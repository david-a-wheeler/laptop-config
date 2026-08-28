"""Unit tests for secrets_server.template.py. Run via ci.sh, or directly:
  python3 -m unittest discover -s tests -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_helper import render_and_import

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_secrets_server():
  return render_and_import(
      os.path.join(REPO_ROOT, "secrets_server.template.py"),
      "secrets_server_under_test",
      SECRETS_SERVER_PORT="9876",
      KEYCHAIN_PREFIX="laptop-config-",
      UTMCTL="/usr/bin/true",
  )


class ApplescriptEscapeTests(unittest.TestCase):
  """_applescript_escape() is the only thing standing between an
  attacker-influenceable value (a git commit message, a client-supplied
  secret name) and arbitrary AppleScript execution via osascript."""

  def setUp(self):
    self.server = load_secrets_server()

  def test_escapes_double_quotes(self):
    self.assertEqual(
        self.server._applescript_escape('say "hi"'), 'say \\"hi\\"'
    )

  def test_escapes_backslashes(self):
    self.assertEqual(self.server._applescript_escape("a\\b"), "a\\\\b")

  def test_plain_text_unchanged(self):
    self.assertEqual(
        self.server._applescript_escape("heroku-api-key"), "heroku-api-key"
    )

  def test_injection_attempt_is_neutralized(self):
    hostile = '" with title "pwned'
    escaped = self.server._applescript_escape(hostile)
    self.assertNotIn('" with title "pwned', escaped)


class VmLockFallbackTests(unittest.TestCase):
  """get_secret_from_keychain()'s entire VM-locking mechanism: try the
  locked name first, fall back to the unlocked name. This is the same
  behavior verified by hand (mocked "security" calls) while building it;
  now it's checked automatically instead of by memory.
  """

  def setUp(self):
    self.server = load_secrets_server()

  def test_locked_variant_found_first(self):
    calls = []

    def fake_read(name):
      calls.append(name)
      return "SECRET" if name == "laptop-config-heroku-api-key@lftux" else ""

    self.server._keychain_read = fake_read
    result = self.server.get_secret_from_keychain("heroku-api-key", "lftux")
    self.assertEqual(result, "SECRET")
    self.assertEqual(calls[0], "laptop-config-heroku-api-key@lftux")

  def test_falls_back_to_unlocked_when_no_locked_entry(self):
    def fake_read(name):
      return "SECRET" if name == "laptop-config-heroku-api-key" else ""

    self.server._keychain_read = fake_read
    result = self.server.get_secret_from_keychain("heroku-api-key", "lftux")
    self.assertEqual(result, "SECRET")

  def test_no_vm_hostname_skips_locked_lookup_entirely(self):
    calls = []

    def fake_read(name):
      calls.append(name)
      return "SECRET"

    self.server._keychain_read = fake_read
    self.server.get_secret_from_keychain("heroku-api-key", "")
    self.assertEqual(calls, ["laptop-config-heroku-api-key"])

  def test_not_found_anywhere_returns_empty(self):
    self.server._keychain_read = lambda name: ""
    result = self.server.get_secret_from_keychain("nonexistent", "lftux")
    self.assertEqual(result, "")


if __name__ == "__main__":
  unittest.main()
