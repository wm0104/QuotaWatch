import Foundation

enum QuotaDisplayRules {
    static func overviewMetrics(_ snapshot: QuotaSnapshot) -> [QuotaMetric] {
        snapshot.metrics.filter { $0.unit != .credits }
    }

    static func title(_ metric: QuotaMetric) -> String {
        if metric.unit == .credits { return "Credits 余额" }
        let parts = metric.id.split(separator: ".")
        guard parts.first == "codex" else { return metric.title }
        let isMain = (parts.count == 2 || parts.count == 3)
            && (parts[1] == "primary" || parts[1] == "secondary")
        let isAdditional = (parts.count == 4 || parts.count == 5)
            && parts[1] == "additional"
            && (parts[3] == "primary" || parts[3] == "secondary")
        guard isMain || isAdditional else { return metric.title }

        let role = isMain ? parts[1] : parts[3]
        let fallback = role == "primary" ? "主要窗口" : "次要窗口"
        let seconds = metric.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
            ?? parts.last.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let duration = seconds.map { durationTitle($0) }
        if isMain { return duration ?? fallback }

        // Strip only the parser's exact trailing label, never words inside an upstream model name.
        let label = role == "primary" ? "主要额度" : "次要额度"
        let suffix = " \(label)" + (duration.map { "（\($0)）" } ?? "")
        guard metric.title.hasSuffix(suffix) else { return metric.title }
        let name = String(metric.title.dropLast(suffix.count))
        guard !name.isEmpty else { return metric.title }
        return "\(name) \(duration ?? fallback)"
    }

    static func isFresh(_ metric: QuotaMetric, account: Account, now: Date = Date()) -> Bool {
        guard account.error == nil, !account.requiresAuth,
              let snapshot = account.snapshot,
              snapshot.metrics.contains(where: { $0.id == metric.id }) else { return false }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        let interval = account.kind.interval
        return interval.isFinite && interval > 0 && age.isFinite
            && age >= 0 && age <= 2 * interval
            && (metric.resetAt.map { $0 > now } ?? true)
    }

    static func isLow(_ metric: QuotaMetric, account: Account, now: Date = Date()) -> Bool {
        guard isFresh(metric, account: account, now: now),
              let snapshot = account.snapshot else { return false }
        // A notification latch suppresses repeat delivery, not the persistent low-state display.
        return AlertEvaluator.evaluate(
            snapshot: snapshot, rules: account.rules, latched: [],
            interval: account.kind.interval, now: now
        ).notify.contains(metric.id)
    }

    static func needsRefresh(_ account: Account, now: Date = Date()) -> Bool {
        guard account.error == nil, !account.requiresAuth,
              let snapshot = account.snapshot else { return true }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        let interval = account.kind.interval
        guard interval.isFinite, interval > 0, age.isFinite,
              age >= 0, age <= 2 * interval else { return true }
        return overviewMetrics(snapshot).contains { metric in
            metric.resetAt.map { !($0 > now) } ?? false
        }
    }

    private static func durationTitle(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return "\(seconds / 86400) 天" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }
}
