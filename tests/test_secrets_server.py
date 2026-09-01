"""Unit tests for secrets-server.template.py. Run via ci.sh, or directly:
  python3 -m unittest discover -s tests -v

This file's own name (and load_secrets_server()'s) keeps the underscore
"secrets_server" spelling despite the file it tests being renamed to
secrets-server.template.py: unlike that file (never `import`ed, only
rendered and exec'd, or run standalone), this one IS a real Python
module `unittest discover` imports by name, so it has to stay a valid
identifier - a hyphen isn't legal in one.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_helper import render_and_import

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_secrets_server():
  return render_and_import(
      os.path.join(REPO_ROOT, "secrets-server.template.py"),
      "secrets_server_under_test",
      SECRETS_SERVER_PORT="9876",
      KEYCHAIN_PREFIX="bulkhead-",
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
  """get_secret_from_keychain()'s VM-locking mechanism: try the
  most-specific variant first (locked + no-confirmation), down to the
  plain unlocked name. This is the same behavior verified by hand
  (mocked "security" calls) while building it; now it's checked
  automatically instead of by memory.
  """

  def setUp(self):
    self.server = load_secrets_server()

  def test_locked_variant_found_first(self):
    calls = []

    def fake_read(name):
      calls.append(name)
      return "SECRET" if name == "bulkhead-heroku-api-key@lftux" else ""

    self.server.retrieve_secret = fake_read
    result = self.server.get_secret_from_keychain("heroku-api-key", "lftux")
    self.assertEqual(result, "SECRET")
    # Tries the more-specific locked+no-confirmation variant first (not
    # found here), then the plain locked variant (found) - never
    # reaches either unlocked tier.
    self.assertEqual(calls, [
        "bulkhead-heroku-api-key@lftux!",
        "bulkhead-heroku-api-key@lftux",
    ])

  def test_falls_back_to_unlocked_when_no_locked_entry(self):
    def fake_read(name):
      return "SECRET" if name == "bulkhead-heroku-api-key" else ""

    self.server.retrieve_secret = fake_read
    result = self.server.get_secret_from_keychain("heroku-api-key", "lftux")
    self.assertEqual(result, "SECRET")

  def test_no_vm_hostname_skips_locked_lookup_entirely(self):
    calls = []

    def fake_read(name):
      calls.append(name)
      return "SECRET" if name == "bulkhead-heroku-api-key" else ""

    self.server.retrieve_secret = fake_read
    result = self.server.get_secret_from_keychain("heroku-api-key", "")
    self.assertEqual(result, "SECRET")
    # No vm_hostname: only the two unlocked tiers are tried; no "@"
    # variant appears at all.
    self.assertEqual(calls, [
        "bulkhead-heroku-api-key!",
        "bulkhead-heroku-api-key",
    ])

  def test_not_found_anywhere_returns_empty(self):
    self.server.retrieve_secret = lambda name: ""
    result = self.server.get_secret_from_keychain("nonexistent", "lftux")
    self.assertEqual(result, "")


class NoConfirmationNamingTests(unittest.TestCase):
  """needs_confirmation() (and get_secret_from_keychain's matching tier)
  are both driven by _resolve()'s "<name>!" convention: default-safe
  (True, a dialog is shown) for anything not stored under a
  "!"-suffixed name, and composes with VM-locking.
  """

  def setUp(self):
    self.server = load_secrets_server()

  def test_unlocked_bang_skips_confirmation(self):
    self.server.secret_exists = (
        lambda name: name == "bulkhead-GH_PUBLIC_TOKEN!"
    )
    self.assertFalse(self.server.needs_confirmation("GH_PUBLIC_TOKEN", ""))

  def test_plain_name_requires_confirmation(self):
    self.server.secret_exists = lambda name: name == "bulkhead-GH_TOKEN"
    self.assertTrue(self.server.needs_confirmation("GH_TOKEN", ""))

  def test_locked_bang_skips_confirmation(self):
    self.server.secret_exists = (
        lambda name: name == "bulkhead-SOME_SECRET@mytux!"
    )
    self.assertFalse(self.server.needs_confirmation("SOME_SECRET", "mytux"))

  def test_locked_without_bang_requires_confirmation(self):
    self.server.secret_exists = (
        lambda name: name == "bulkhead-SOME_SECRET@mytux"
    )
    self.assertTrue(self.server.needs_confirmation("SOME_SECRET", "mytux"))

  def test_nothing_stored_defaults_to_requiring_confirmation(self):
    self.server.secret_exists = lambda name: False
    self.assertTrue(self.server.needs_confirmation("NEVER_STORED", ""))


class SessionApprovalTrackingTests(unittest.TestCase):
  """session_previously_approved()/mark_session_approved() drive the
  approval dialog's default button: Deny until a session id has had at
  least one approval, Authorize after. In-memory only (see the module
  docstring), so each test gets a fresh, empty set via load_secrets_server()
  (render_and_import() never registers the module in sys.modules, so
  there's nothing for one test to leak into another).
  """

  def setUp(self):
    self.server = load_secrets_server()

  def test_unseen_session_not_previously_approved(self):
    self.assertFalse(self.server.session_previously_approved("session-a"))

  def test_marking_approved_is_remembered(self):
    self.server.mark_session_approved("session-a")
    self.assertTrue(self.server.session_previously_approved("session-a"))

  def test_different_sessions_tracked_independently(self):
    self.server.mark_session_approved("session-a")
    self.assertFalse(self.server.session_previously_approved("session-b"))


if __name__ == "__main__":
  unittest.main()
