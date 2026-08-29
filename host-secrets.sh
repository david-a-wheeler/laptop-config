#!/bin/sh
# host-secrets.sh: manage the named secrets secrets_server.py serves out of
# macOS Keychain. Run on the host only; VMs never store secrets.
# MUST be on MacOS. POSIX sh throughout.
#
# Every secret name here is a short logical name (like "GH_TOKEN")
# spelled like the environment variable it stands in if one exists.
# Every Keychain-touching command below applies config.sh's KEYCHAIN_PREFIX
# to mark it as a secret managed here (anything else is not visible).
#
# To lock a secret to one specific VM instead of leaving it available to
# any VM, just append "@<vm-hostname>" as part of the name you give below
# (e.g. "HEROKU_API_KEY@mytux"). secrets_server.py resolves which VM is
# asking and only serves an "@vm"-suffixed name to that VM specifically.
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "host-secrets.sh"

usage() {
  cat <<EOF >&2
Usage: $0 list
       $0 set <name>[@vm-hostname] # set secret <name> from stdin
       $0 get <name>[@vm-hostname] # print secret <name> to stdout
       $0 delete <name>[@vm-hostname] # delete secret <name>

Run "$0 list" to see every currently servable secret.
EOF
  exit 1
}

# Every Keychain-touching function below takes a short logical name (the
# same one you'd pass on the command line, "@vm-hostname" suffix and all)
# and applies KEYCHAIN_PREFIX itself: callers never need to think about
# the prefix.
secret_exists() {
  security find-generic-password -s "${KEYCHAIN_PREFIX}$1" >/dev/null 2>&1
}

cmd_list() {
  echo "Named secrets referenced by config.sh's GIT_SECRETS:"
  for pair in $GIT_SECRETS; do
    host="${pair%%:*}"
    name="${pair#*:}"
    if secret_exists "$name"; then
      state="present"
    else
      state="MISSING"
    fi
    echo "  $name (for $host): $state"
  done

  echo
  echo "All secrets currently servable (stored under Keychain's \"${KEYCHAIN_PREFIX}\" prefix):"
  # "security dump-keychain" (no "-d") lists item attributes only, never
  # secret values: the closest thing security(1) has to "list by prefix",
  # since find-generic-password only does an exact -s match. "svce" is
  # Keychain's own attribute name for the service string
  # add-generic-password -s/find-generic-password -s operate on. Capture
  # the output separately (rather than piping it directly) so a failure
  # here is visible instead of silently producing an empty list under
  # set -e (same reasoning as host-setup.sh's utm_list_output).
  dump_output="$(security dump-keychain 2>&1)" || {
    echo "  WARNING: 'security dump-keychain' failed; can't list these:" >&2
    echo "$dump_output" >&2
    dump_output=""
  }
  printf '%s\n' "$dump_output" \
    | grep -o '"svce"<blob>="[^"]*"' \
    | sed -e 's/^"svce"<blob>="//' -e 's/"$//' \
    | grep "^${KEYCHAIN_PREFIX}" \
    | sed -e "s/^${KEYCHAIN_PREFIX}//" -e 's/^/  - /' \
    | sort -u
}

cmd_get() {
  security find-generic-password -s "${KEYCHAIN_PREFIX}$1" -w
}

cmd_set() {
  name="$1"
  tty_stdin=false
  if [ -t 0 ]; then
    tty_stdin=true
  fi

  # Too-short secrets are a mistake, prevent them.
  min_length=9
  if [ "$tty_stdin" = true ]; then
    trap 'stty echo' EXIT
    trap 'stty echo; exit 1' INT TERM HUP
  fi
  while :; do
    if [ "$tty_stdin" = true ]; then
      printf '%s' "Paste the secret for $name: "
      stty -echo
    fi
    if ! read -r token; then
      # Not a cancel path (Ctrl-C skips this entirely, see above). This
      # is EOF/closed stdin (e.g. run non-interactively), where retrying
      # would just spin forever re-reading nothing.
      if [ "$tty_stdin" = true ]; then
        stty echo
        echo
      fi
      echo "No more input; giving up." >&2
      exit 1
    fi
    if [ "$tty_stdin" = true ]; then
      stty echo
      echo
    fi
    if [ "${#token}" -ge "$min_length" ]; then
      break
    fi
    echo "That's only ${#token} character(s); too short." >&2
    if [ "$tty_stdin" = false ]; then
      echo "stdin isn't a terminal, so there's nothing left to retry with; giving up." >&2
      exit 1
    fi
    echo "Try again (Ctrl-C to cancel)." >&2
  done
  if [ "$tty_stdin" = true ]; then
    trap - EXIT INT TERM HUP
  fi
  echo "(Received ${#token} characters.)"

  if secret_exists "$name"; then
    security delete-generic-password -s "${KEYCHAIN_PREFIX}${name}" >/dev/null 2>&1
  fi
  security add-generic-password -a "$USER" -s "${KEYCHAIN_PREFIX}${name}" -w "$token"
  echo "Stored $name in Keychain."
}

cmd_delete() {
  name="$1"
  if ! secret_exists "$name"; then
    echo "$name isn't in Keychain; nothing to delete."
    return 0
  fi
  security delete-generic-password -s "${KEYCHAIN_PREFIX}${name}" >/dev/null 2>&1
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
