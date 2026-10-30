import Combine
import CryptoKit
import Foundation
import Network
import SafariServices
import Security
import UIKit

// Independent RFC 7636 / OAuth 2.0 implementation; the public Codex client ID is not a secret.
@MainActor
final class CodexOAuth: NSObject, ObservableObject, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    @Published private(set) var isLoggingIn = false

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeEndpoint = "https://auth.openai.com/oauth/authorize"
    private static let tokenEndpoint = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let callbackPath = "/auth/callback"
    private static let callbackPort: NWEndpoint.Port = 1455
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumPeers = 8
    private static let loginTimeoutNanoseconds: UInt64 = 180_000_000_000
    private static let peerTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static var refreshTasks: [String: Task<TokenReply, Error>] = [:]

    private var attemptID: UUID?
    private var continuation: CheckedContinuation<Credential, Error>?
    private var expectedState: String?
    private var codeVerifier: String?
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var safari: SFSafariViewController?
    private var timeoutTask: Task<Void, Never>?
    private var exchangeTask: Task<Void, Never>?
    private var callbackConsumed = false

    private final class Peer {
        let connection: NWConnection
        var header = Data()
        var startedReading = false
        var timeout: Task<Void, Never>?

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private struct TokenReply: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let tokenType: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    private enum ParsedRequest {
        case reject(String)
        case callback([String: String])
    }

    func login() async throws -> Credential {
        guard !isLoggingIn else { throw QuotaError.message("已有登录正在进行。") }
        try Task.checkCancellation()
        let id = UUID()
        attemptID = id
        isLoggingIn = true
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { pending in
                guard self.attemptID == id else {
                    pending.resume(throwing: CancellationError())
                    return
                }
                self.continuation = pending
                if Task.isCancelled {
                    self.finish(.failure(CancellationError()), for: id)
                    return
                }
                do {
                    try self.beginLogin(for: id)
                } catch let error as QuotaError {
                    self.finish(.failure(error), for: id)
                } catch {
                    self.finish(.failure(Self.listenerError()), for: id)
                }
            }
        }, onCancel: { [weak self] in
            // A delayed cancellation of an older login must not cancel a newer one.
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()), for: id)
            }
        })
    }

    func cancel() {
        guard let id = attemptID else { return }
        finish(.failure(QuotaError.message("已取消 OpenAI 登录。")), for: id)
    }

    static func refresh(_ existing: Credential) async throws -> Credential {
        try Task.checkCancellation()
        guard let refreshToken = usableToken(existing.refreshToken) else {
            throw QuotaError.message("登录凭证已失效，请重新登录 OpenAI。")
        }
        // Share one rotation per refresh token; never automatically retry a consumed token.
        // Once started, finish rotation even if a waiter cancels, so its new token can be saved.
        if let pending = refreshTasks[refreshToken] {
            let reply = try await pending.value
            return try credential(from: reply, replacing: existing)
        }
        let pending = Task {
            try await requestTokens([
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refreshToken
            ], refreshing: true)
        }
        refreshTasks[refreshToken] = pending
        defer { refreshTasks.removeValue(forKey: refreshToken) }
        let reply = try await pending.value
        return try credential(from: reply, replacing: existing)
    }

    private func beginLogin(for id: UUID) throws {
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        codeVerifier = verifier
        expectedState = state
        callbackConsumed = false
        let authorizationURL = try Self.authorizationURL(verifier: verifier, state: state)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        // Explicit IPv4 loopback binding, never a wildcard/LAN listener. Safari's localhost
        // resolution can fall back to IPv4; no second listener or ephemeral-port fallback.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: Self.callbackPort
        )
        let localListener = try NWListener(using: parameters)
        listener = localListener
        localListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.listenerChanged(state, authorizationURL: authorizationURL, for: id)
            }
        }
        localListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self = self else { connection.cancel(); return }
                self.accept(connection, for: id)
            }
        }
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.loginTimeoutNanoseconds) }
            catch { return }
            self?.finish(.failure(QuotaError.message("OpenAI 登录超时，请重试。")), for: id)
        }
        localListener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State, authorizationURL: URL, for id: UUID) {
        guard attemptID == id, !callbackConsumed else { return }
        switch state {
        case .ready:
            guard listener?.port == Self.callbackPort else {
                finish(.failure(Self.listenerError()), for: id)
                return
            }
            guard safari == nil else { return }
            guard let presenter = Self.topViewController(),
                  presenter.viewIfLoaded?.window != nil,
                  !presenter.isBeingDismissed, !presenter.isBeingPresented else {
                finish(.failure(QuotaError.message("无法显示登录页面，请回到应用前台后重试。")), for: id)
                return
            }
            let browser = SFSafariViewController(url: authorizationURL)
            browser.delegate = self
            safari = browser
            presenter.present(browser, animated: true)
            browser.presentationController?.delegate = self
        case .failed(_), .waiting(_):
            finish(.failure(Self.listenerError()), for: id)
        case .cancelled:
            finish(.failure(QuotaError.message("登录回调服务已停止，请重试。")), for: id)
        default:
            break
        }
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in
            guard let self, controller === self.safari else { return }
            self.cancel()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === safari else { return }
        cancel()
    }

    private static func listenerError() -> QuotaError {
        QuotaError.message("无法监听本机 1455 端口，请关闭占用该端口的程序后重试。")
    }

    private func accept(_ connection: NWConnection, for id: UUID) {
        guard attemptID == id, !callbackConsumed, peers.count < Self.maximumPeers else {
            connection.cancel()
            return
        }
        let peerID = UUID()
        let peer = Peer(connection)
        peers[peerID] = peer
        peer.timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.peerTimeoutNanoseconds) }
            catch { return }
            guard self?.attemptID == id else { return }
            self?.closePeer(peerID)
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self, self.attemptID == id,
                      let peer = self.peers[peerID] else { return }
                switch state {
                case .ready:
                    guard !peer.startedReading else { return }
                    peer.startedReading = true
                    self.receiveHeader(peerID, for: id)
                case .failed(_), .cancelled:
                    self.closePeer(peerID)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receiveHeader(_ peerID: UUID, for id: UUID) {
        guard attemptID == id, let peer = peers[peerID] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                self?.received(data, complete: complete, failed: error != nil, peerID: peerID, for: id)
            }
        }
    }

    private func received(_ data: Data?, complete: Bool, failed: Bool, peerID: UUID, for id: UUID) {
        guard attemptID == id, let peer = peers[peerID] else { return }
        guard !failed, let data = data, !data.isEmpty else { closePeer(peerID); return }
        guard peer.header.count + data.count <= Self.maximumHeaderBytes else {
            respond(peerID, status: "431 Request Header Fields Too Large", text: "请求过大。")
            return
        }
        peer.header.append(data)
        if let end = peer.header.range(of: Data("\r\n\r\n".utf8)) {
            // One request only: no bodies, pipelining, or ambiguous framing.
            guard end.upperBound == peer.header.endIndex else {
                respond(peerID, status: "400 Bad Request", text: "无效的登录回调。")
                return
            }
            let header = Data(peer.header[..<end.lowerBound])
            switch Self.parseRequest(header) {
            case .reject(let status):
                respond(peerID, status: status, text: "无效的登录回调。")
            case .callback(let parameters):
                handleCallback(parameters, peerID: peerID, for: id)
            }
        } else if complete {
            closePeer(peerID)
        } else {
            receiveHeader(peerID, for: id)
        }
    }

    private static func parseRequest(_ data: Data) -> ParsedRequest {
        guard let header = String(data: data, encoding: .ascii) else {
            return .reject("400 Bad Request")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, lines.count <= 100,
              first.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return .reject("400 Bad Request")
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .reject("400 Bad Request")
        }
        guard parts[0] == "GET" else { return .reject("405 Method Not Allowed") }
        let target = parts[1]
        guard target.utf8.count <= 8192, !target.contains("#") else {
            return .reject("400 Bad Request")
        }
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pathAndQuery.first == Substring(callbackPath) else { return .reject("404 Not Found") }

        var host: String?
        var contentLength: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .reject("400 Bad Request") }
            let name = line[..<colon]
            guard !name.isEmpty, name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }) else { return .reject("400 Bad Request") }
            let rawValue = line[line.index(after: colon)...]
            guard rawValue.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                return .reject("400 Bad Request")
            }
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            switch name.lowercased() {
            case "host":
                guard host == nil else { return .reject("400 Bad Request") }
                host = value.lowercased()
            case "content-length":
                guard contentLength == nil, value == "0" else { return .reject("400 Bad Request") }
                contentLength = value
            case "transfer-encoding":
                return .reject("400 Bad Request")
            default:
                break
            }
        }
        // Reject DNS rebinding / unexpected virtual hosts, even on a loopback socket.
        guard host == "localhost:1455" || host == "127.0.0.1:1455" else {
            return .reject("400 Bad Request")
        }
        guard pathAndQuery.count == 2 else { return .callback([:]) }
        let pairs = pathAndQuery[1].split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count <= 32 else { return .reject("400 Bad Request") }
        var parameters: [String: String] = [:]
        for pair in pairs {
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let key = String(fields[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(fields[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !key.isEmpty, parameters[key] == nil else {
                return .reject("400 Bad Request")
            }
            parameters[key] = value
        }
        return .callback(parameters)
    }

    private func handleCallback(_ parameters: [String: String], peerID: UUID, for id: UUID) {
        guard attemptID == id, !callbackConsumed,
              let state = parameters["state"], let expected = expectedState,
              Self.constantTimeEqual(state, expected) else {
            // Unsolicited requests must not terminate the real pending login.
            respond(peerID, status: "400 Bad Request", text: "无效的登录状态。")
            return
        }
        guard parameters["code"] == nil || parameters["error"] == nil else {
            respond(peerID, status: "400 Bad Request", text: "无效的登录回调。")
            return
        }
        if let error = parameters["error"], !error.isEmpty {
            respond(peerID, status: "200 OK", text: "授权未完成，请返回 QuotaWatch。")
            let message = error == "access_denied" ? "已取消 OpenAI 授权。" : "OpenAI 授权未完成，请重试。"
            finish(.failure(QuotaError.message(message)), for: id)
            return
        }
        guard let code = Self.usableToken(parameters["code"]), let verifier = codeVerifier else {
            respond(peerID, status: "400 Bad Request", text: "登录回调缺少授权码。")
            return
        }
        callbackConsumed = true
        stopServer(keeping: peerID)
        respond(peerID, status: "200 OK", text: "授权已收到，你可以返回 QuotaWatch。")
        exchangeTask = Task { @MainActor [weak self] in
            do {
                let reply = try await Self.requestTokens([
                    "grant_type": "authorization_code",
                    "client_id": Self.clientID,
                    "code": code,
                    "redirect_uri": Self.redirectURI,
                    "code_verifier": verifier
                ], refreshing: false)
                let credential = try Self.credential(from: reply, replacing: nil)
                self?.finish(.success(credential), for: id)
            } catch {
                self?.finish(.failure(error), for: id)
            }
        }
    }

    private func respond(_ peerID: UUID, status: String, text: String) {
        guard let peer = peers[peerID] else { return }
        // Only fixed application strings reach this page; no callback values are reflected.
        let body = Data(("<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width\"><title>QuotaWatch</title>" +
            "<body><h1>QuotaWatch</h1><p>" + text + "</p></body></html>").utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        head += "Pragma: no-cache\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Content-Security-Policy: default-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n"
        if status == "405 Method Not Allowed" { head += "Allow: GET\r\n" }
        head += "\r\n"
        var response = Data(head.utf8)
        response.append(body)
        peer.connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePeer(peerID) }
        })
    }

    private func closePeer(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel()
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
    }

    private func stopServer(keeping peerID: UUID? = nil) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) where id != peerID { closePeer(id) }
    }

    private func finish(_ result: Result<Credential, Error>, for id: UUID) {
        guard attemptID == id else { return }
        let pending = continuation
        continuation = nil
        attemptID = nil
        expectedState = nil
        codeVerifier = nil
        callbackConsumed = false
        timeoutTask?.cancel()
        timeoutTask = nil
        exchangeTask?.cancel()
        exchangeTask = nil
        stopServer()
        let browser = safari
        safari = nil
        browser?.delegate = nil
        browser?.presentationController?.delegate = nil
        // Synchronous dismissal avoids a retry presenting during an outgoing animation.
        if browser?.presentingViewController != nil { browser?.dismiss(animated: false) }
        isLoggingIn = false
        pending?.resume(with: result)
    }

    private static func authorizationURL(verifier: String, state: String) throws -> URL {
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let url = components?.url else { throw QuotaError.message("无法创建 OpenAI 登录请求。") }
        return url
    }

    private static func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QuotaError.message("无法安全创建登录请求，请重试。")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(a, b) { difference |= left ^ right }
        return difference == 0
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let windows = scenes.flatMap { $0.windows }
        guard let root = (windows.first { $0.isKeyWindow } ??
            windows.first { !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal })?.rootViewController
        else { return nil }
        var top = root
        while true {
            if let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            } else if let navigation = top as? UINavigationController,
                      let visible = navigation.visibleViewController {
                top = visible
            } else if let tabs = top as? UITabBarController, let selected = tabs.selectedViewController {
                top = selected
            } else if let split = top as? UISplitViewController, let visible = split.viewControllers.last {
                top = visible
            } else {
                return top
            }
        }
    }

    private static func requestTokens(_ fields: [String: String], refreshing: Bool) async throws -> TokenReply {
        guard let url = URL(string: tokenEndpoint) else { throw invalidTokenReply() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: OAuthNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = fields.sorted { $0.key < $1.key }.map { key, value in
            // The fixed ASCII allowlist encodes '+', '&', '=', and all non-ASCII bytes.
            (key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "") + "=" +
                (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        request.httpBody = Data(form.utf8)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url?.absoluteString == tokenEndpoint else {
                throw invalidTokenReply()
            }
            guard http.statusCode == 200 else {
                // Do not read, display, or log raw error bodies (which can contain credentials).
                if refreshing && [400, 401, 403].contains(http.statusCode) {
                    throw QuotaError.message("OpenAI 登录已过期或被撤销，请重新登录。")
                }
                if http.statusCode == 429 {
                    throw QuotaError.message("OpenAI 请求过于频繁，请稍后重试。")
                }
                if !refreshing && [400, 401, 403].contains(http.statusCode) {
                    throw QuotaError.message("OpenAI 登录授权已失效，请重新开始登录。")
                }
                throw QuotaError.message("OpenAI 登录服务暂时不可用，请稍后重试。")
            }
            let maximumBytes = 1024 * 1024
            guard http.expectedContentLength <= Int64(maximumBytes) else { throw invalidTokenReply() }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw invalidTokenReply() }
                data.append(byte)
            }
            guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data) else {
                throw invalidTokenReply()
            }
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.message("无法连接 OpenAI 登录服务，请检查网络后重试。")
        }
    }

    private static func credential(from reply: TokenReply, replacing existing: Credential?) throws -> Credential {
        guard let accessToken = usableToken(reply.accessToken) else { throw invalidTokenReply() }
        if let type = reply.tokenType, type.caseInsensitiveCompare("Bearer") != .orderedSame {
            throw invalidTokenReply()
        }
        if let refreshToken = reply.refreshToken, usableToken(refreshToken) == nil { throw invalidTokenReply() }
        let refreshToken = reply.refreshToken ?? existing?.refreshToken
        guard usableToken(refreshToken) != nil else {
            throw QuotaError.message("未获得可续期的 OpenAI 登录凭证，请重新登录。")
        }

        // JWT payloads are UNVERIFIED display metadata, not authentication/authorization proof.
        // A JWT exp is only a local refresh scheduling hint, never a token-validity decision.
        let idClaims = jwtPayload(reply.idToken)
        let accessClaims = jwtPayload(accessToken)
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let idProfile = idClaims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let accessProfile = accessClaims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let accountID = accountHint(idAuth["chatgpt_account_id"]) ?? accountHint(accessAuth["chatgpt_account_id"])
        let identity = displayText(idClaims["email"]) ?? displayText(idProfile["email"]) ??
            displayText(accessProfile["email"]) ?? displayText(accessClaims["email"]) ??
            displayText(idClaims["name"]) ?? displayText(accessClaims["name"])
        var expiresAt: Date?
        if let seconds = reply.expiresIn {
            guard seconds.isFinite, seconds > 0 else { throw invalidTokenReply() }
            let date = Date().addingTimeInterval(seconds)
            guard date.timeIntervalSince1970.isFinite else { throw invalidTokenReply() }
            expiresAt = date
        } else if let seconds = accessClaims["exp"] as? Double, seconds.isFinite, seconds > 0 {
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        var credential = existing ?? Credential()
        credential.accessToken = accessToken
        credential.refreshToken = refreshToken
        credential.accountID = accountID ?? existing?.accountID
        credential.identity = identity ?? existing?.identity
        // Never reuse an old token's expiry for a newly issued token.
        credential.expiresAt = expiresAt
        return credential
    }

    private static func invalidTokenReply() -> QuotaError {
        QuotaError.message("OpenAI 返回了无效的登录凭证，请重试或重新登录。")
    }

    private static func usableToken(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty, value.utf8.count <= 64 * 1024,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return value
    }

    private static func accountHint(_ value: Any?) -> String? {
        guard let text = usableToken(value as? String), text.utf8.count <= 256 else { return nil }
        return text
    }

    private static func displayText(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 1024,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtPayload(_ token: String?) -> [String: Any] {
        guard let token = token, token.utf8.count <= 64 * 1024 else { return [:] }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, !segments[1].isEmpty else { return [:] }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return claims
    }
}

// Prevent URLSession from forwarding an authorization code or refresh token through any redirect.
private final class OAuthNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
