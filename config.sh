# shellcheck shell=sh
# config.sh - person/machine-specific values shared by the setup scripts.
# Sourced only (no shebang needed) - must stay POSIX sh, since it's sourced
# by both host-setup.sh/host-secrets.sh (macOS) and vm-setup.sh (Ubuntu's
# dash).
#
# Sourced (not executed) by host-setup.sh, vm-setup.sh, host-secrets.sh, and
# common.sh's render_template(). Copy this repo and edit these values if you
# want to reuse the scripts for your own setup.

# Git identity (used by common.sh's configure_git_niceties).
GIT_USER_NAME="David A. Wheeler"
GITHUB_ID="david-a-wheeler"
# Make email weird to counter naive spammers
GIT_USER_EMAIL="dwheeler"'@'"dwheeler.com"

# Linux username inside every VM (lftux, mytux, ...). Scripts assume it's the
# same on each VM so one config.sh works for all of them.
VM_USER="dwheeler"

# Unprivileged macOS account that runs local inference engines, kept unable
# to read the primary user's home directory. See architecture.md.
MACOS_INFER_USER="_infer"

# Port the host git-auth proxy (git_host_proxy.py) listens on, and that
# vm-git-helper.py talks to.
HOST_PROXY_PORT="9876"

# git host -> macOS Keychain service name, space-separated "host:service"
# pairs. vm-git-helper.py (rendered from vm-git-helper.template.py) looks up
# the right secret name here for whatever git host it's asked to authenticate.
# Add an entry here (and run host-secrets.sh set <service> on the host) to
# bring another git host under the proxy; no script changes needed.
GIT_SECRETS="github.com:git-host-github-pat"

# Path to UTM's utmctl CLI, not on PATH by default since it ships inside
# the app bundle. host-setup.sh uses it to look up each running VM's name
# and current IP live (`utmctl list`, `utmctl ip-address <name>`) and
# builds ~/.ssh/config Host blocks from that, so "ssh lftux"/"scp x lftux:"
# work directly - avahi's .local names don't resolve from the host, since
# mDNS doesn't cross UTM's Shared Network NAT (and bridging isn't an option
# on WiFi). Nothing here needs updating as VMs are added, removed, or
# change IP: every host-setup.sh run re-queries utmctl fresh. Requires
# qemu-guest-agent running in the VM (vm-setup.sh installs it).
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

# TCP ports the VM is allowed to reach outbound (besides loopback and DNS).
# 22=SSH, 80/443=HTTP/HTTPS. See nftables.template.conf.
NFTABLES_ALLOWED_TCP_PORTS="22 80 443"

# Extra paths noclaude() grants read-only nono access to, beyond the
# current directory and ~/.claude (which every project needs). Space
# separated. Add your own toolchain dirs here as needed. Use $HOME rather
# than ~ - a tilde in a double-quoted assignment doesn't expand.
NONO_EXTRA_READ_PATHS="$HOME/.rbenv"

# Set to "true" to also set up the SSH reverse tunnel (RemoteForward) for
# reaching a host-side local inference engine (e.g. Ollama) from the VM.
# Off by default: architecture.md marked this speculative, and it's unrelated
# to git auth.
ENABLE_INFERENCE_SSH_TUNNEL="false"
