#!/bin/sh
# rotate-heroku-key.sh - creates a new Heroku API token and stores it in
# Keychain under "heroku-api-key" (or "heroku-api-key@<vm-hostname>" if
# config.sh's HEROKU_API_KEY_VM is set, to lock it to a single VM - see
# architecture.md's Secrets Server section). Never touches any other
# secret - same "rotate first, cut over later" shape as
# rotate-github-pat.sh.
#
# Usage: rotate-heroku-key.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "rotate-heroku-key.sh"

name="heroku-api-key"
description="laptop-config"
if [ -n "$HEROKU_API_KEY_VM" ]; then
  name="heroku-api-key@$HEROKU_API_KEY_VM"
  description="laptop-config: $HEROKU_API_KEY_VM"
fi

echo "== Rotating the Heroku API key =="
echo
echo "Wherever you have the heroku CLI installed, run the following"
echo "(after ensuring there's no AI running on it to view the login):"
echo
echo "~~~"
echo "heroku login"
echo "heroku authorizations:create --description \"$description\" --short"
echo "heroku logout"
echo "~~~"
echo
echo "We deliberately do NOT use your account's single default API key from"
echo "the Heroku dashboard. Regenerating that would break anything else"
echo "using it, and it silently expires whenever you change your account"
echo "password. This makes a separate, independently revocable token"
echo "instead - the Heroku dashboard has no web UI for creating one, only"
echo "the CLI does."
echo
echo "The final \"heroku logout\" matters: \"heroku login\" writes a session"
echo "credential to ~/.netrc that we don't want lying around once we have"
echo "the dedicated token above - logout both removes it locally and"
echo "invalidates it server-side. The token from authorizations:create is"
echo "independent of that login session, so logging out doesn't affect it."
echo

"$SCRIPT_DIR/host-secrets.sh" set "$name"

echo
if [ -n "$HEROKU_API_KEY_VM" ]; then
  echo "Try it: on $HEROKU_API_KEY_VM (only - this key is locked to that VM), run"
else
  echo "Try it: on any VM, run"
fi
echo
echo "  heroku_session heroku auth:whoami"
echo
echo "That fetches the key (one approval dialog here on the host), runs"
echo "\"heroku auth:whoami\" with it set, and it's gone again once that"
echo "command exits. Run \"heroku_session\" with no arguments instead to drop"
echo "into a shell for a whole burst of heroku commands at once."
