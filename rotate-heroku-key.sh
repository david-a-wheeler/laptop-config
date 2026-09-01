#!/bin/sh
# rotate-heroku-key.sh: creates a new Heroku API token and stores it in
# Keychain under "HEROKU_API_KEY" (or "HEROKU_API_KEY@<vm-hostname>" if
# config.sh's HEROKU_API_KEY_VM is set, to lock it to a single VM: see
# architecture.md's Secrets Server section) - spelled like the environment
# variable heroku-session sets, the same convention GH_TOKEN uses. Never
# touches any other secret; it's the same "rotate first, cut over later"
# shape as rotate-github-pat.sh.
#
# Usage: rotate-heroku-key.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "rotate-heroku-key.sh"

name="HEROKU_API_KEY"
description="laptop-config"
if [ -n "$HEROKU_API_KEY_VM" ]; then
  name="HEROKU_API_KEY@$HEROKU_API_KEY_VM"
  description="laptop-config: $HEROKU_API_KEY_VM"
fi

cat <<EOF
== Rotating the Heroku API key ==

Wherever you have the heroku CLI installed, run the following
(after ensuring there's no AI running on it to view the login):

~~~
heroku login
heroku authorizations:create --description "$description" --short
heroku logout
~~~

We deliberately do NOT use your account's single default API key from
the Heroku dashboard. Regenerating that would break anything else
using it, and it silently expires whenever you change your account
password. This makes a separate, independently revocable token
instead: the Heroku dashboard has no web UI for creating one, only
the CLI does.

The final "heroku logout" matters: "heroku login" writes a session
credential to ~/.netrc that we don't want lying around once we have
the dedicated token above. Logout both removes it locally and
invalidates it server-side; the token from authorizations:create is
independent of that login session, so logging out doesn't affect it.

EOF

"$SCRIPT_DIR/host-secrets.sh" set "$name"

echo
if [ -n "$HEROKU_API_KEY_VM" ]; then
  echo "Try it: on $HEROKU_API_KEY_VM (only, since this key is locked to"
  echo "that VM), run"
else
  echo "Try it: on any VM, run"
fi
cat <<'EOF'

  heroku-session heroku auth:whoami

That fetches the key (one approval dialog here on the host), runs
"heroku auth:whoami" with it set, and it's gone again once that
command exits. Run "heroku-session" with no arguments instead to drop
into a shell for a whole burst of heroku commands at once.
EOF
cat <<EOF

== Once you've confirmed the new key works ==

authorizations:create above always mints a brand new authorization, so
any older "laptop-config"-described one is still valid on Heroku's side
until revoked. Rotating with the same VM lock produces the identical
description each time, so matching by description can't tell old from
new; this instead keeps only the single most recently created
laptop-config authorization (by "created_at", not by description) and
revokes every other one. This uses heroku-session rather than "heroku
login" to authenticate it, so it never touches ~/.netrc at all: there's
nothing to log out of afterward.
EOF
echo
if [ -n "$HEROKU_API_KEY_VM" ]; then
  echo "On $HEROKU_API_KEY_VM (only, since the key's locked to that VM), run:"
else
  echo "On any VM, run:"
fi
cat <<'EOF'

~~~
heroku-session
heroku authorizations -j | jq -r \
  '[.[] | select(.description | startswith("laptop-config"))] |
   sort_by(.created_at) | reverse | .[1:] | .[] | .id' |
while IFS= read -r id; do
  heroku authorizations:revoke "$id"
done
exit
~~~
EOF
