#!/usr/bin/env python3
"""macOS Host Git Authorization Proxy Server.

Listens on the virtual bridge interface, queries Keychain for a named
secret, and prompts for human approval before releasing it. Generalized to
serve any secret stored in Keychain (not just a single GitHub PAT): the
caller (vm-git-helper.py, running in a VM) names which Keychain service it
wants via "secret_name" in the request payload, resolved on the VM side
from config.sh's GIT_SECRETS map. The approval dialog always names the
requested secret, so a request for something unexpected is easy to catch
and deny by hand, even though we don't otherwise restrict which service
name a caller may ask for.

Logs one JSON object per line to stdout (see log_event) for every request
this handles, approved/denied/errored - not just crashes. This exists
because of a real incident: the process was alive and correctly bound (the
actual cause turned out to be the VM's own egress firewall missing a rule
for this port - see nftables.template.conf), but the LaunchAgent's log
files sat empty the whole time regardless, which wasted real time
diagnosing "is it even receiving requests." Now every request leaves a
line, flushed immediately, whether or not anything goes wrong.

To test connectivity or the approval dialog itself without ever touching
the real secret, set "dry_run": true in a /token request - see
_handle_token_dry_run. This exists because of a second incident on the
same day: a raw curl test against a real request printed an actual token
in plaintext. dry_run makes that a non-issue by construction, not by
remembering to redact output - the server never reads the secret's value
out of Keychain at all when dry_run is set, so there's nothing to expose
regardless of how the response gets displayed.
"""
import json
import re
import socket
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_PORT = 9876


def log_event(level: str, event: str, **fields) -> None:
  """Writes one JSONL record to stdout and flushes immediately.

  The LaunchAgent redirects stdout to git_host_proxy.log with no terminal
  attached, and Python fully buffers stdout by default when it's not a
  tty - lines can sit unwritten until the process exits. flush=True here
  is what makes a log line show up right away instead. Never pass a field
  containing the actual secret/token value - secret_name (which one was
  requested) is fine to log, the secret itself is not.
  """
  record = {
      "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
      "level": level,
      "event": event,
  }
  record.update(fields)
  print(json.dumps(record, sort_keys=True), flush=True)


def get_virtual_bridge_ip() -> str:
  """Scans macOS interfaces for UTM/Virtualization bridge adapters."""
  try:
    virtual_ifaces = [
        name
        for _, name in socket.if_nameindex()
        if name.startswith(("bridge", "vmnet", "vnic"))
    ]
    for iface in virtual_ifaces:
      out = subprocess.check_output(
          ["ifconfig", iface], text=True, stderr=subprocess.DEVNULL
      )
      match = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out)
      if match:
        return match.group(1)
  except Exception:
    pass
  return "127.0.0.1"


