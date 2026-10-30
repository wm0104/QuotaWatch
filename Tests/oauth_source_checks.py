#!/usr/bin/env python3
"""Offline structural checks only; iOS compilation/runtime coverage belongs to CI."""
from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "QuotaWatch" / "CodexOAuth.swift"


class OAuthSourceChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def section(self, start, end):
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_contract_api_and_no_duplicate_core_types(self):
        self.assertRegex(self.source, r"@MainActor\s+final class CodexOAuth: NSObject, ObservableObject")
        for declaration in (
            "@Published private(set) var isLoggingIn = false",
            "func login() async throws -> Credential",
            "func cancel()",
            "static func refresh(_ existing: Credential) async throws -> Credential",
        ):
            self.assertIn(declaration, self.source)
        self.assertNotRegex(self.source, r"(?:struct|enum|class)\s+(?:Credential|QuotaError)\b")

    def test_public_configuration(self):
        for value in (
            '"app_EMoamEEZ73f0CkXaXp7hrann"',
            '"https://auth.openai.com/oauth/authorize"',
            '"https://auth.openai.com/oauth/token"',
            '"http://localhost:1455/auth/callback"',
        ):
            self.assertIn(value, self.source)
        auth = self.section("private static func authorizationURL", "private static func randomURLSafeString")
        for key, value in (
            ("response_type", "code"),
            ("scope", "openid profile email offline_access"),
            ("code_challenge_method", "S256"),
            ("codex_cli_simplified_flow", "true"),
            ("originator", "codex_cli_rs"),
            ("id_token_add_organizations", "true"),
            ("prompt", "select_account"),
        ):
            self.assertIn(f'URLQueryItem(name: "{key}", value: "{value}")', auth)

    def test_pkce_and_random_state(self):
        self.assertIn("SHA256.hash(data: Data(verifier.utf8))", self.source)
        self.assertIn("SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)", self.source)
        self.assertIn("[UInt8](repeating: 0, count: 32)", self.source)
        begin = self.section("private func beginLogin", "private func listenerChanged")
        self.assertEqual(begin.count("try Self.randomURLSafeString()"), 2)
        self.assertIn('URLQueryItem(name: "code_challenge", value: challenge)', self.source)
        self.assertIn('URLQueryItem(name: "state", value: state)', self.source)

    def test_explicit_loopback_only_and_no_port_fallback(self):
        begin = self.section("private func beginLogin", "private func listenerChanged")
        self.assertRegex(begin, r'requiredLocalEndpoint\s*=\s*\.hostPort\(\s*host: NWEndpoint.Host\("127\.0\.0\.1"\)')
        self.assertIn("parameters.allowLocalEndpointReuse = false", begin)
        self.assertEqual(self.source.count("NWListener(using:"), 1)
        self.assertIn("try NWListener(using: parameters)", begin)
        self.assertIn("private static let callbackPort: NWEndpoint.Port = 1455", self.source)
        self.assertIn("guard listener?.port == Self.callbackPort", self.source)
        self.assertNotRegex(self.source, r'NWEndpoint.Host\("(?:0\.0\.0\.0|::)"\)|on:\s*\.any')

    def test_listener_failure_precedes_presentation(self):
        state = self.section("private func listenerChanged", "func safariViewControllerDidFinish")
        self.assertLess(state.index("case .ready:"), state.index("presenter.present(browser"))
        self.assertIn("case .failed(_), .waiting(_):", state)
        self.assertIn("finish(.failure(Self.listenerError()), for: id)", state)

    def test_callback_bounds_and_timeouts(self):
        for fragment in (
            "maximumHeaderBytes = 16 * 1024", "maximumPeers = 8",
            "loginTimeoutNanoseconds: UInt64 = 180_000_000_000",
            "peerTimeoutNanoseconds: UInt64 = 10_000_000_000",
            "peer.header.count + data.count <= Self.maximumHeaderBytes",
            "peers.count < Self.maximumPeers", "maximumLength: 4096",
            "target.utf8.count <= 8192", "pairs.count <= 32",
            "end.upperBound == peer.header.endIndex",
        ):
            self.assertIn(fragment, self.source)

    def test_http_exact_path_host_method_and_query_validation(self):
        parser = self.section("private static func parseRequest", "private func handleCallback")
        for fragment in (
            'parts[0] == "GET"', "pathAndQuery.first == Substring(callbackPath)",
            'host == "localhost:1455" || host == "127.0.0.1:1455"',
            "guard host == nil", 'case "transfer-encoding":',
            'contentLength == nil, value == "0"', "parameters[key] == nil",
            "removingPercentEncoding", 'replacingOccurrences(of: "+", with: " ")',
        ):
            self.assertIn(fragment, parser)
        self.assertIn('callbackPath = "/auth/callback"', self.source)

    def test_state_before_code_exchange_and_once_only(self):
        callback = self.section("private func handleCallback", "private func respond")
        self.assertLess(callback.index("Self.constantTimeEqual(state, expected)"), callback.index("Self.requestTokens"))
        self.assertLess(callback.index("callbackConsumed = true"), callback.index("Self.requestTokens"))
        self.assertIn("!callbackConsumed", callback)
        self.assertIn('parameters["code"] == nil || parameters["error"] == nil', callback)
        self.assertIn('error == "access_denied"', callback)
        self.assertIn("stopServer(keeping: peerID)", callback)

    def test_exactly_once_cleanup_before_resume(self):
        finish = self.section("private func finish", "private static func authorizationURL")
        self.assertIn("guard attemptID == id else { return }", finish)
        for fragment in (
            "continuation = nil", "attemptID = nil", "expectedState = nil", "codeVerifier = nil",
            "timeoutTask?.cancel()", "exchangeTask?.cancel()", "stopServer()",
            "browser?.delegate = nil", "isLoggingIn = false",
        ):
            self.assertLess(finish.index(fragment), finish.index("pending?.resume(with: result)"))
        self.assertIn("listener?.cancel()", self.source)
        self.assertIn("peer.connection.cancel()", self.source)

    def test_cancellation_and_visible_presenter(self):
        for fragment in (
            "withTaskCancellationHandler", "self?.finish(.failure(CancellationError()), for: id)",
            "SFSafariViewController(url: authorizationURL)", "browser.delegate = self",
            "func safariViewControllerDidFinish", "func presentationControllerDidDismiss",
            ".foregroundActive", "$0.isKeyWindow", "top.presentedViewController",
            "navigation.visibleViewController", "tabs.selectedViewController", "split.viewControllers.last",
        ):
            self.assertIn(fragment, self.source)

    def test_refresh_rotation_preserves_missing_fields(self):
        merge = self.section("private static func credential", "private static func invalidTokenReply")
        for fragment in (
            "reply.refreshToken ?? existing?.refreshToken", "accountID ?? existing?.accountID",
            "identity ?? existing?.identity", "var credential = existing ?? Credential()",
            "credential.expiresAt = expiresAt",
        ):
            self.assertIn(fragment, merge)
        refresh = self.section("static func refresh", "private func beginLogin")
        self.assertIn("refreshTasks[refreshToken]", refresh)
        self.assertIn("defer { refreshTasks.removeValue(forKey: refreshToken) }", refresh)
        self.assertIn('"grant_type": "refresh_token"', refresh)
        self.assertNotIn("pending.cancel()", refresh)
        self.assertIn("OpenAI 登录已过期或被撤销，请重新登录。", self.source)

    def test_transport_and_metadata_do_not_expose_credentials(self):
        for fragment in (
            "URLSessionConfiguration.ephemeral", "configuration.httpCookieStorage = nil",
            "configuration.urlCache = nil", "defer { session.invalidateAndCancel() }",
            "delegate: OAuthNoRedirects()", "completionHandler(nil)",
            '"application/x-www-form-urlencoded"', "guard data.count < maximumBytes",
            "UNVERIFIED display metadata", "Referrer-Policy: no-referrer", "Cache-Control: no-store",
        ):
            self.assertIn(fragment, self.source)
        self.assertNotRegex(self.source, r"\b(?:print|debugPrint|dump|NSLog|os_log)\s*\(")
        self.assertNotIn("error.localizedDescription", self.source)
        self.assertNotIn("error_description", self.source)
        self.assertNotRegex(self.source, r"(?:try!|client_secret|UserDefaults|HTTPCookieStorage.shared)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
