#!/usr/bin/env python3
"""Ubuntu VM Git Credential Helper.

Speaks git's credential-helper stdin/stdout format only; the actual
secrets_server.py request is delegated to secrets-client.py (get
<name>), the same generic client heroku_session/gh_session already use,
rather than reimplementing that HTTP call here too. Which secret to ask
for is resolved from the git host git is asking about (GIT_SECRETS
below, baked in from config.sh's GIT_SECRETS at install time by
vm-setup.sh); the name passed to secrets-client.py is always the short,
unprefixed logical name, since secrets_server.py applies KEYCHAIN_PREFIX
itself. A host with no entry here is refused without ever running
secrets-client.py, so only git hosts you've deliberately configured are
handled.

Rendered from vm-git-helper.template.py by vm-setup.sh: edit the template,
not the installed copy, since a re-run of vm-setup.sh overwrites this file.
"""
import subprocess
import sys

GIT_SECRETS = @@GIT_SECRETS_PY_DICT@@


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

  secret_name = GIT_SECRETS.get(input_data.get("host", ""), "")
  if not secret_name:
    # No secret configured for this git host: fail closed without ever
    # running secrets-client.py.
    sys.exit(1)

  try:
    commit_summary = subprocess.check_output(
        ["git", "log", "-1", "--oneline"], text=True, stderr=subprocess.DEVNULL
    ).strip()
  except Exception:
    commit_summary = "Non-repository or working directory"

  # "secrets-client.py" (bare name, not a relative path) is found via
  # $PATH regardless of the current directory: vm-setup.sh installs it
  # to /usr/local/bin alongside this file. Session id (from
  # LAPTOP_CONFIG_AUTH_SESSION) is picked up by secrets-client.py itself
  # from the environment it inherits from us. stderr is left connected to
  # ours (not captured) so a denial reason lands on the human's terminal
  # instead of vanishing silently.
  try:
    token = subprocess.check_output(
        ["secrets-client.py", "get", secret_name, "--context", commit_summary],
        text=True,
    ).strip()
  except subprocess.CalledProcessError:
    sys.exit(1)

  print("username=x-access-token")
  print(f"password={token}")


if __name__ == "__main__":
  main()
