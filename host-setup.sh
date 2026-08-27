#!/bin/sh
# host-setup.sh - idempotent setup for the macOS host. POSIX sh throughout
# (no bash-only features), same as vm-setup.sh - what /bin/sh actually is
# on macOS isn't worth relying on either way.
#
# Run this after every "git pull" of this repo to converge the host to the
# repo's current config. Safe to re-run any time. Some steps have no
# reliable non-interactive equivalent (GUI-only System Settings toggles) -
# those print exact instructions and wait for you to confirm, rather than
# guessing at a scriptable equivalent that might silently do the wrong
# thing (e.g. create an admin account, or toggle the wrong power setting).
#
# Does not touch secrets - see host-secrets.sh for that (run it once after
# the first host-setup.sh, and again whenever a token needs rotating).
set -eu

# This script is macOS-only for now (no dependencies loaded yet, so check
# this before anything else can fail confusingly on the wrong machine) -
# real incident: this got run on an Ubuntu VM by mistake, and its
# Mac-specific checks further down produced misleading results (no /Users,
# no _infer account - neither of which means anything on Linux) instead of
# just saying "wrong machine." Might loosen this later (e.g. a Linux host),
# but that's not supported today, so fail clearly rather than guess.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: host-setup.sh is for the macOS host only (this machine reports '$(uname -s)')." >&2
  echo "  Run vm-setup.sh instead if this is one of the Ubuntu VMs." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Disabled: the check below was added after "ls /Users" failed with
# ENOENT, which looked like a Full Disk Access problem - but that test was
# run over an ssh session into the Linux VM, which has no /Users at all
# (it has /home); nothing was actually confirmed broken on macOS itself.
# Left here commented out, not deleted, in case FDA does turn out to be a
# real precondition later - uncomment and verify against an actual Mac
# shell first.
#
# echo "== Checking for Full Disk Access =="
# if ! ls /Users >/dev/null 2>&1; then
#   cat <<EOF >&2
# ERROR: can't read /Users - this terminal app doesn't have Full Disk
# Access, which recent macOS requires for account/directory lookups (id,
# dscl) that later steps in this script depend on.
#
# Fix: System Settings > Privacy & Security > Full Disk Access > enable it
# for whatever app you're running this script from (Terminal, iTerm2, etc.),
# then re-run this script.
# EOF
#   exit 1
# fi

echo "== Locking down home directory (macOS grants 'staff' group read by default) =="
chmod go-rwx "$HOME"

echo "== Checking for the $MACOS_INFER_USER account =="
if ! id "$MACOS_INFER_USER" >/dev/null 2>&1; then
  cat <<EOF

The $MACOS_INFER_USER account doesn't exist yet. It runs local inference
engines (llama.cpp, Stable Diffusion, ...) under an account that can't read
your home directory, so a compromised inference engine can't reach your
files or keys. Create it now:

  1. Open macOS System Settings.
  2. Users & Groups > Add User.
  3. Create a *standard* (non-administrator) user named "$MACOS_INFER_USER".

EOF
  printf '%s' "Press Enter once you've created it (or Ctrl-C to skip for now): "
  read -r _
  if ! id "$MACOS_INFER_USER" >/dev/null 2>&1; then
    echo "WARNING: $MACOS_INFER_USER still not found. Continuing anyway - re-run this script after creating it." >&2
  fi
fi

echo "== Installing git_host_proxy.py =="
mkdir -p "$HOME/bin"
cp "$SCRIPT_DIR/git_host_proxy.py" "$HOME/bin/git_host_proxy.py"
chmod +x "$HOME/bin/git_host_proxy.py"

echo "== Installing the git-host-proxy LaunchAgent =="
mkdir -p "$HOME/Library/LaunchAgents"
render_template "$SCRIPT_DIR/com.user.githostproxy.template.plist" \
  "$HOME/Library/LaunchAgents/com.user.githostproxy.plist" HOME
uid="$(id -u)"
launchctl bootout "gui/$uid/com.user.githostproxy" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.user.githostproxy.plist"

