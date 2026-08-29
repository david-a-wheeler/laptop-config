#!/bin/sh
# ci.sh: runs every check this repo has (shellcheck, syntax checks, a
# couple of logic tests). Run it locally before committing; .github/
# workflows/ci.yml just calls this same script, so local and CI runs are
# always identical, never two checklists that can drift apart.
#
# Usage: ./ci.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
step() {
  echo
  echo "== $1 =="
}

# Plain scripts: no @@VAR@@ templating, safe to check as-is.
PLAIN_SCRIPTS="config.sh common.sh host-setup.sh vm-setup.sh host-secrets.sh rotate-github-pat.sh rotate-heroku-key.sh"

step "shellcheck (plain scripts)"
# shellcheck disable=SC2086
if ! shellcheck -x $PLAIN_SCRIPTS; then
  fail=1
fi

step "dash -n (plain scripts)"
for f in $PLAIN_SCRIPTS; do
  if ! dash -n "$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done

step "rendering and checking templates"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

NONO_EXTRA_READ_ARGS="--read $HOME/.rbenv "
render_template vm-bash-aliases-block.template.sh "$tmp/bash-aliases.sh" NONO_EXTRA_READ_ARGS
if ! dash -n "$tmp/bash-aliases.sh"; then
  echo "FAILED: vm-bash-aliases-block.template.sh (dash -n)" >&2
  fail=1
fi
if ! bash -n "$tmp/bash-aliases.sh"; then
  echo "FAILED: vm-bash-aliases-block.template.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x -s bash "$tmp/bash-aliases.sh"; then
  fail=1
fi

GIT_SECRETS_PY_DICT='{"github.com": "GH_TOKEN"}'
render_template vm-git-helper.template.py "$tmp/vm-git-helper.py" SECRETS_SERVER_PORT GIT_SECRETS_PY_DICT
render_template secrets-client.template.py "$tmp/secrets-client.py" SECRETS_SERVER_PORT
render_template secrets_server.template.py "$tmp/secrets_server.py" \
  SECRETS_SERVER_PORT KEYCHAIN_PREFIX UTMCTL
for f in vm-git-helper.py secrets-client.py secrets_server.py; do
  if ! python3 -m py_compile "$tmp/$f"; then
    echo "FAILED: $f (py_compile)" >&2
    fail=1
  fi
done

step "python unit tests (tests/)"
# tests/render_helper.py renders a template in memory and imports it as a
# real module, so these exercise the actual logic (not a reimplementation
# of it) without needing a macOS host, Keychain, or network. Add new test
# files under tests/ named test_*.py and this picks them up automatically.
if ! python3 -m unittest discover -s "$SCRIPT_DIR/tests" -v; then
  fail=1
fi

step "jq revoke-filter logic (rotate-heroku-key.sh's auto-revoke query)"
# This is the trickiest logic in the repo, and it had a real bug once
# (matching by description instead of created_at silently revoked
# nothing on any routine same-VM rotation, since the old and new
# authorizations share an identical description). This fixture
# reproduces exactly that: two entries with the same description, one
# older, plus an unrelated third entry that must never be touched.
cat > "$tmp/fake_authorizations.json" <<'EOF'
[
  {"id": "OLD-1111-1111-1111-111111111111", "description": "laptop-config: lftux", "created_at": "2026-01-15T10:00:00-00:00"},
  {"id": "NEW-2222-2222-2222-222222222222", "description": "laptop-config: lftux", "created_at": "2026-08-28T14:30:00-00:00"},
  {"id": "OTHER-333-333-333-333333333333", "description": "Heroku Dashboard", "created_at": "2026-08-28T14:31:00-00:00"}
]
EOF
result="$(jq -r '
  [.[] | select(.description | startswith("laptop-config"))] |
  sort_by(.created_at) | reverse | .[1:] | .[] | .id
' "$tmp/fake_authorizations.json")"
if [ "$result" != "OLD-1111-1111-1111-111111111111" ]; then
  echo "FAILED: expected only the old entry's ID, got:" >&2
  echo "$result" >&2
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED (see above)." >&2
  exit 1
fi
