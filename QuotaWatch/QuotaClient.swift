import Foundation

struct HTTPFailure: LocalizedError {
    let status: Int
    let retryAt: Date?
    var errorDescription: String? {
        switch status {
        case 401: return "认证已失效，请重新登录或更换密钥。"
        case 403: return "服务拒绝访问；已停止自动重试，请检查账户或接口权限。"
        case 404: return "用量接口不可用；旧数据仅供参考。"
        case 429: return "查询过于频繁，稍后按服务端限制重试。"
        case 500...599: return "服务暂时异常，旧数据已保留。"
        default: return "查询失败（HTTP \(status)），旧数据已保留。"
        }
    }
}

final class QuotaRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward authenticated quota requests through redirects.
    }
}

enum QuotaClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 2
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: QuotaRedirectPolicy(), delegateQueue: nil)
    }()

    static func fetch(kind: ProviderKind, credential: Credential) async throws -> QuotaSnapshot {
        let endpoint = kind == .codex
            ? "https://chatgpt.com/backend-api/wham/usage"
            : "https://api.deepseek.com/user/balance"
        guard let token = kind == .codex ? credential.accessToken : credential.apiKey,
              !token.isEmpty else { throw QuotaError.message("缺少凭据，请重新登录。") }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if kind == .codex {
            // Public CLI identity, not a promise of supported third-party integration.
            request.setValue("codex_cli_rs/0.166.0 (iOS; arm64)", forHTTPHeaderField: "User-Agent")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
            if let id = credential.accountID, !id.isEmpty {
                request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw QuotaError.message("无效的服务器响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(status: http.statusCode, retryAt: retryDate(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard data.count <= 2_000_000 else { throw QuotaError.message("响应过大，已拒绝处理。") }
        if kind == .codex, let expected = credential.accountID,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let actual = object["account_id"] as? String, actual != expected {
            throw QuotaError.message("返回的账户与当前登录不一致，已拒绝保存数据。")
        }
        return try QuotaParser.parse(data, kind: kind)
    }

    private static func retryDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return Date().addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}
