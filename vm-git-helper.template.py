#!/usr/bin/env python3
"""Ubuntu VM Git Credential Helper.

Dynamically finds the host default gateway and requests an ephemeral auth
token from git_host_proxy.py running on the macOS host. Generalized: which
Keychain secret to ask for is resolved from the git host git is asking about
(GIT_SECRETS below, baked in from config.sh's GIT_SECRETS at install time by
vm-setup.sh). A host with no entry here is refused without ever contacting
the proxy, so only git hosts you've deliberately configured are handled.

Rendered from vm-git-helper.template.py by vm-setup.sh - edit the template,
not the installed copy, since a re-run of vm-setup.sh overwrites this file.
"""
import json
import os
import subprocess
import sys
import urllib.request

HOST_PROXY_PORT = @@HOST_PROXY_PORT@@
GIT_SECRETS = @@GIT_SECRETS_PY_DICT@@


def get_default_gateway() -> str:
  try:
    return subprocess.check_output(
        "ip route | awk '/default/ {print $3}'", shell=True, text=True
    ).strip()
  except Exception:
    return "192.168.64.1"


def main():
  if len(sys.argv) < 2 or sys.argv[1] != "get":
    return

  input_data = {}
  for line in sys.stdin:
    line = line.strip()
    if not line:
      break
    if "=" in line:
      key, val = line.split("=", 1)
      input_data[key] = val

  host = input_data.get("host", "")
  secret_name = GIT_SECRETS.get(host, "")
  if not secret_name:
    # No secret configured for this git host - fail closed without ever
    # contacting the host proxy.
    sys.exit(1)

  session_id = os.environ.get("GIT_AUTH_SESSION", "")

  try:
    commit_summary = subprocess.check_output(
        ["git", "log", "-1", "--oneline"], text=True, stderr=subprocess.DEVNULL
    ).strip()
  except Exception:
    commit_summary = "Non-repository or working directory"

  payload = {
      "session": session_id,
      "protocol": input_data.get("protocol", "https"),
      "host": host,
      "path": input_data.get("path", ""),
      "commit": commit_summary,
      "secret_name": secret_name,
  }

  host_ip = get_default_gateway()
  proxy_url = f"http://{host_ip}:{HOST_PROXY_PORT}/token"

  req = urllib.request.Request(
      proxy_url,
      data=json.dumps(payload).encode("utf-8"),
      headers={"Content-Type": "application/json"},
  )

  try:
    with urllib.request.urlopen(req, timeout=30) as resp:
      result = json.loads(resp.read().decode("utf-8"))
      if result.get("status") == "approved" and "token" in result:
        print("username=x-access-token")
        print(f"password={result['token']}")
        sys.exit(0)
      else:
        sys.exit(1)
  except Exception:
    sys.exit(1)


if __name__ == "__main__":
  main()
