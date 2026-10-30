import Foundation

enum WidgetDisplayState: String, Codable, Equatable {
    case healthy, stale, empty, error
}

enum WidgetResetStatus: Equatable {
    case none
    case pending(Date)   // expected reset is still in the future
    case passed(Date)    // reset time elapsed; cached value needs refresh confirmation

    var resetAt: Date? {
        switch self {
        case .none: return nil
        case .pending(let date), .passed(let date): return date
        }
    }
    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }
}

struct WidgetMetricSummary: Equatable, Identifiable {
    let metric: WidgetMetricSnapshot
    let resetStatus: WidgetResetStatus
    var id: String { metric.id }
}

struct WidgetDisplaySummary: Equatable {
    let state: WidgetDisplayState
    let accounts: [WidgetAccountSnapshot]
    let overflowCount: Int
    let needsRefresh: Bool

    var selectedCount: Int { accounts.count + overflowCount }
}

// Pure display/timeline policy. It never writes a value into a metric: a passed reset yields
// .passed and the cached remaining value is shown as awaiting confirmation, never 0% or 100%.
// It also never sums balances or windows from different providers/currencies.
enum WidgetRefreshRules {
    static func interval(for provider: String) -> TimeInterval? {
        switch provider {
        case "codex": return 300
        case "deepseek": return 600
        default: return nil
        }
    }

    static func isStale(_ account: WidgetAccountSnapshot, at now: Date) -> Bool {
        guard let interval = interval(for: account.provider) else { return true }
        let age = now.timeIntervalSince(account.capturedAt)
        return !age.isFinite || age < 0 || age >= interval
    }

    static func resetStatus(_ metric: WidgetMetricSnapshot, at now: Date) -> WidgetResetStatus {
        guard let reset = metric.resetAt, WidgetSnapshotSanitizer.valid(reset) else { return .none }
        return reset <= now ? .passed(reset) : .pending(reset)
    }

    static func needsRefresh(_ account: WidgetAccountSnapshot, at now: Date) -> Bool {
        if isStale(account, at: now) { return true }
        return account.metrics.contains { resetStatus($0, at: now).isPassed }
    }

    static func needsRefresh(_ snapshot: WidgetSnapshot?, at now: Date) -> Bool {
        guard let snapshot, let clean = snapshot.sanitized() else { return false }
        return clean.accounts.contains { needsRefresh($0, at: now) }
    }

    // At most eight rows per account, in cache order. Rows are never merged: CNY and USD, or
    // primary and weekly windows, stay separate.
    static func summaryMetrics(_ account: WidgetAccountSnapshot, at now: Date,
                               limit: Int = WidgetSnapshotLimits.maximumMetricsPerAccount)
        -> [WidgetMetricSummary] {
        var seen: Set<String> = []
        let maximum = max(0, min(limit, WidgetSnapshotLimits.maximumMetricsPerAccount))
        return Array(account.metrics.compactMap { metric -> WidgetMetricSummary? in
            guard let clean = metric.sanitized(), seen.insert(clean.id).inserted else { return nil }
            return WidgetMetricSummary(metric: clean, resetStatus: resetStatus(clean, at: now))
        }.prefix(maximum))
    }

    static func selectedAccounts(_ snapshot: WidgetSnapshot?,
                                 selectedIDs: [UUID]? = nil) -> [WidgetAccountSnapshot] {
        guard let snapshot, let clean = snapshot.sanitized() else { return [] }
        let accounts = Array(clean.accounts.prefix(WidgetSnapshotLimits.maximumAccounts))
        guard let selectedIDs else { return accounts }
        var seen: Set<UUID> = []
        var result: [WidgetAccountSnapshot] = []
        for id in selectedIDs {
            guard seen.insert(id).inserted else { continue }
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            result.append(account)
            if result.count == WidgetSnapshotLimits.maximumAccounts { break }
        }
        return result
    }

    static func displayState(accounts: [WidgetAccountSnapshot], at now: Date)
        -> WidgetDisplayState {
        guard !accounts.isEmpty else { return .empty }
        let failed = accounts.filter { $0.lastError?.isEmpty == false }.count
        if failed == accounts.count { return .error }
        if failed > 0 { return .stale }
        let needsConfirmation = accounts.contains { account in
            isStale(account, at: now)
                || account.metrics.isEmpty
                || account.metrics.contains { resetStatus($0, at: now).isPassed }
        }
        return needsConfirmation ? .stale : .healthy
    }

    static func displaySummary(_ snapshot: WidgetSnapshot?,
                               selectedIDs: [UUID]? = nil,
                               limit: Int = WidgetSnapshotLimits.maximumAccounts,
                               at now: Date = Date()) -> WidgetDisplaySummary {
        let selected = selectedAccounts(snapshot, selectedIDs: selectedIDs)
        let maximum = max(0, min(limit, WidgetSnapshotLimits.maximumAccounts))
        let visible = Array(selected.prefix(maximum))
        return WidgetDisplaySummary(
            state: displayState(accounts: visible, at: now),
            accounts: visible,
            overflowCount: max(0, selected.count - visible.count),
            needsRefresh: selected.contains { needsRefresh($0, at: now) })
    }

    // Earliest cached boundary for the caller's WidgetKit timeline. It is a hint only:
    // the system decides whether/when to reload and may delay it (never real time).
    static func nextRefreshDate(_ snapshot: WidgetSnapshot?, at now: Date) -> Date? {
        guard let snapshot, let clean = snapshot.sanitized() else { return nil }
        var dates: [Date] = []
        for account in clean.accounts {
            if let interval = interval(for: account.provider) {
                let stale = account.capturedAt.addingTimeInterval(interval)
                if stale > now { dates.append(stale) }
            }
            dates.append(contentsOf: account.metrics.compactMap {
                guard let reset = $0.resetAt, reset > now else { return nil }
                return reset
            })
        }
        return dates.min()
    }
}
