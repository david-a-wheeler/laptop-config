#!/usr/bin/env python3
"""VM-side generic secrets-server client.

Fetches one named secret from secrets-server.py on the macOS host, over
the same request/response protocol vm-git-helper.py already speaks (minus
git's credential-helper-specific stdin/stdout format), as a reusable
primitive for any VM-side script that needs a host-held secret released
with human approval, not just git. secret_session() (see
vm-bash-aliases-block.template.sh; heroku_session and gh_session are both
thin wrappers over it) is the generic non-git caller.

Usage: secrets-client.py get <name> [--context TEXT]
Prints the secret to stdout and exits 0 on success; prints an error to
stderr and exits nonzero otherwise (denied, not found, unreachable). "name"
is always the short logical name (e.g. "GH_TOKEN", "HEROKU_API_KEY", spelled
like the environment variable it stands in for wherever one exists); secrets-server.py
applies KEYCHAIN_PREFIX and any VM-lock suffix itself.

Requires LAPTOP_CONFIG_AUTH_SESSION to be set (see
vm-bash-aliases-block.template.sh, which generates one for every human
interactive shell). Without it, the server denies the request without
ever consulting Keychain, same as any other caller. noclaude() strips it
before an AI agent ever runs, so a sandboxed agent can never use this
script to reach a real secret either.

Rendered from secrets-client.template.py by vm-setup.sh: edit the
template, not the installed copy, since a re-run of vm-setup.sh overwrites
this file.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

SECRETS_SERVER_PORT = @@SECRETS_SERVER_PORT@@


def get_default_gateway() -> str:
  try:
    return subprocess.check_output(
        "ip route | awk '/default/ {print $3}'", shell=True, text=True
    ).strip()
  except Exception:
    return "192.168.64.1"


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("action", choices=["get"])
  parser.add_argument("name", help="short logical secret name, e.g. GH_TOKEN")
  parser.add_argument(
      "--context", default="secrets-client.py request",
      help="shown to the human in the approval dialog",
  )
  args = parser.parse_args()

  payload = {
      "session": os.environ.get("LAPTOP_CONFIG_AUTH_SESSION", ""),
      "path": os.getcwd(),
      "context": args.context,
      "secret_name": args.name,
  }

  host_ip = get_default_gateway()
  server_url = f"http://{host_ip}:{SECRETS_SERVER_PORT}/secret"

  req = urllib.request.Request(
      server_url,
      data=json.dumps(payload).encode("utf-8"),
      headers={"Content-Type": "application/json"},
  )

  try:
    with urllib.request.urlopen(req, timeout=30) as resp:
      result = json.loads(resp.read().decode("utf-8"))
  except urllib.error.HTTPError as e:
    try:
      result = json.loads(e.read().decode("utf-8"))
    except Exception:
      result = {}
    print(f"secrets-client: {result.get('reason', f'HTTP {e.code}')}", file=sys.stderr)
    sys.exit(1)
  except Exception as e:
    print(f"secrets-client: couldn't reach the secrets server: {e}", file=sys.stderr)
    sys.exit(1)

  if result.get("status") == "approved" and "token" in result:
    print(result["token"])
    sys.exit(0)
  else:
    print(f"secrets-client: {result.get('reason', 'denied')}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
  main()
