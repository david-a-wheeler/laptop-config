#!/bin/sh
# vm-setup.sh - idempotent setup for an Ubuntu VM (lftux, mytux, ...).
#
# Run this after every "git pull" of this repo to converge the VM to the
# repo's current config. Safe to re-run any time; it only ever brings state
# in line with config.sh, never accumulates changes.
#
# Needs sudo (apt, systemctl, writing /etc/nftables.conf, /etc/cups/cupsd.conf,
# /usr/local/bin). Does not touch secrets - see host-secrets.sh, run on the
# macOS host, for that.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# This script is Linux-only for now - might loosen this later, but only
# Ubuntu VMs are supported today, so fail clearly rather than let
# apt/systemctl/etc. produce confusing errors on a machine without them.
linux_only "vm-setup.sh"

echo "== Installing base packages =="
# openssh/avahi/cups/nftables per architecture.md's discovery+services
# phase. curl has to land here, before anything else (the gh repo setup
# right below, the Claude Code installer further down) tries to use it -
# a fresh VM image can't be assumed to have it already. Node.js/npm are
# deliberately NOT installed here: Claude Code's native installer (below)
# is self-contained. qemu-guest-agent lets the host ask UTM's utmctl for
# this VM's current IP (see host-setup.sh) - without it running here,
# "ssh <this-vm-name>" from the host has nothing to go on.
#
# git/shellcheck/make/build-essential/vim/python3: general-purpose dev
# tools worth having on every VM regardless of project (vim in particular
# because EDITOR/VISUAL below are set to it; python3 because
# vm-git-helper.py above is a Python script invoked directly by git, so
# it's a hard requirement for the git-auth bridge, not just a nicety - not
# worth assuming it's preinstalled). Checked against `apt-mark showmanual`
# on lftux and deliberately left out anything project-specific rather than
# universal - ruby, postgresql, and the heroku CLI are for one project
# (BadgeApp) and don't belong in a generic laptop-config repo; cmake,
# autoconf, bison, pkg-config, and the lib*-dev packages are ruby-build's
# prerequisites for compiling Ruby, same story; graphviz looked like it
# might be a project's doc-generation dependency rather than a general
# tool. Add project-specific packages by hand in that project's own setup,
# not here. "apt-get install -y" is naturally idempotent (a no-op once
# everything's already at the latest version), so this one line covers
# first install and every later re-run.
sudo apt-get update
sudo apt-get install -y openssh-server avahi-daemon nftables curl cups \
  qemu-guest-agent git shellcheck make build-essential vim python3

echo "== Enabling services =="
sudo systemctl enable --now ssh avahi-daemon nftables cups qemu-guest-agent

echo "== Adding the GitHub CLI (gh) apt repo and installing gh =="
# Official install method (see https://github.com/cli/cli/blob/trunk/docs/install_linux.md):
# add GitHub's own apt repo and keyring, then install gh from it. Unlike
# nono further down, this one has a real repo behind it, so it's safe to
# automate. Deliberately NOT gated behind "is gh already installed": these
# are just idempotent file writes, and doing them unconditionally means a
# corrupted keyring/repo file or a key rotation gets fixed on the next run
# too, not just on first install. curl writes to a temp file first (rather
# than piping into "sudo tee") so a failed download is caught here via
# set -e, instead of silently producing an empty keyring that only fails
# later, confusingly, inside apt-get update. This needs its own apt-get
# update (the one above ran before this repo existed), so gh install is
# two "apt-get update"s total rather than the one everything else shares.
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /tmp/githubcli-archive-keyring.gpg
sudo install -m 644 /tmp/githubcli-archive-keyring.gpg \
  /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f /tmp/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

