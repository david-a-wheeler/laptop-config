#!/bin/sh
# rotate-github-pat.sh: rotates both GitHub PATs this repo stores, one
# after another: GH_TOKEN (a classic PAT, scopes repo+workflow; backs
# git's HTTPS auth and gh_session) and GH_PUBLIC_TOKEN! (a fine-grained
# PAT scoped to "Public Repositories (read-only)"; backs anon-access, so
# gh(1) works for a sandboxed AI agent reading public data without ever
# handing it real access). The trailing "!" is deliberate, not a typo:
# it's what marks a Keychain entry as releasable with no confirmation
# dialog (see secrets_server.template.py's _resolve()); everything else
# defaults to requiring one. Rotated together since both typically
# expire on the same org-enforced schedule; press Enter at either
# prompt to leave that one secret unchanged if it hasn't actually
# expired yet.
#
# Never touches config.sh or the currently active secrets; the current
# setup keeps working unchanged while you run this, so there's no window
# where switching too early could break git push (real incident: almost
# happened by renaming config.sh's secret name before the new secret
# existed under it).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "rotate-github-pat.sh"

# $1: secret name (Keychain/env var). $2: token-creation URL. $3: what
# to actually select on that page. One shared shape (print instructions,
# open the browser, hand off to host-secrets.sh set, which itself
# accepts a bare Enter to leave an existing secret unchanged); the two
# calls below differ only in these three strings.
rotate_one() {
  name="$1"
  url="$2"
  recipe="$3"
  cat <<EOF

== Rotating $name ==

Create a new token: $url
  $recipe
EOF
  if command -v open >/dev/null 2>&1; then
    open "$url" 2>/dev/null || true
  fi
  "$SCRIPT_DIR/host-secrets.sh" set "$name"
}

rotate_one GH_TOKEN \
  "https://github.com/settings/tokens" \
  "Generate new token (classic); scopes: repo, workflow."

rotate_one 'GH_PUBLIC_TOKEN!' \
  "https://github.com/settings/personal-access-tokens/new" \
  "Repository access: Public Repositories (read-only); no permissions needed."

cat <<'EOF'

This doesn't switch config.sh over or touch any other secret; that's a
separate, deliberate step once you've confirmed these work.

Try it: on any VM, "git push"/"git fetch" and "gh_session gh auth
status" exercise GH_TOKEN (one approval dialog each). "anon-access gh
issue view https://github.com/cli/cli/issues/13307" exercises
GH_PUBLIC_TOKEN, released with no dialog at all (the trailing "!" on
how it's stored is what does that), since anon-access substitutes it
for GH_TOKEN/GITHUB_TOKEN before a sandboxed agent ever runs.
EOF
