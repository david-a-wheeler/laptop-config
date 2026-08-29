#!/bin/sh
# host-secrets.sh: manage the named secrets secrets_server.py serves out of
# macOS Keychain. Run on the host only; VMs never store secrets. Kept
# separate from host-setup.sh so a plain "git pull && ./host-setup.sh" can
# never touch a stored secret. POSIX sh throughout: the token prompt below
# masks input with stty rather than bash's "read -s", since we don't rely
# on what /bin/sh actually is.
#
# Every name here is a short logical name ("GH_TOKEN", not
# "laptop-config-GH_TOKEN") - spelled like the environment variable it
# stands in for wherever one exists (see config.sh's GIT_SECRETS comment),
# so this name is self-documenting and secret_session needs no separate
# lookup table. Every Keychain-touching command below applies
# config.sh's KEYCHAIN_PREFIX itself; that prefix is what marks a secret as
# servable by secrets_server.py at all (see config.sh), so storing
# something here already makes it servable, nothing further to declare.
#
# To lock a secret to one specific VM instead of leaving it available to
# any VM, just include "@<vm-hostname>" as part of the name you give below
# (e.g. "HEROKU_API_KEY@mytux"). secrets_server.py resolves which VM is
# asking and only serves an "@vm"-suffixed name to that VM specifically.
# Don't store both "name" and "name@vm-hostname" at once unless you
# actually want every other VM falling through to the unlocked one.
#
# Usage:
#   host-secrets.sh list
#   host-secrets.sh set    <name>[@vm-hostname]   # interactive paste;
#                                    # asks before overwriting. No setup
#                                    # instructions printed here; see
#                                    # rotate-github-pat.sh/rotate-heroku-key.sh
#                                    # for how to actually obtain a value.
#                                    # Renaming an existing secret (e.g. after
#                                    # a naming-convention change) needs no
#                                    # setup step: "host-secrets.sh get OLD |
#                                    # host-secrets.sh set NEW" pipes the
#                                    # value straight across without ever
#                                    # displaying or re-typing it. Piped
#                                    # input always overwrites without
#                                    # asking, and only works for a NEW name
#                                    # that doesn't already exist (piped
#                                    # input has exactly one line to give,
#                                    # not a separate y/N answer first).
#   host-secrets.sh get    <name>[@vm-hostname]   # prints the secret to
#                                    # stdout (careful)
#   host-secrets.sh delete <name>[@vm-hostname]   # asks for confirmation
#                                    # first
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "host-secrets.sh"

usage() {
  cat <<EOF >&2
Usage: $0 list
       $0 set <name>[@vm-hostname]
       $0 get <name>[@vm-hostname]
       $0 delete <name>[@vm-hostname]

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
  # A piped secret (e.g. "host-secrets.sh get OLD | host-secrets.sh set
  # NEW", the supported way to rename/copy one without ever re-pasting it
  # by hand) is exactly one line with no room for an interactive y/N
  # exchange first, so this only asks when stdin's actually a terminal;
  # piped input always overwrites.
  tty_stdin=false
  if [ -t 0 ]; then
    tty_stdin=true
  fi
  if secret_exists "$name" && [ "$tty_stdin" = true ]; then
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

  # No setup instructions printed here by design: each secret's own
  # rotate-<name>.sh script (rotate-github-pat.sh, rotate-heroku-key.sh)
  # owns that, so there's exactly one place to look, not two saying
  # slightly different things. Run this directly only if you already have
  # the value in hand.
  # Secrets this short are almost certainly a mistake (empty paste, partial
  # paste, a stray keystroke) rather than a real one, so this asks again
  # instead of silently storing something useless (only when interactive:
  # piped stdin has exactly one line to give, so there's nothing to retry
  # with). The traps guarantee terminal echo gets restored no matter how
  # this ends, including Ctrl-C; skipped entirely when stdin isn't a
  # terminal; "stty -echo"/"stty echo" fail outright on a pipe
  # ("Inappropriate ioctl for device"), which under "set -e" would abort
  # this function before ever reading the piped value.
  # Tested and confirmed the EXIT trap alone does NOT fire on an untrapped
  # SIGINT (dash terminates immediately on the signal's default
  # disposition), so INT/TERM/HUP need their own explicit handler too.
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
    echo "That's only ${#token} character(s): doesn't look like a real secret." >&2
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
  printf '%s' "Delete $name from Keychain? This can't be undone. [y/N] "
  read -r confirm
  case "$confirm" in
    y | Y | yes | YES)
      security delete-generic-password -s "${KEYCHAIN_PREFIX}${name}" >/dev/null 2>&1
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