echo "== Claude Code (native installer) =="
# Asked once ever (see ask_once in common.sh) when claude isn't already
# on PATH - no point asking whether to install something clearly already
# there, and re-checking "command -v claude" here (rather than persisting
# that fact anywhere) means this self-corrects if claude's ever
# uninstalled later, instead of trusting a flag that could go stale.
# want_claude is captured once and reused below (for the CLAUDE.md step)
# rather than re-running "command -v claude" there too - right after a
# fresh install in this same run, that check could false-negative: the
# native installer's ~/.local/bin only lands on PATH via the
# .bash_aliases block this script installs, which a fresh shell hasn't
# sourced yet mid-run.
if command -v claude >/dev/null 2>&1; then
  echo "Claude Code is already installed."
  want_claude=true
elif ask_once install-claude-code "Install Claude Code on this VM?"; then
  curl -fsSL https://claude.ai/install.sh | bash
  want_claude=true
else
  echo "Skipping Claude Code install (recorded preference)."
  want_claude=false
fi

echo "== Rendering and applying nftables egress ruleset =="
# SECRETS_SERVER_PORT gets its own rule scoped to the host's gateway
# address (see nftables.template.conf) rather than being folded into the
# general NFTABLES_ALLOWED_TCP_PORTS set, which would let the VM reach ANY
# host on that port instead of just the secrets server. Missing this port
# entirely was a real incident - the VM couldn't reach the secrets server
# at all, and nothing failed loudly; git just fell back to an interactive
# username prompt - so it's handled explicitly here rather than left to
# config.sh.
nft_ports="$(printf '%s' "$NFTABLES_ALLOWED_TCP_PORTS" | sed 's/^ *//; s/ *$//; s/ /, /g')"
NFTABLES_ALLOWED_TCP_PORTS_NFT="$nft_ports"
HOST_GATEWAY_IP="$(ip route | awk '/^default/ { print $3; exit }')"
if [ -z "$HOST_GATEWAY_IP" ]; then
  echo "ERROR: couldn't determine the default gateway - can't scope the secrets-server firewall rule safely." >&2
  exit 1
fi
render_template "$SCRIPT_DIR/nftables.template.conf" /tmp/nftables.conf.rendered \
  NFTABLES_ALLOWED_TCP_PORTS_NFT HOST_GATEWAY_IP SECRETS_SERVER_PORT
sudo cp /tmp/nftables.conf.rendered /etc/nftables.conf
rm -f /tmp/nftables.conf.rendered
sudo nft -f /etc/nftables.conf

echo "== Hardening CUPS (unix socket only, no TCP listener) =="
# Only comments an uncommented "Listen localhost:631" line, so this is
# already safe to re-run: once commented, the pattern no longer matches.
sudo sed -i '/^[[:space:]]*Listen localhost:631/s/^/#/' /etc/cups/cupsd.conf
sudo systemctl restart cups

echo "== Installing/updating nono =="
# nono ships prebuilt .deb/.rpm on GitHub Releases - no real apt repo
# backs it (confirmed earlier: apt-cache policy showed nothing), so this
# fetches the latest release's .deb for this VM's architecture directly
# and dpkg -i's it, the same way it's actually installed on lftux already
# (confirmed via dpkg.log: a direct "dpkg -i" of a downloaded .deb, not
# apt/a script). Re-running this always grabs whatever's currently latest,
# so updating nono is just re-running vm-setup.sh. Cargo/Homebrew (the
# project's other documented options) would mean a whole extra toolchain
# just to build a 25 MB tool we can get prebuilt.
nono_arch="$(dpkg --print-architecture)"
nono_deb_url="$(curl -fsSL https://api.github.com/repos/nolabs-ai/nono/releases/latest \
  | grep -o "https://github.com/nolabs-ai/nono/releases/download/[^\"]*_${nono_arch}\.deb" \
  | head -1)"
