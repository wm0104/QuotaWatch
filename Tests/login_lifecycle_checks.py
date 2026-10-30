"""Regression guard: covering AccountEditor with Safari is not a user cancellation.

These are source-level checks, not a claim that UIKit lifecycle was tested on a device.
The real iOS 16 presentation and OAuth round trip still require device validation.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LoginLifecycleChecks(unittest.TestCase):
    def setUp(self):
        self.editor = (ROOT / 'QuotaWatch/AccountEditor.swift').read_text().split('struct RuleEditor:')[0]
        self.oauth = (ROOT / 'QuotaWatch/CodexOAuth.swift').read_text()

    def test_covering_editor_does_not_cancel_login(self):
        self.assertNotRegex(self.editor, r'\.onDisappear\s*\{')
        self.assertIn('operation = Task {', self.editor)
        self.assertIn('try await store.add(', self.editor)

    def test_explicit_user_cancel_is_preserved(self):
        self.assertIn('operation?.cancel(); store.oauth.cancel(); dismiss()', self.editor)
        self.assertIn('.interactiveDismissDisabled(saving)', self.editor)
        self.assertIn('if !Task.isCancelled { dismiss() }', self.editor)

    def test_browser_cancel_and_timeout_cleanup_are_preserved(self):
        self.assertIn('func safariViewControllerDidFinish', self.oauth)
        self.assertIn('func presentationControllerDidDismiss', self.oauth)
        self.assertIn('loginTimeoutNanoseconds: UInt64 = 180_000_000_000', self.oauth)
        self.assertIn('withTaskCancellationHandler', self.oauth)
        self.assertIn('listener?.cancel()', self.oauth)
        self.assertIn('pending?.resume(with: result)', self.oauth)


if __name__ == '__main__':
    unittest.main(verbosity=2)
