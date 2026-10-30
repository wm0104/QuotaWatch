import Foundation

enum QuotaParser {
    static func parse(_ data: Data, kind: ProviderKind, now: Date = Date()) throws -> QuotaSnapshot {
        do {
            guard now.timeIntervalSince1970.isFinite else { throw InvalidResponse.value }
            let decoder = JSONDecoder()
            let snapshot: QuotaSnapshot
            switch kind {
            case .deepseek:
                let response = try decoder.decode(DeepSeekResponse.self, from: data)
                let metrics = try response.balances.map { balance -> QuotaMetric in
                    let unit: QuotaUnit
                    switch balance.currency {
                    case "CNY": unit = .cny
                    case "USD": unit = .usd
                    default: throw InvalidResponse.value
                    }
                    return QuotaMetric(
                        id: "deepseek.balance.\(unit.rawValue)",
                        title: "\(balance.currency) 余额",
                        unit: unit,
                        remaining: balance.total?.value,
                        granted: balance.granted?.value,
                        toppedUp: balance.toppedUp?.value
                    )
                }
                snapshot = QuotaSnapshot(capturedAt: now, metrics: metrics, available: response.available)

            case .codex:
                let response = try decoder.decode(CodexResponse.self, from: data)
                if let plan = response.plan, plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw InvalidResponse.value
                }
                var metrics: [QuotaMetric] = []
                if let rate = response.rateLimit {
                    metrics += try windowMetrics(rate, prefix: "codex", title: "Codex", now: now)
                }
                for extra in response.additional ?? [] {
                    let names = [extra.feature, extra.name].compactMap { $0 }
                    guard !names.isEmpty,
                          names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                          let stableName = names.first,
                          let escapedName = stableName.addingPercentEncoding(
                            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"))
                    else { throw InvalidResponse.value }
                    if let rate = extra.rateLimit {
                        metrics += try windowMetrics(
                            rate, prefix: "codex.additional.\(escapedName)",
                            title: extra.name ?? stableName, now: now
                        )
                    }
                }
                if let credits = response.credits {
                    metrics.append(QuotaMetric(
                        id: "codex.credits", title: "Codex 点数", unit: .credits,
                        remaining: credits.balance?.value, unlimited: credits.unlimited ?? false
                    ))
                }
                snapshot = QuotaSnapshot(
                    capturedAt: now, metrics: metrics, plan: response.plan,
                    available: response.rateLimit?.allowed
                )
            }
            guard Set(snapshot.metrics.map(\.id)).count == snapshot.metrics.count else {
                throw InvalidResponse.value
            }
            return snapshot
        } catch {
            // Decoding errors can contain response fragments; never expose them to UI/logs.
            throw QuotaError.message("\(kind.name) 额度响应格式无效或包含不支持的值。")
        }
    }

    private static func windowMetrics(
        _ rate: CodexRateLimit, prefix: String, title: String, now: Date
    ) throws -> [QuotaMetric] {
        var result: [QuotaMetric] = []
        for (role, label, window) in [
            ("primary", "主要额度", rate.primary),
            ("secondary", "次要额度", rate.secondary)
        ] {
            guard let window = window else { continue }
            if let seconds = window.duration, seconds <= 0 { throw InvalidResponse.value }
            if let epoch = window.resetAt, epoch < 0 { throw InvalidResponse.value }
            if let seconds = window.resetAfter, seconds < 0 { throw InvalidResponse.value }
            let durationID = window.duration.map { ".\($0)" } ?? ""
            let durationTitle = window.duration.map { seconds -> String in
                if seconds % 86400 == 0 { return "（\(seconds / 86400) 天）" }
                if seconds % 3600 == 0 { return "（\(seconds / 3600) 小时）" }
                if seconds % 60 == 0 { return "（\(seconds / 60) 分钟）" }
                return "（\(seconds) 秒）"
            } ?? ""
            // Absolute server time wins; never roll an expired window forward using its relative hint.
            let reset = window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? window.resetAfter.map { now.addingTimeInterval(TimeInterval($0)) }
            result.append(QuotaMetric(
                id: "\(prefix).\(role)\(durationID)", title: "\(title) \(label)\(durationTitle)",
                unit: .percent,
                remaining: window.used.map { min(Decimal(100), max(Decimal.zero, Decimal(100) - $0.value)) },
                resetAt: reset
            ))
        }
        return result
    }

    private enum InvalidResponse: Error { case value }

    private struct NonnegativeNumber: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let number = try container.decode(Decimal.self)
            guard !number.isNaN, number >= 0 else { throw InvalidResponse.value }
            value = number
        }
    }

    private struct Balance: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard text.range(of: "\\A[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\z",
                                 options: .regularExpression) != nil,
                      let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN, number >= 0 else { throw InvalidResponse.value }
                let mantissa = text.prefix { $0 != "e" && $0 != "E" }
                guard number != 0 || !mantissa.contains(where: { $0 >= "1" && $0 <= "9" }) else {
                    throw InvalidResponse.value
                }
                value = number
            } else {
                value = try NonnegativeNumber(from: decoder).value
            }
        }
    }

    private struct DeepSeekResponse: Decodable {
        let available: Bool?
        let balances: [DeepSeekBalance]
        enum CodingKeys: String, CodingKey {
            case available = "is_available", balances = "balance_infos"
        }
    }

    private struct DeepSeekBalance: Decodable {
        let currency: String
        let total: Balance?
        let granted: Balance?
        let toppedUp: Balance?
        enum CodingKeys: String, CodingKey {
            case currency, total = "total_balance", granted = "granted_balance", toppedUp = "topped_up_balance"
        }
    }

    private struct CodexResponse: Decodable {
        let plan: String?
        let rateLimit: CodexRateLimit?
        let additional: [AdditionalRateLimit]?
        let credits: CodexCredits?
        enum CodingKeys: String, CodingKey {
            case plan = "plan_type", rateLimit = "rate_limit", additional = "additional_rate_limits", credits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            plan = try container.decodeIfPresent(String.self, forKey: .plan)
            guard plan != nil || container.contains(.rateLimit)
                    || container.contains(.additional) || container.contains(.credits) else {
                throw InvalidResponse.value
            }
            rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
            additional = try container.decodeIfPresent([AdditionalRateLimit].self, forKey: .additional)
            credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        }
    }

    private struct CodexRateLimit: Decodable {
        let allowed: Bool?
        let reached: Bool?
        let primary: CodexWindow?
        let secondary: CodexWindow?
        enum CodingKeys: String, CodingKey {
            case allowed, reached = "limit_reached", primary = "primary_window", secondary = "secondary_window"
        }
    }

    private struct CodexWindow: Decodable {
        let used: NonnegativeNumber?
        let duration: Int?
        let resetAt: Int?
        let resetAfter: Int?
        enum CodingKeys: String, CodingKey {
            case used = "used_percent", duration = "limit_window_seconds"
            case resetAt = "reset_at", resetAfter = "reset_after_seconds"
        }
    }

    private struct AdditionalRateLimit: Decodable {
        let name: String?
        let feature: String?
        let rateLimit: CodexRateLimit?
        enum CodingKeys: String, CodingKey {
            case name = "limit_name", feature = "metered_feature", rateLimit = "rate_limit"
        }
    }

    private struct CodexCredits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: Balance?
        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits", unlimited, balance
        }
    }
}
