import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// This file requires the app's Models.swift and QuotaParser.swift in the same target. It does not
// depend on CodexOAuth.swift (SafariServices/UIKit, @MainActor) or the app's QuotaClient.swift.
struct WidgetQuotaHTTPFailure: LocalizedError, Equatable {
    let status: Int

    var errorDescription: String? {
        switch status {
        case 401: return "认证已失效，等待主应用重新登录并同步凭据。"
        case 403: return "服务拒绝访问，本次查询已停止。"
        case 404: return "用量接口暂不可用。"
        case 429: return "查询过于频繁，等待系统稍后重试。"
        case 300...399: return "请求被重定向，已拒绝。"
        case 500...599: return "服务暂时异常。"
        default: return "查询失败（HTTP \(status)）。"
        }
    }
}

private final class WidgetQuotaRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer token to another URL.
    }
}

enum WidgetQuotaClient {
    static let maximumResponseBytes = 2_000_000
    private static let codexEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let deepseekEndpoint = URL(string: "https://api.deepseek.com/user/balance")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration,
                          delegate: WidgetQuotaRedirectPolicy(), delegateQueue: nil)
    }()

    // Credentials are normally synced by the host. The widget does not rotate OAuth tokens here;
    // a 401 is surfaced as a sanitized error for the host to repair on its next refresh.
    static func fetch(kind: ProviderKind, credential: Credential,
                      now: Date = Date()) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let endpoint = kind == .codex ? codexEndpoint : deepseekEndpoint
        let rawToken = kind == .codex ? credential.accessToken : credential.apiKey
        guard let rawToken, headerSafe(rawToken, maximum: 32_768) else {
            throw QuotaError.message("小组件凭据无效，等待主应用同步。")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(rawToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if kind == .codex {
            request.setValue("codex_cli_rs/0.166.0 (iOS; arm64)", forHTTPHeaderField: "User-Agent")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
            if let accountID = credential.accountID, !accountID.isEmpty {
                guard headerSafe(accountID, maximum: 128) else {
                    throw QuotaError.message("小组件凭据中的账户标识无效。")
                }
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await load(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch is URLError {
            throw QuotaError.message("网络连接失败，稍后由系统重试。")
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.message("无效的服务器响应。")
        }
        guard let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https",
              finalURL.host == endpoint.host,
              finalURL.path == endpoint.path else {
            throw QuotaError.message("服务器返回了意外的地址，已拒绝处理。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WidgetQuotaHTTPFailure(status: http.statusCode)
        }
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(rawLength), length > maximumResponseBytes {
            throw QuotaError.message("响应过大，已拒绝处理。")
        }
        guard !data.isEmpty, data.count <= maximumResponseBytes else {
            throw QuotaError.message("响应为空或过大，已拒绝处理。")
        }

        if kind == .codex, let expected = credential.accountID, !expected.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let actual = object["account_id"] as? String, actual != expected {
            throw QuotaError.message("返回的账户与当前登录不一致，已拒绝保存数据。")
        }
        return try QuotaParser.parse(data, kind: kind, now: now)
    }

    static func fetch(kind: ProviderKind, credential: WidgetCredentialRecord,
                      now: Date = Date()) async throws -> QuotaSnapshot {
        guard credential.provider == kind.rawValue,
              let clean = credential.validated(),
              clean.provider == kind.rawValue else {
            throw QuotaError.message("小组件凭据无效或与账户类型不匹配。")
        }
        return try await fetch(kind: kind, credential: clean.credential, now: now)
    }

    static func tokenNeedsRefresh(_ credential: Credential, now: Date = Date()) -> Bool {
        guard let expiresAt = credential.expiresAt,
              expiresAt.timeIntervalSince1970.isFinite else { return false }
        return expiresAt.timeIntervalSince(now) < 300
    }

    private static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if os(iOS)
        return try await session.data(for: request)
        #else
        // Swift 5.9 corelibs does not expose the async data(for:) API; this keeps the pure
        // Foundation test build portable without changing the iOS production path.
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
        #endif
    }

    private static func headerSafe(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum else { return false }
        return value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}

// Host and widget both use the same explicit allowed-account set before saving/loading. The
// conversion stays here so WidgetCredentialStore.swift has no dependency on Models.swift.
extension WidgetCredentialRecord {
    init(_ credential: Credential, provider: ProviderKind) {
        self.init(
            provider: provider.rawValue,
            apiKey: credential.apiKey,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accountID: credential.accountID,
            identity: credential.identity,
            expiresAt: credential.expiresAt)
    }

    var credential: Credential {
        Credential(apiKey: apiKey, accessToken: accessToken, refreshToken: refreshToken,
                   accountID: accountID, identity: identity, expiresAt: expiresAt)
    }
}
