import Foundation

enum ProbeIdentity {
    static let group = "group.com.wm0104.quotawatch.widgetprobe"
    static let kind = "QuotaProbeWidget"
    static let snapshotFile = "fake-snapshot-v1.json"
    static let diagnosticFile = "widget-read-v1.json"
    static let maximumRevision = 1_000_000_000
}

enum ProbeError: LocalizedError {
    case invalid(String)
    case groupUnavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "模拟数据无效：\(reason)"
        case .groupUnavailable: return "App Group 不可访问；未使用替代容器。检查注册、签名或解锁设备。"
        }
    }
}

struct ProbeAccount: Codable, Identifiable {
    enum Provider: String, Codable { case codex, deepseek }
    let id: String
    let provider: Provider
    let remainingPercent: Double?
    let balanceUSD: Double?
    let expectedResetAt: Date?
}

struct ProbeSnapshot: Codable {
    let schemaVersion: Int
    let isFake: Bool
    let revision: Int
    let writtenAt: Date
    let staleAt: Date
    let accounts: [ProbeAccount]

    func validated() throws -> ProbeSnapshot {
        guard schemaVersion == 1, isFake else { throw ProbeError.invalid("schema / FAKE 标记") }
        guard (1...ProbeIdentity.maximumRevision).contains(revision),
              writtenAt.timeIntervalSince1970.isFinite, staleAt.timeIntervalSince1970.isFinite,
              staleAt > writtenAt else { throw ProbeError.invalid("revision / 时间") }
        guard accounts.map(\.id) == ["FAKE-CODEX-A", "FAKE-CODEX-B", "FAKE-DEEPSEEK-C"] else {
            throw ProbeError.invalid("仅允许固定的三个模拟账户")
        }
        for (index, account) in accounts.enumerated() {
            if index < 2 {
                guard account.provider == .codex, let percent = account.remainingPercent,
                      percent.isFinite, (0...100).contains(percent), account.balanceUSD == nil,
                      let reset = account.expectedResetAt, reset.timeIntervalSince1970.isFinite,
                      reset > writtenAt else { throw ProbeError.invalid("Codex 数值 / 重置时间") }
            } else {
                guard account.provider == .deepseek, account.remainingPercent == nil,
                      let balance = account.balanceUSD, balance.isFinite,
                      (0...1_000_000).contains(balance), account.expectedResetAt == nil else {
                    throw ProbeError.invalid("DeepSeek 模拟余额")
                }
            }
        }
        return self
    }

    static func fake(revision: Int, now: Date) -> ProbeSnapshot {
        let step = Double(revision % 20)
        return ProbeSnapshot(schemaVersion: 1, isFake: true, revision: revision,
            writtenAt: now, staleAt: now.addingTimeInterval(600), accounts: [
                ProbeAccount(id: "FAKE-CODEX-A", provider: .codex, remainingPercent: 72 - step,
                    balanceUSD: nil, expectedResetAt: now.addingTimeInterval(120)),
                ProbeAccount(id: "FAKE-CODEX-B", provider: .codex, remainingPercent: 31 + step,
                    balanceUSD: nil, expectedResetAt: now.addingTimeInterval(240)),
                ProbeAccount(id: "FAKE-DEEPSEEK-C", provider: .deepseek, remainingPercent: nil,
                    balanceUSD: 12 + step * 0.37, expectedResetAt: nil)
            ])
    }
}

struct ProbeReadDiagnostic: Codable {
    let schemaVersion: Int
    let revision: Int?
    let readAt: Date
    let result: String

    func validated() throws -> ProbeReadDiagnostic {
        guard schemaVersion == 1, readAt.timeIntervalSince1970.isFinite,
              revision.map({ (1...ProbeIdentity.maximumRevision).contains($0) }) ?? true,
              ["ok", "missing", "error"].contains(result),
              (result == "ok") == (revision != nil) else { throw ProbeError.invalid("读取诊断") }
        return self
    }
}

enum ProbeCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
