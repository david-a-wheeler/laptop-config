#!/bin/sh
# host-secrets.sh - manage the named secrets git_host_proxy.py serves out of
# macOS Keychain. Run on the host only; VMs never store secrets. Kept
# separate from host-setup.sh so a plain "git pull && ./host-setup.sh" can
# never touch a stored secret. POSIX sh throughout - the token prompt below
# masks input with stty rather than bash's "read -s", since we don't rely
# on what /bin/sh actually is.
#
# Usage:
#   host-secrets.sh list
#   host-secrets.sh set    <name>   # interactive; prints instructions for
#                                    # known names, asks before overwriting
#   host-secrets.sh get    <name>   # prints the secret to stdout (careful)
#   host-secrets.sh delete <name>   # asks for confirmation first
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "host-secrets.sh"

usage() {
  cat <<EOF >&2
Usage: $0 list
       $0 set <name>
       $0 get <name>
       $0 delete <name>

Named secrets currently referenced by config.sh's GIT_SECRETS:
$(for pair in $GIT_SECRETS; do echo "  ${pair#*:}  (for ${pair%%:*})"; done)
EOF
  exit 1
}

secret_exists() {
  security find-generic-password -s "$1" >/dev/null 2>&1
}

cmd_list() {
  for pair in $GIT_SECRETS; do
    host="${pair%%:*}"
    name="${pair#*:}"
    if secret_exists "$name"; then
      state="present"
    else
      state="MISSING"
    fi
    echo "$name (for $host): $state"
  done
}

cmd_get() {
  security find-generic-password -s "$1" -w
}

# Per-secret setup instructions. Add a case here as new named secrets show
# up in config.sh's GIT_SECRETS - this is the intended extension point.
print_recipe() {
  case "$1" in
    github-pat)
      cat <<EOF

Create a GitHub Personal Access Token:
  1. Open https://github.com/settings/tokens
  2. Generate new token (classic) - scopes: repo, workflow.
  3. Copy the token (starts with "ghp_" or "github_pat_").
EOF
      ;;
    *)
      echo "No setup recipe for '$1' yet - add one to host-secrets.sh's print_recipe()." >&2
      ;;
  esac
}

cmd_set() {
  name="$1"
  if secret_exists "$name"; then
    printf '%s already exists in Keychain. Overwrite? [y/N] ' "$name"
    read -r confirm
    case "$confirm" in
      y | Y | yes | YES) : ;;
      *)
        echo "Leaving $name unchanged."
        return 0
        ;;
    esac
  fi

  print_recipe "$name"
  # Secrets this short are almost certainly a mistake (empty paste, partial
  # paste, a stray keystroke) rather than a real one - ask again instead of
  # silently storing something useless. The traps guarantee terminal echo
  # gets restored no matter how this ends, including Ctrl-C - tested and
  # confirmed the EXIT trap alone does NOT fire on an untrapped SIGINT
  # (dash terminates immediately on the signal's default disposition), so
  # INT/TERM/HUP need their own explicit handler too.
  min_length=9
  trap 'stty echo' EXIT
  trap 'stty echo; exit 1' INT TERM HUP
  while :; do
    printf '%s' "Paste the secret for $name: "
    stty -echo
    if ! read -r token; then
      # Not a cancel path - Ctrl-C skips this entirely (see above). This
      # is EOF/closed stdin (e.g. run non-interactively), where retrying
      # would just spin forever re-reading nothing.
      stty echo
      echo
      echo "No more input - giving up." >&2
      exit 1
    fi
    stty echo
    echo
    if [ "${#token}" -ge "$min_length" ]; then
      break
    fi
    echo "That's only ${#token} character(s) - doesn't look like a real secret. Try again (Ctrl-C to cancel)." >&2
  done
  trap - EXIT INT TERM HUP
  echo "(Received ${#token} characters.)"

  if secret_exists "$name"; then
    security delete-generic-password -s "$name" >/dev/null 2>&1
  fi
  security add-generic-password -a "$USER" -s "$name" -w "$token"
  echo "Stored $name in Keychain."
}

cmd_delete() {
  name="$1"
  if ! secret_exists "$name"; then
    echo "$name isn't in Keychain - nothing to delete."
    return 0
  fi
  printf '%s' "Delete $name from Keychain? This can't be undone. [y/N] "
  read -r confirm
  case "$confirm" in
    y | Y | yes | YES)
      security delete-generic-password -s "$name" >/dev/null 2>&1
      echo "Deleted $name from Keychain."
      ;;
    *)
      echo "Leaving $name unchanged."
      ;;
  esac
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  list)
    cmd_list
    ;;
  get)
    [ $# -ge 1 ] || usage
    cmd_get "$1"
    ;;
  set)
    [ $# -ge 1 ] || usage
    cmd_set "$1"
    ;;
  delete)
    [ $# -ge 1 ] || usage
    cmd_delete "$1"
    ;;
  *)
    usage
    ;;
esac
