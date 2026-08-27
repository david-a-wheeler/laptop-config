#!/bin/sh
# rotate-heroku-key.sh - creates a new Heroku API token and stores it in
# Keychain under "heroku-api-key" (or "heroku-api-key@<vm-hostname>" if
# you pass one, to lock it to a single VM - see architecture.md's Secrets
# Server section). Never touches config.sh or any other secret - same
# "rotate first, cut over later" shape as rotate-github-pat.sh.
#
# Usage: rotate-heroku-key.sh [vm-hostname]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "rotate-heroku-key.sh"

name="heroku-api-key"
if [ $# -ge 1 ]; then
  name="heroku-api-key@$1"
fi

echo "== Rotating the Heroku API key =="
echo
echo "This doesn't run the Heroku CLI for you - use it wherever you have it"
echo "(this host, or any VM), then paste the result here:"
echo
echo "  1. heroku login"
echo "  2. heroku authorizations:create --description \"laptop-config\" --short"
echo
echo "Deliberately not your account's single default API key from the Heroku"
echo "dashboard - regenerating that would break anything else using it. This"
echo "makes a separate, independently revocable token instead."
echo

"$SCRIPT_DIR/host-secrets.sh" set "$name"

echo
echo "Stored as \"$name\". This doesn't touch any other secret - if this"
echo "replaces an existing key of the same name, run_heroku on the VM picks"
echo "up the new one immediately (it fetches fresh every time)."
