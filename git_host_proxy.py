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
"""
import json
import re
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_PORT = 9876


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
    if self.path != "/token":
      self.send_response(404)
      self.end_headers()
      return

    content_length = int(self.headers.get("Content-Length", 0))
    body = self.rfile.read(content_length)

    try:
      payload = json.loads(body.decode("utf-8"))
    except Exception:
      self._respond({"status": "denied", "reason": "Invalid JSON"}, 400)
      return

    session_id = payload.get("session", "")
    repo_path = payload.get("path", "Unknown Path")
    commit_info = payload.get("commit", "No commit details")
    secret_name = payload.get("secret_name", "")

    if not session_id:
      self._respond(
          {"status": "denied", "reason": "Missing GIT_AUTH_SESSION"}, 403
      )
      return

    if not secret_name:
      self._respond(
          {"status": "denied", "reason": "Missing secret_name"}, 400
      )
      return

    secret = get_secret_from_keychain(secret_name)
    if not secret:
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

    applescript = (
        f'display dialog "{prompt_text}" with title "Git Security Gatekeeper"'
        ' buttons {"Deny", "Authorize"} default button "Deny"'
    )

    res = subprocess.run(
        ["osascript", "-e", applescript], capture_output=True, text=True
    )

    if "button returned:Authorize" in res.stdout:
      self._respond({"status": "approved", "token": secret}, 200)
    else:
      self._respond(
          {"status": "denied", "reason": "User rejected request"}, 403
      )

  def _respond(self, data, code=200):
    self.send_response(code)
    self.send_header("Content-Type", "application/json")
    self.end_headers()
    self.wfile.write(json.dumps(data).encode("utf-8"))

  def log_message(self, format, *args):
    pass


def main():
  listen_host = get_virtual_bridge_ip()
  print(f"[*] Host Auth Proxy listening on {listen_host}:{LISTEN_PORT}")
  server = HTTPServer((listen_host, LISTEN_PORT), AuthProxyHandler)
  try:
    server.serve_forever()
  except KeyboardInterrupt:
    print("\n[*] Shutting down.")


if __name__ == "__main__":
  main()
