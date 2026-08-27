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

echo "== Installing Claude Code (native installer) =="
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

echo "== Rendering and applying nftables egress ruleset =="
nft_ports="$(printf '%s' "$NFTABLES_ALLOWED_TCP_PORTS" | sed 's/ /, /g')"
NFTABLES_ALLOWED_TCP_PORTS_NFT="$nft_ports"
render_template "$SCRIPT_DIR/nftables.template.conf" /tmp/nftables.conf.rendered \
  NFTABLES_ALLOWED_TCP_PORTS_NFT
sudo cp /tmp/nftables.conf.rendered /etc/nftables.conf
rm -f /tmp/nftables.conf.rendered
sudo nft -f /etc/nftables.conf

echo "== Hardening CUPS (unix socket only, no TCP listener) =="
# Only comments an uncommented "Listen localhost:631" line, so this is
# already safe to re-run: once commented, the pattern no longer matches.
sudo sed -i '/^[[:space:]]*Listen localhost:631/s/^/#/' /etc/cups/cupsd.conf
sudo systemctl restart cups

echo "== Checking for nono =="
# Not installed here: we don't have a verified install command to embed
# blindly. Install per https://nono.sh/docs/cli/getting_started/installation
# if this warns.
if ! command -v nono >/dev/null 2>&1; then
  echo "WARNING: nono not found on PATH. Install it manually:" >&2
  echo "  https://nono.sh/docs/cli/getting_started/installation" >&2
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
  HOST_PROXY_PORT GIT_SECRETS_PY_DICT
sudo cp /tmp/vm-git-helper.py.rendered /usr/local/bin/vm-git-helper.py
sudo chmod +x /usr/local/bin/vm-git-helper.py
rm -f /tmp/vm-git-helper.py.rendered
git config --global credential.helper /usr/local/bin/vm-git-helper.py

echo "== Configuring git niceties =="
configure_git_niceties

echo "== Installing Claude Code global instructions (CLAUDE.md) =="
mkdir -p "$HOME/.claude"
install_unless_locally_newer "$SCRIPT_DIR/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md"

echo "== Managing ~/.bash_aliases block (editor, GIT_AUTH_SESSION, noclaude) =="
nono_extra_read_args=""
for path in $NONO_EXTRA_READ_PATHS; do
  nono_extra_read_args="${nono_extra_read_args}--read ${path} "
done
NONO_EXTRA_READ_ARGS="$nono_extra_read_args"
render_template "$SCRIPT_DIR/vm-bash-aliases-block.template.sh" /tmp/bash-aliases-block.rendered \
  NONO_EXTRA_READ_ARGS
install_managed_block /tmp/bash-aliases-block.rendered "$HOME/.bash_aliases"
rm -f /tmp/bash-aliases-block.rendered

echo "== Adding the host's SSH public key to authorized_keys =="
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if [ -f "$SCRIPT_DIR/host-ssh-key.pub" ]; then
  pubkey="$(cat "$SCRIPT_DIR/host-ssh-key.pub")"
  grep -qxF "$pubkey" "$HOME/.ssh/authorized_keys" || echo "$pubkey" >> "$HOME/.ssh/authorized_keys"
else
  echo "NOTE: host-ssh-key.pub isn't in the repo yet - run host-setup.sh on the Mac, commit it, and git pull here to enable host->VM ssh." >&2
fi

if [ "$ENABLE_INFERENCE_SSH_TUNNEL" = "true" ]; then
  # Reserved for the "MAYBE" host-inference-engine SSH reverse tunnel from
  # architecture.md. The VM side needs nothing beyond sshd (already enabled
  # above); the host-side keygen/RemoteForward setup lives in host-setup.sh.
  # Not otherwise implemented yet - architecture.md itself marked it
  # speculative, and it's unrelated to git auth.
  :
fi

echo "== vm-setup.sh done =="
