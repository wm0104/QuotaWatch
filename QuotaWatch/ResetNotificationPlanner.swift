import Foundation

// Foundation-only planning: never infer a reset from a duration or a failed fetch.
struct ResetNotificationPlan: Equatable {
    let identifier: String
    let accountID: UUID
    let metricID: String
    let resetAt: Date
    let title: String
    let body: String
}

enum ResetNotificationPlanner {
    static let prefix = "reset-"
    static func identifier(accountID: UUID, metricID: String) -> String {
        prefix + accountID.uuidString + "-" + Data(metricID.utf8).base64EncodedString()
    }
    static func enabledIdentifiers(_ accounts: [Account]) -> Set<String> {
        Set(accounts.filter { $0.kind == .codex && !$0.requiresAuth }.flatMap { account in
            (account.resetAlerts ?? []).map { identifier(accountID: account.id, metricID: $0) }
        })
    }
    static func capacity(otherPending: Int) -> Int {
        // shortcut: reserve 8 of iOS's 64 slots for low/test/other notifications.
        // Deferred windows require a later reconciliation; there is no repeating timer.
        max(0, min(48, 56 - max(0, otherPending)))
    }
    static func plans(accounts: [Account], permitted: Bool, otherPending: Int = 0,
                      now: Date = Date()) -> [ResetNotificationPlan] {
        Array(candidates(accounts: accounts, permitted: permitted, now: now)
            .prefix(capacity(otherPending: otherPending)))
    }
    static func candidates(accounts: [Account], permitted: Bool,
                           now: Date = Date()) -> [ResetNotificationPlan] {
        guard permitted else { return [] }
        var result: [ResetNotificationPlan] = []
        var seen: Set<String> = []
        for account in accounts where account.kind == .codex && !account.requiresAuth {
            guard let snapshot = account.snapshot, snapshot.capturedAt <= now else { continue }
            for metric in snapshot.metrics where metric.unit == .percent && !metric.unlimited {
                guard account.resetAlerts?.contains(metric.id) == true,
                      let reset = metric.resetAt, reset.timeIntervalSince1970.isFinite,
                      reset > now, reset > snapshot.capturedAt else { continue }
                let id = identifier(accountID: account.id, metricID: metric.id)
                guard seen.insert(id).inserted else { continue }
                let name = QuotaDisplayRules.title(metric)
                    .replacingOccurrences(of: #"(\d) (小时|天|分钟|秒)"#, with: "$1$2", options: .regularExpression)
                result.append(ResetNotificationPlan(identifier: id, accountID: account.id,
                    metricID: metric.id, resetAt: reset, title: "\(name)额度重置时间已到",
                    body: "\(account.alias)：点击查看恢复后的最新额度"))
            }
        }
        return result.sorted {
            $0.resetAt == $1.resetAt ? $0.identifier < $1.identifier : $0.resetAt < $1.resetAt
        }
    }
}

struct NotificationTap: Equatable, Identifiable {
    let id: String
    let accountID: UUID?
    let deliveredAt: Date

    init(identifier: String, deliveredAt: Date, userInfo: [AnyHashable: Any]) {
        id = identifier + ":" + String(deliveredAt.timeIntervalSince1970)
        accountID = (userInfo["accountID"] as? String).flatMap(UUID.init(uuidString:))
        self.deliveredAt = deliveredAt
    }
    func destination(in accounts: [Account]) -> UUID? {
        guard let accountID, accounts.contains(where: { $0.id == accountID }) else { return nil }
        return accountID
    }
}
