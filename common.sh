# shellcheck shell=sh
# common.sh - shell functions shared by host-setup.sh and vm-setup.sh.
# Sourced only (no shebang needed) - must stay POSIX sh, since it's sourced
# by both host-setup.sh/host-secrets.sh (macOS) and vm-setup.sh (Ubuntu's
# dash).
#
# Source this after config.sh:
#   . "$(dirname "$0")/config.sh"
#   . "$(dirname "$0")/common.sh"

# Usage: macos_only <script-name-for-the-error-message>
# Exits with a clear error if this isn't running on macOS. Call this right
# after sourcing config.sh/common.sh (sourcing them is harmless on any
# platform - just variable/function definitions - so it's fine for the
# check to come after that, not before).
macos_only() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: $1 is for the macOS host only (this machine reports '$(uname -s)')." >&2
    exit 1
  fi
}

# Usage: linux_only <script-name-for-the-error-message>
# Exits with a clear error if this isn't running on Linux (the Ubuntu VMs).
linux_only() {
  if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: $1 is for the Ubuntu VMs only (this machine reports '$(uname -s)')." >&2
    exit 1
  fi
}

# Usage: render_template <template-file> <dest-file> <VAR1> [<VAR2> ...]
# Substitutes every "@@VAR@@" in <template-file> with the current value of
# shell variable VAR (one already set, typically by config.sh), for each VAR
# named, writing the result to <dest-file>. Always fully overwrites <dest-file>
# so reruns can't leave a partially-substituted file behind.
render_template() {
  template="$1"
  dest="$2"
  shift 2
  sed_script=""
  for var in "$@"; do
    eval "val=\$$var"
    # Escape backslash, our '|' delimiter, and '&' (special in sed replacements).
    escaped=$(printf '%s' "$val" | sed -e 's/[\&|]/\\&/g')
    sed_script="${sed_script}s|@@${var}@@|${escaped}|g
"
  done
  sed -e "$sed_script" "$template" > "$dest"
}

# Usage: install_managed_block <block-content-file> <target-file>
# Inserts (or replaces) a marker-delimited block in <target-file>, leaving
# every other line in the file untouched. Safe to re-run: it always removes
# any previous laptop-config block before appending the current one, so the
# block never duplicates and always reflects the repo's current content.
install_managed_block() {
  block_file="$1"
  target="$2"
  begin_marker="# >>> laptop-config >>>"
  end_marker="# <<< laptop-config <<<"
  touch "$target"
  tmp="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$target" > "$tmp"
  {
    cat "$tmp"
    echo "$begin_marker"
    cat "$block_file"
    echo "$end_marker"
  } > "$target"
  rm -f "$tmp"
}

# Prints a file's mtime as a Unix timestamp. Tries GNU stat's syntax first
# (Ubuntu VMs), falls back to BSD stat's (macOS host) - the two disagree on
# flags and neither errors usefully on the other's, so this is the portable
# way to get one number out of either.
_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Usage: install_unless_locally_newer <src-file> <dest-file>
# Copies <src-file> to <dest-file>, unless <dest-file> already exists,
# differs in content from <src-file>, AND is newer than it - in that case
# someone edited the installed copy directly rather than the repo, so this
# warns and prints the command to pull that edit back into the repo instead
# of silently overwriting it.
install_unless_locally_newer() {
  src="$1"
  dest="$2"
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    if [ "$(_mtime "$dest")" -gt "$(_mtime "$src")" ]; then
      echo "WARNING: $dest is newer than $src and differs - leaving it alone." >&2
      echo "  To pull those changes back into the repo, run:" >&2
      echo "  cp \"$dest\" \"$src\"" >&2
      return 0
    fi
  fi
  cp "$src" "$dest"
}

# Usage: confirmation_done <name>
# True if <name> has previously been confirmed done (see mark_confirmed).
# For a manual step with no reliable way to check its actual state (a
# GUI-only System Settings toggle, say) - lets it prompt once instead of on
# every run. Stored per-checkout under confirmations/ (gitignored: host and
# each VM confirm their own steps independently, and it's not something
# anyone else's clone should inherit).
confirmation_done() {
  [ -f "$SCRIPT_DIR/confirmations/$1" ]
}

# Usage: mark_confirmed <name>
# Records that <name> is done, so confirmation_done <name> is true from
# here on.
mark_confirmed() {
  mkdir -p "$SCRIPT_DIR/confirmations"
  touch "$SCRIPT_DIR/confirmations/$1"
}

# Usage: confirm_once <name>
# Prompts once for whether <name> is actually done, defaulting to "no" (a
# bare Enter means "keep asking next run," not "assume it's done") - only
# an explicit yes calls mark_confirmed. Call this after printing whatever
# instructions <name> needs, and only inside an
# `if ! confirmation_done <name>; then ... fi` block, so it's never shown
# again once confirmed.
confirm_once() {
  name="$1"
  printf '%s' "Confirmed these are set - stop asking? [y/N] "
  read -r response
  case "$response" in
    y | Y | yes | YES) mark_confirmed "$name" ;;
    *) : ;;
  esac
}

# Sets the git config values that make git pleasant to use day-to-day.
# GIT_USER_NAME/GIT_USER_EMAIL come from config.sh; the rest are fixed
# defaults worth having everywhere (fsck on transfer/fetch catches repo
# corruption early, autosetupremote saves a step on first push of a branch).
configure_git_niceties() {
  git config --global user.name "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config --global init.defaultbranch main
  git config --global push.autosetupremote true
  git config --global transfer.fsckobjects true
  git config --global fetch.fsckobjects true
}