def get_secret_from_keychain(service_name: str) -> str:
  """Retrieves a named secret directly from macOS Keychain."""
  try:
    return subprocess.check_output(
        [
            "security",
            "find-generic-password",
            "-s",
            service_name,
            "-w",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
  except subprocess.CalledProcessError:
    return ""


def keychain_secret_exists(service_name: str) -> bool:
  """Checks whether a named secret exists in Keychain, without reading its
  value (no "-w"). Used for dry-run requests, so testing connectivity or
  the approval flow can never actually pull a real secret out of Keychain -
  there's nothing to accidentally print, because nothing sensitive was ever
  read in the first place.
  """
  return subprocess.run(
      ["security", "find-generic-password", "-s", service_name],
      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
  ).returncode == 0


def _applescript_escape(s: str) -> str:
  """Escapes a string for safe embedding in an AppleScript string literal.

  repo_path/commit_info come from the requesting VM (commit_info is derived
  from a commit message, which is attacker-influenceable if you ever clone
  something untrusted), so without this a crafted value could break out of
  the quoted string and run arbitrary AppleScript via osascript.
  """
  return s.replace("\\", "\\\\").replace('"', '\\"')


class AuthProxyHandler(BaseHTTPRequestHandler):

  def do_POST(self):
    client_ip = self.client_address[0]
    log_event("info", "request_received", path=self.path, client=client_ip)

    if self.path != "/token":
      log_event("warning", "unknown_path", path=self.path, client=client_ip)
      self.send_response(404)
      self.end_headers()
      return

    content_length = int(self.headers.get("Content-Length", 0))
    body = self.rfile.read(content_length)

    try:
      payload = json.loads(body.decode("utf-8"))
    except Exception as e:
      log_event(
          "warning", "token_denied", reason="invalid_json",
          client=client_ip, detail=str(e),
      )
      self._respond({"status": "denied", "reason": "Invalid JSON"}, 400)
      return

    session_id = payload.get("session", "")
    repo_path = payload.get("path", "Unknown Path")
    commit_info = payload.get("commit", "No commit details")
    secret_name = payload.get("secret_name", "")

    if not session_id:
      log_event(
          "warning", "token_denied", reason="missing_session",
          client=client_ip, secret_name=secret_name,
      )
      self._respond(
          {"status": "denied", "reason": "Missing GIT_AUTH_SESSION"}, 403
      )
      return

    if not secret_name:
      log_event(
          "warning", "token_denied", reason="missing_secret_name",
          client=client_ip,
      )
      self._respond(
          {"status": "denied", "reason": "Missing secret_name"}, 400
      )
      return

    dry_run = bool(payload.get("dry_run", False))
    if dry_run:
      self._handle_token_dry_run(
          client_ip, secret_name, session_id, repo_path, commit_info
      )
      return

    secret = get_secret_from_keychain(secret_name)
    if not secret:
      log_event(
          "error", "token_error", reason="keychain_secret_not_found",
          client=client_ip, secret_name=secret_name,
      )
      self._respond(
          {"status": "error", "reason": "Keychain secret not found"}, 500
      )
      return

    prompt_text = (
        f"Git Authentication Request\n\n"
        f"Secret: {_applescript_escape(secret_name)}\n"
        f"Target Path: {_applescript_escape(repo_path)}\n"
        f"Local Context: {_applescript_escape(commit_info)}\n"
        f"Session ID: {_applescript_escape(session_id[:8])}...\n\n"
        f"Authorize access for this operation?"
    )

    log_event(
        "info", "token_prompt_shown", client=client_ip,
        secret_name=secret_name, session=session_id[:8], path=repo_path,
    )
    approved = self._show_approval_dialog(prompt_text)

    if approved:
      log_event(
          "info", "token_approved", client=client_ip,
          secret_name=secret_name, session=session_id[:8],
      )
      self._respond({"status": "approved", "token": secret}, 200)
    else:
      log_event(
          "info", "token_denied", reason="user_rejected", client=client_ip,
          secret_name=secret_name, session=session_id[:8],
      )
      self._respond(
          {"status": "denied", "reason": "User rejected request"}, 403
      )

  def _handle_token_dry_run(self, client_ip, secret_name, session_id,
                             repo_path, commit_info):
    """Exercises the full approval flow (Keychain lookup, dialog) without
    ever reading the secret's actual value - see keychain_secret_exists().
    The response has no "token" field either way, so there's nothing in it
    that could ever put a real secret in a terminal or a log by accident.
    This is the sanctioned way to test connectivity or the approval dialog:
    always set "dry_run": true rather than curling /token directly with a
    real request - see the incident noted in git log around this file.
    """
    if not keychain_secret_exists(secret_name):
      log_event(
          "error", "token_error", reason="keychain_secret_not_found",
          client=client_ip, secret_name=secret_name, dry_run=True,
      )
      self._respond(
          {
              "status": "error",
              "reason": "Keychain secret not found",
              "dry_run": True,
          },
          500,
      )
      return

    prompt_text = (
        f"TEST REQUEST - dry run, no secret will be released\n\n"
        f"Secret: {_applescript_escape(secret_name)}\n"
        f"Target Path: {_applescript_escape(repo_path)}\n"
        f"Local Context: {_applescript_escape(commit_info)}\n"
        f"Session ID: {_applescript_escape(session_id[:8])}...\n\n"
        f"This only tests connectivity and this dialog - nothing is "
        f"released either way."
    )
    log_event(
        "info", "token_dry_run_prompt_shown", client=client_ip,
        secret_name=secret_name, session=session_id[:8], path=repo_path,
    )
    approved = self._show_approval_dialog(
        prompt_text, title="Git Security Gatekeeper (TEST)"
    )
    log_event(
        "info", "token_dry_run_result", approved=approved, client=client_ip,
        secret_name=secret_name, session=session_id[:8],
    )
    self._respond(
        {"status": "approved" if approved else "denied", "dry_run": True},
        200 if approved else 403,
    )

  def _show_approval_dialog(self, prompt_text: str,
                             title: str = "Git Security Gatekeeper") -> bool:
    """Shows the AppleScript approval dialog; returns whether Authorize was
    clicked. Shared by the real and dry-run paths so there's exactly one
    place that builds and runs the osascript command. Logs a warning if
    osascript itself produced stderr output - that's how a dialog that
    failed to display (as opposed to a real Deny click) shows up.
    """
    applescript = (
        f'display dialog "{prompt_text}" with title'
        f' "{_applescript_escape(title)}"'
        ' buttons {"Deny", "Authorize"} default button "Deny"'
    )
    res = subprocess.run(
        ["osascript", "-e", applescript], capture_output=True, text=True
    )
    if res.stderr.strip():
      log_event(
          "warning", "approval_dialog_stderr",
          detail=res.stderr.strip(),
      )
    return "button returned:Authorize" in res.stdout

  def _respond(self, data, code=200):
    self.send_response(code)
    self.send_header("Content-Type", "application/json")
    self.end_headers()
    self.wfile.write(json.dumps(data).encode("utf-8"))

  def log_message(self, format, *args):
    # Suppressed in favor of the explicit log_event calls above, which
    # carry more useful structure than BaseHTTPRequestHandler's default
    # access-log line.
    pass


def main():
  listen_host = get_virtual_bridge_ip()
  log_event("info", "startup", listen_host=listen_host, listen_port=LISTEN_PORT)
  server = HTTPServer((listen_host, LISTEN_PORT), AuthProxyHandler)
  try:
    server.serve_forever()
  except KeyboardInterrupt:
    log_event("info", "shutdown", reason="keyboard_interrupt")


if __name__ == "__main__":
  main()