echo "== Generating an SSH key for host->VM access (if missing) =="
# Plain ed25519, no hardware key: this is just for host-initiated
# convenience logins (ssh/scp into a VM by name), not for anything
# security-critical - VMs never get host secrets this way. The private key
# never leaves the host. The public half is pushed straight to each VM
# below via ssh-copy-id, rather than committed into this repo: a public key
# isn't a secret, but it *is* machine-generated, person-specific data, so
# tracking it here would mean anyone else reusing this repo either inherits
# this key or fights constant diff noise replacing it with their own -
# same category of problem config.local.sh already solves for config.sh.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "laptop-config host->VM access"
fi

echo "== Configuring SSH access to VMs (~/.ssh/config + authorized_keys, via utmctl) =="
# Ask utmctl (UTM's own CLI, already installed with the app) which VMs are
# running and what IP each one currently has, rather than maintaining a
# manual name->IP list: nothing to update here as VMs are added, removed,
# renamed, or just get a new DHCP lease. `utmctl list`'s output is a
# fixed-format table (UUID, Status, Name); we only look at started VMs,
# since a stopped one has no guest agent to answer `ip-address` anyway.
# `ip-address` lists IPv4 addresses before any IPv6 ones, so the first line
# is what we want (see `utmctl help ip-address`).
#
# ssh-copy-id installs the key from above on each VM using its normal login
# password (typed interactively) - standard, boring, and it needs nothing
# from this repo or from vm-setup.sh. It's also already idempotent: once a
# VM has the key, ssh-copy-id authenticates with it directly and skips
# re-adding it, no password needed on later runs. accept-new avoids an
# unexpected host-key prompt on a VM's first-ever connection; a rejected or
# unreachable VM only warns, so one bad VM can't stop the others or the
# rest of this script.
if [ -x "$UTMCTL" ]; then
  # Capture "utmctl list"'s own exit status separately before piping its
  # output onward - a pipeline's exit status in POSIX sh is the *last*
  # command's (no "pipefail" here), so "utmctl list | awk | while" would
  # otherwise silently swallow a failure here (UTM not running, etc.)
  # instead of warning about it.
  if utm_list_output="$("$UTMCTL" list 2>&1)"; then
    ssh_config_block="$(mktemp)"
    printf '%s\n' "$utm_list_output" \
      | awk 'NR > 1 && $2 == "started" { print $NF }' \
      | while IFS= read -r vm_name; do
          vm_ip="$("$UTMCTL" ip-address "$vm_name" 2>/dev/null | head -1)"
          if [ -n "$vm_ip" ]; then
            {
              echo "Host $vm_name"
              echo "    HostName $vm_ip"
              echo "    User $VM_USER"
              echo "    IdentityFile ~/.ssh/id_ed25519"
              echo "    IdentitiesOnly yes"
              echo
            } >> "$ssh_config_block"
            if ! ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" \
                 -o StrictHostKeyChecking=accept-new "$VM_USER@$vm_ip"; then
              echo "WARNING: couldn't copy the host's SSH key to $vm_name ($vm_ip) - 'ssh $vm_name' will need a password until this succeeds." >&2
            fi
          fi
        done
    install_managed_block "$ssh_config_block" "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
    rm -f "$ssh_config_block"
  else
    echo "WARNING: 'utmctl list' failed - skipping ~/.ssh/config setup:" >&2
    echo "$utm_list_output" >&2
  fi
else
  echo "WARNING: utmctl not found at $UTMCTL - skipping ~/.ssh/config setup. Check UTMCTL in config.sh." >&2
fi

if ! confirmation_done battery; then
  cat <<EOF

== Power settings (System Settings > Battery) ==

These are GUI-only toggles with no reliable scriptable equivalent, so set
them by hand if you haven't already:

  1. Options > enable "Prevent automatic sleeping on power adapter when the
     display is off".
  2. Charging > (i) > ensure "Optimized Battery Charging" is enabled.
  3. Energy Mode > On power adapter > switch to "High power".
  4. System Settings > General > Software Update > (i) next to Automatic
     Updates > toggle OFF "Install macOS updates" (you still want the other
     automatic-update options on; this just avoids an update rebooting you
     mid-work).

Also: keep the case open, and the back of the laptop raised if practical,
for airflow.

EOF
  confirm_once battery
fi

echo "== Configuring git niceties =="
configure_git_niceties

echo "== host-setup.sh done =="
