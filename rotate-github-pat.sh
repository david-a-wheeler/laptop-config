#!/bin/sh
# rotate-github-pat.sh: creates a new GitHub PAT and stores it in Keychain
# under the name "github-pat", separately from actually switching the
# git-auth bridge over to it. Never touches config.sh or the currently
# active secret; the current setup keeps working unchanged while you run
# this, so there's no window where switching too early could break git
# push (real incident: almost happened by renaming config.sh's secret name
# before the new secret existed under it). GitHub PATs expire, so expect
# to run this at least once a year, or any time a token needs rotating for
# another reason (e.g. exposure).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "rotate-github-pat.sh"

echo "== Rotating the GitHub PAT =="
echo
echo "Create a new token: https://github.com/settings/tokens"
echo "  Generate new token (classic); scopes: repo, workflow."
if command -v open >/dev/null 2>&1; then
  open "https://github.com/settings/tokens" 2>/dev/null || true
fi
echo

"$SCRIPT_DIR/host-secrets.sh" set github-pat

echo
echo "Stored as \"github-pat\". This doesn't switch config.sh over or touch"
echo "any other secret; that's a separate, deliberate step once you've"
echo "confirmed this one works."
