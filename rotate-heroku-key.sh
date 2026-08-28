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
description="laptop-config"
if [ $# -ge 1 ]; then
  name="heroku-api-key@$1"
  description="laptop-config: $1"
fi

echo "== Rotating the Heroku API key =="
echo
echo "This doesn't run the Heroku CLI for you - use it wherever you have it"
echo "(this host, or any VM), then paste the result here:"
echo
echo "  1. heroku login"
echo "  2. heroku authorizations:create --description \"$description\" --short"
echo
echo "Deliberately not your account's single default API key from the Heroku"
echo "dashboard - regenerating that would break anything else using it, and"
echo "it silently expires whenever you change your account password. This"
echo "makes a separate, independently revocable token instead - the Heroku"
echo "dashboard has no web UI for creating one of those, only the CLI does."
echo

"$SCRIPT_DIR/host-secrets.sh" set "$name"

echo
echo "Stored as \"$name\". This doesn't touch any other secret - if this"
echo "replaces an existing key of the same name, heroku_session on the VM picks"
echo "up the new one immediately (it fetches fresh every time)."
echo
if [ $# -ge 1 ]; then
  echo "Try it: on $1 (only - this key is locked to that VM), run"
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
