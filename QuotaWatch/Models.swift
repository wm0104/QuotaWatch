import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case codex, deepseek

    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .codex: return 300
        case .deepseek: return 600
        }
    }
}

enum QuotaUnit: String, Codable {
    case percent, cny, usd, credits
}

struct Credential: Codable, Equatable {
    var apiKey: String? = nil
    var accessToken: String? = nil
    var refreshToken: String? = nil
    var accountID: String? = nil
    var identity: String? = nil
    var expiresAt: Date? = nil
}

struct QuotaMetric: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var unit: QuotaUnit
    var remaining: Decimal?
    var resetAt: Date? = nil
    var granted: Decimal? = nil
    var toppedUp: Decimal? = nil
    var unlimited: Bool = false
}

struct QuotaSnapshot: Codable, Equatable {
    var capturedAt: Date
    var metrics: [QuotaMetric]
    var plan: String? = nil
    var available: Bool? = nil
}

struct AlertRule: Codable, Equatable, Identifiable {
    var metricID: String
    var threshold: Decimal
    var enabled: Bool = true
    var id: String { metricID }
}

struct Account: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: ProviderKind
    var alias: String
    var remoteID: String? = nil
    var identity: String? = nil
    var snapshot: QuotaSnapshot? = nil
    var rules: [AlertRule] = []
    var latched: Set<String> = []
    var error: String? = nil
    var lastAttempt: Date? = nil
    var nextAllowedAt: Date? = nil
    var requiresAuth: Bool = false
    var revision: UUID = UUID()
    var createdAt: Date = Date()
}

enum QuotaError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum AlertEvaluator {
    static func evaluate(
        snapshot: QuotaSnapshot,
        rules: [AlertRule],
        latched: Set<String>,
        interval: TimeInterval,
        now: Date = Date()
    ) -> (notify: [String], latched: Set<String>) {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard interval.isFinite, interval > 0, age.isFinite,
              age >= 0, age <= 2 * interval else {
            return ([], latched)
        }

        var next = latched
        var notify: [String] = []
        var evaluated: Set<String> = []
        for rule in rules where rule.enabled {
            guard !rule.threshold.isNaN, rule.threshold >= 0,
                  evaluated.insert(rule.metricID).inserted,
                  let metric = snapshot.metrics.first(where: { $0.id == rule.metricID }),
                  !metric.unlimited,
                  let remaining = metric.remaining,
                  !remaining.isNaN, remaining >= 0,
                  metric.unit != .percent || (remaining <= 100 && rule.threshold <= 100),
                  metric.resetAt.map({ $0 > now }) ?? true else { continue }

            if remaining <= rule.threshold {
                if next.insert(rule.metricID).inserted {
                    notify.append(rule.metricID)
                }
            } else {
                next.remove(rule.metricID)
            }
        }
        // The caller commits this prospective latch only after notification scheduling succeeds.
        return (notify, next)
    }
}
