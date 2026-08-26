#!/usr/bin/env python3
"""macOS Host Git Authorization Proxy Server.

Listens on the virtual bridge interface, queries Keychain, and prompts for
human approval.
"""
import json
import re
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_PORT = 9876
KEYCHAIN_SERVICE_NAME = "git-host-proxy-pat"


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


def get_token_from_keychain() -> str:
  """Retrieves the encrypted GitHub PAT directly from macOS Keychain."""
  try:
    return subprocess.check_output(
        [
            "security",
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE_NAME,
            "-w",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
  except subprocess.CalledProcessError:
    return ""


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

    if not session_id:
      self._respond(
          {"status": "denied", "reason": "Missing GIT_AUTH_SESSION"}, 403
      )
      return

    token = get_token_from_keychain()
    if not token:
      self._respond(
          {"status": "error", "reason": "Keychain secret not found"}, 500
      )
      return

    prompt_text = (
        f"Git Authentication Request\n\n"
        f"Target Path: {repo_path}\n"
        f"Local Context: {commit_info}\n"
        f"Session ID: {session_id[:8]}...\n\n"
        f"Authorize token access for this operation?"
    )

    applescript = (
        f'display dialog "{prompt_text}" with title "Git Security Gatekeeper"'
        ' buttons {"Deny", "Authorize"} default button "Deny"'
    )

    res = subprocess.run(
        ["osascript", "-e", applescript], capture_output=True, text=True
    )

    if "button returned:Authorize" in res.stdout:
      self._respond({"status": "approved", "token": token}, 200)
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