if [ -n "$nono_deb_url" ]; then
  # Version comes from the release tag in the URL path
  # (.../download/v0.74.0/...), not the .deb filename - decouples this
  # from nono's asset-naming convention, only relies on GitHub's own
  # release-asset URL structure. dpkg-query fails (nonzero) if nono-cli
  # isn't installed yet, which is expected, not an error - old_version
  # just stays empty in that case.
  nono_new_version="$(printf '%s' "$nono_deb_url" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')"
  nono_new_version="${nono_new_version#v}"
  nono_old_version="$(dpkg-query -W -f='${Version}' nono-cli 2>/dev/null || true)"
  if [ -n "$nono_old_version" ] && [ "$nono_old_version" = "$nono_new_version" ]; then
    echo "nono is already up to date (version $nono_new_version)."
  else
    curl -fsSL "$nono_deb_url" -o /tmp/nono-cli.deb
    sudo dpkg -i /tmp/nono-cli.deb
    rm -f /tmp/nono-cli.deb
    if [ -n "$nono_old_version" ]; then
      echo "Updated nono: $nono_old_version -> $nono_new_version"
    else
      echo "Installed nono $nono_new_version (was not previously installed)."
    fi
  fi
else
  echo "WARNING: couldn't find a nono .deb release for architecture $nono_arch - install manually:" >&2
  echo "  https://github.com/nolabs-ai/nono/releases" >&2
fi

echo "== Installing vm-git-helper (git credential helper) =="
git_secrets_py_dict="{"
first=1
for pair in $GIT_SECRETS; do
  host="${pair%%:*}"
  secret="${pair#*:}"
  if [ "$first" -eq 0 ]; then
    git_secrets_py_dict="${git_secrets_py_dict}, "
  fi
  git_secrets_py_dict="${git_secrets_py_dict}\"${host}\": \"${secret}\""
  first=0
done
git_secrets_py_dict="${git_secrets_py_dict}}"
GIT_SECRETS_PY_DICT="$git_secrets_py_dict"
render_template "$SCRIPT_DIR/vm-git-helper.template.py" /tmp/vm-git-helper.py.rendered \
  SECRETS_SERVER_PORT GIT_SECRETS_PY_DICT
sudo cp /tmp/vm-git-helper.py.rendered /usr/local/bin/vm-git-helper.py
sudo chmod +x /usr/local/bin/vm-git-helper.py
rm -f /tmp/vm-git-helper.py.rendered
git config --global credential.helper /usr/local/bin/vm-git-helper.py

echo "== Installing secrets-client (generic secrets-server CLI, used by heroku_session) =="
render_template "$SCRIPT_DIR/secrets-client.template.py" /tmp/secrets-client.py.rendered \
  SECRETS_SERVER_PORT
sudo cp /tmp/secrets-client.py.rendered /usr/local/bin/secrets-client.py
sudo chmod +x /usr/local/bin/secrets-client.py
rm -f /tmp/secrets-client.py.rendered

echo "== Configuring git niceties =="
configure_git_niceties

if [ "$want_claude" = true ]; then
  echo "== Installing Claude Code global instructions (CLAUDE.md) =="
  mkdir -p "$HOME/.claude"
  install_unless_locally_newer "$SCRIPT_DIR/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md"
fi

echo "== Managing ~/.bash_aliases block (editor, LAPTOP_CONFIG_AUTH_SESSION, noclaude, heroku_session) =="
nono_extra_read_args=""
for path in $NONO_EXTRA_READ_PATHS; do
  nono_extra_read_args="${nono_extra_read_args}--read ${path} "
done
NONO_EXTRA_READ_ARGS="$nono_extra_read_args"
render_template "$SCRIPT_DIR/vm-bash-aliases-block.template.sh" /tmp/bash-aliases-block.rendered \
  NONO_EXTRA_READ_ARGS
install_managed_block /tmp/bash-aliases-block.rendered "$HOME/.bash_aliases"
rm -f /tmp/bash-aliases-block.rendered

if [ "$ENABLE_INFERENCE_SSH_TUNNEL" = "true" ]; then
  # Reserved for the "MAYBE" host-inference-engine SSH reverse tunnel from
  # architecture.md. The VM side needs nothing beyond sshd (already enabled
  # above); the host-side keygen/RemoteForward setup lives in host-setup.sh.
  # Not otherwise implemented yet - architecture.md itself marked it
  # speculative, and it's unrelated to git auth.
  :
fi

echo "== vm-setup.sh done =="
