import Foundation

// Foundation-only synthetic fixtures. No permissions, accounts or notification delivery.
@main
struct ResetNotificationTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
    static func account(_ id: UUID = UUID(), alias: String = "合成账户") -> Account {
        let metrics = [
            QuotaMetric(id: "codex.primary.18000", title: "主要额度", unit: .percent,
                        remaining: 25, resetAt: now.addingTimeInterval(600)),
            QuotaMetric(id: "codex.secondary.604800", title: "次要额度", unit: .percent,
                        remaining: 50, resetAt: now.addingTimeInterval(1200))
        ]
        return Account(id: id, kind: .codex, alias: alias, remoteID: "synthetic-account",
                       identity: "synthetic@example.invalid",
                       snapshot: QuotaSnapshot(capturedAt: now, metrics: metrics))
    }
    static func plans(_ values: [Account], permitted: Bool = true, other: Int = 0) -> [ResetNotificationPlan] {
        ResetNotificationPlanner.plans(accounts: values, permitted: permitted, otherPending: other, now: now)
    }
    static func ids(_ plans: [ResetNotificationPlan]) -> Set<String> { Set(plans.map(\.identifier)) }

    static func main() throws {
        var a = account(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let primary = a.snapshot!.metrics[0].id
        let secondary = a.snapshot!.metrics[1].id
        expect(a.resetAlerts == nil && plans([a]).isEmpty, "New account defaults off")
        a.resetAlerts = [primary, secondary]
        a.rules = [AlertRule(metricID: primary, threshold: 30)]
        a.latched = [primary]
        let encoded = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Account.self, from: encoded)
        expect(decoded == a, "New account round trip retains independent settings")
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "resetAlerts")
        let legacy = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        expect(legacy.resetAlerts == nil && plans([legacy]).isEmpty, "Old JSON defaults off")
        expect(legacy.snapshot == a.snapshot && legacy.rules == a.rules, "Legacy quota/rules retained")
        json["resetAlerts"] = NSNull()
        let null = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        expect(null.resetAlerts == nil, "Explicit null defaults off")
        json["resetAlerts"] = [primary, primary]
        let duplicate = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        expect(duplicate.resetAlerts == [primary], "Duplicate settings decoded as set")
        json["resetAlerts"] = "invalid"
        do {
            _ = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
            fatalError("Malformed settings must not silently enable notifications")
        } catch { checks += 1 }

        let original = plans([a])
        expect(original.count == 2 && ids(original).count == 2, "Windows independently identified")
        expect(a.latched == [primary] && a.rules.count == 1, "Reset planning never changes low-alert rules or latch")
        let low = AlertEvaluator.evaluate(snapshot: a.snapshot!, rules: a.rules, latched: [], interval: 300, now: now)
        expect(low.notify == [primary], "Low-alert evaluation remains independent")
        expect(original[0].resetAt < original[1].resetAt, "Earliest first")
        expect(original[0].title.contains("5小时"), "Uses real window title")
        expect(original[0].title == "5小时额度重置时间已到", "Title reports only the server reset time")
        expect(original[0].body == "合成账户：点击查看恢复后的最新额度" && !original[0].body.contains("100%"), "Click to query, no recovery guarantee")
        expect(plans([a], permitted: false).isEmpty, "No permission no schedules")
        expect(plans([a, a]) == original, "Duplicate accounts do not duplicate requests")
        a.snapshot!.metrics.append(a.snapshot!.metrics[0])
        expect(plans([a]) == original, "Duplicate metric ID deduplicated")
        a.snapshot!.metrics.removeLast()
        var b = account(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        b.resetAlerts = [primary]
        expect(plans([a, b]).count == 3, "Accounts remain independent")
        expect(ids(plans([a, b])).count == 3, "Stable unique request IDs across accounts")
        expect(ResetNotificationPlanner.identifier(accountID: a.id, metricID: "窗口/a") !=
               ResetNotificationPlanner.identifier(accountID: a.id, metricID: "窗口/a/"), "Metric IDs are lossless, not sanitized collisions")

        a.resetAlerts = [primary]
        expect(plans([a]).count == 1 && plans([a])[0].metricID == primary, "Toggle one window only")
        expect(ids(original).subtracting(ids(plans([a]))).count == 1, "Off cancels only its own window")
        expect(ids(original).subtracting(ids(plans([]))) == ids(original), "Delete cancels account schedules")
        var renamed = a
        renamed.alias = "改名后的合成账户"
        expect(plans([renamed])[0].identifier == plans([a])[0].identifier, "Rename replaces same request")
        expect(plans([renamed])[0].body != plans([a])[0].body, "Rename updates body")
        var changed = a
        changed.snapshot!.metrics[0].resetAt = now.addingTimeInterval(900)
        expect(plans([changed])[0].identifier == plans([a])[0].identifier, "Refresh replaces rather than adds")
        expect(plans([changed])[0].resetAt != plans([a])[0].resetAt, "Refresh uses new server resetAt")
        changed.remoteID = "another-identity"
        changed.identity = "another@example.invalid"
        changed.resetAlerts = nil // AccountStore clears opt-ins when verified identity changes.
        expect(plans([changed]).isEmpty, "New identity must opt in again")
        expect(ResetNotificationPlanner.enabledIdentifiers([changed]).isEmpty, "New identity clears delivered ownership")
        a.error = "网络暂时失败"
        a.nextAllowedAt = now.addingTimeInterval(300)
        expect(plans([a]).count == 1, "Transient failure preserves reliable future schedule")
        a.requiresAuth = true
        expect(plans([a]).isEmpty && ResetNotificationPlanner.enabledIdentifiers([a]).isEmpty, "Invalid auth cancels pending and delivered")
        a.requiresAuth = false
        a.error = nil
        a.kind = .deepseek
        expect(plans([a]).isEmpty, "DeepSeek never schedules resets")
        a.kind = .codex
        a.snapshot!.metrics[0].resetAt = nil
        expect(plans([a]).isEmpty, "No resetAt means no guess from duration")
        a.snapshot!.metrics[0].durationSeconds = 18000
        expect(plans([a]).isEmpty, "Duration alone never schedules")
        for seconds in [-1.0, 0] {
            a.snapshot!.metrics[0].resetAt = now.addingTimeInterval(seconds)
            expect(plans([a]).isEmpty, "Past or due time does not repeat")
        }
        a.snapshot!.metrics[0].resetAt = Date(timeIntervalSince1970: .infinity)
        expect(plans([a]).isEmpty, "Non-finite reset rejected")
        a.snapshot!.metrics[0].resetAt = now.addingTimeInterval(600)
        a.snapshot!.metrics[0].unlimited = true
        expect(plans([a]).isEmpty, "Unlimited not scheduled")
        a.snapshot!.metrics[0].unlimited = false
        a.snapshot!.metrics[0].unit = .credits
        expect(plans([a]).isEmpty, "Credits not scheduled")
        a.snapshot!.metrics[0].unit = .percent
        a.snapshot!.capturedAt = now.addingTimeInterval(1)
        expect(plans([a]).isEmpty, "Future snapshot rejected")
        a.snapshot!.capturedAt = now.addingTimeInterval(-86400)
        expect(plans([a]).count == 1, "A stale snapshot can still have a reliable future reset")
        let afterReset = ResetNotificationPlanner.plans(accounts: [a], permitted: true, now: now.addingTimeInterval(601))
        expect(afterReset.isEmpty, "Clock passing reset does not rearm")
        a.snapshot = nil
        expect(plans([a]).isEmpty, "Missing snapshot not scheduled")

        var many = account()
        many.snapshot!.metrics = (0..<70).map { index in
            QuotaMetric(id: "synthetic.\(index)", title: "窗口 \(index)", unit: .percent,
                        remaining: 50, resetAt: now.addingTimeInterval(Double(70 - index) * 60))
        }
        many.resetAlerts = Set(many.snapshot!.metrics.map(\.id))
        expect(ResetNotificationPlanner.candidates(accounts: [many], permitted: true, now: now).count == 70, "Capacity reports actual deferred count")
        expect(plans([many]).count == 48, "Conservative reset ceiling")
        expect(plans([many]).first!.resetAt == now.addingTimeInterval(60), "Prioritize earliest")
        expect(plans([many], other: 20).count == 36, "Other pending notifications consume capacity")
        expect(plans([many], other: 56).isEmpty && plans([many], other: 64).isEmpty, "Full queue does not overflow")
        expect(plans([many], other: -1).count == 48, "Defensive negative input")
        expect(plans([many], other: Int.max).isEmpty, "Large count does not overflow")
        let reversed = Array(many.snapshot!.metrics.reversed())
        many.snapshot!.metrics = reversed
        expect(plans([many]).first!.resetAt == now.addingTimeInterval(60), "Input order does not alter priority")
        for index in many.snapshot!.metrics.indices { many.snapshot!.metrics[index].resetAt = now.addingTimeInterval(600) }
        let tied = plans([many])
        expect(tied.map(\.identifier) == tied.map(\.identifier).sorted(), "Tie order deterministic")
        expect(ids(tied).count == tied.count, "No duplicates under capacity")
        expect(ResetNotificationPlanner.enabledIdentifiers([many]).count == 70, "Delivered opt-in ownership independent of queue truncation")
        many.resetAlerts = []
        expect(plans([many]).isEmpty && ResetNotificationPlanner.enabledIdentifiers([many]).isEmpty, "All off clears pending and delivered")
        repairFixtures()
        print("PASS: \(checks) reset notification checks (synthetic Foundation fixtures; no delivery)")
    }
}

extension ResetNotificationTests {
    static func repairFixtures() {
        for count in [0, 1, 2, 3, 7] {
            expect(QuotaDisplayRules.detailColumnCount(metricCount: count, accessibility: false) == (count <= 1 ? 1 : 2), "Layout follows actual window count, never plan")
            expect(QuotaDisplayRules.detailColumnCount(metricCount: count, accessibility: true) == 1, "Accessibility stacks every window")
        }
        var a = account()
        let revision = a.revision
        expect(ReminderAuthorization.canCommit(expected: revision, current: revision), "Same account revision can commit after authorization")
        expect(!ReminderAuthorization.canCommit(expected: revision, current: UUID()), "Rename/relogin/rule change rejects suspended authorization")
        expect(!ReminderAuthorization.canCommit(expected: revision, current: nil), "Deleted account cannot be recreated by permission completion")
        let tap = NotificationTap(identifier: "reset-fixture", deliveredAt: now, userInfo: ["accountID": a.id.uuidString])
        expect(tap.destination(in: [a]) == a.id, "Notification resolves its own account ID")
        expect(tap.destination(in: []) == nil, "Deleted target safely routes home")
        let other = account()
        expect(tap.destination(in: [other]) == nil, "Never substitute another account")
        let invalid = NotificationTap(identifier: "low-fixture", deliveredAt: now, userInfo: ["accountID": "invalid"])
        expect(invalid.accountID == nil && invalid.destination(in: [a]) == nil, "Malformed target routes home")
        let missing = NotificationTap(identifier: "test", deliveredAt: now, userInfo: [:])
        expect(missing.destination(in: [a]) == nil, "Test notification has no account")
        expect(tap.id == NotificationTap(identifier: "reset-fixture", deliveredAt: now, userInfo: [:]).id, "Repeated callback has same delivery key")
        expect(tap.id != NotificationTap(identifier: "reset-fixture", deliveredAt: now.addingTimeInterval(1), userInfo: [:]).id, "New delivery of same request is independent")

        a.snapshot!.capturedAt = now.addingTimeInterval(-120)
        a.snapshot!.metrics[0].resetAt = now
        a.lastAttempt = now.addingTimeInterval(-5)
        expect(QuotaRefreshPolicy.hasUnobservedReset(a, now: now), "Expired old window detected on ordinary open")
        expect(QuotaRefreshPolicy.allows(a, forced: false, now: now), "Newly due reset bypasses 5-minute interval")
        a.nextAllowedAt = now.addingTimeInterval(120)
        expect(!QuotaRefreshPolicy.allows(a, forced: false, now: now), "Due reset respects server Retry-After")
        expect(!QuotaRefreshPolicy.allows(a, forced: true, notificationAt: now, now: now), "Notification cannot bypass server limit")
        a.nextAllowedAt = now
        a.requiresAuth = true
        expect(!QuotaRefreshPolicy.allows(a, forced: true, notificationAt: now, now: now), "Notification cannot bypass invalid authentication")
        a.requiresAuth = false
        a.error = "合成网络失败"
        expect(!QuotaRefreshPolicy.allows(a, forced: false, now: now), "Past Retry-After still has failure backoff")
        expect(!QuotaRefreshPolicy.allows(a, forced: true, notificationAt: now, now: now), "Repeated taps do not bypass failure backoff")
        for seconds in [30.0, 60, 120, 240] {
            expect(!QuotaRefreshPolicy.allows(a, forced: false, now: now.addingTimeInterval(seconds)), "Failed old reset never retries every timer tick")
        }
        expect(QuotaRefreshPolicy.allows(a, forced: true, now: now.addingTimeInterval(30)), "Manual retry retains 30-second debounce after server limit expires")
        expect(QuotaRefreshPolicy.allows(a, forced: false, now: now.addingTimeInterval(300)), "Failure retries only after backoff")
        a.error = nil
        a.nextAllowedAt = nil
        a.lastAttempt = now
        a.snapshot!.capturedAt = now.addingTimeInterval(1)
        expect(!QuotaRefreshPolicy.hasUnobservedReset(a, now: now.addingTimeInterval(1)), "Success with same past reset consumes immediate reset check")
        for seconds in [30.0, 60, 90, 120, 240] {
            expect(!QuotaRefreshPolicy.allows(a, forced: false, now: now.addingTimeInterval(seconds)), "Same old reset never creates 30/60-second loop")
        }
        expect(a.snapshot!.metrics[0].remaining == 25, "Clock crossing never invents 100 percent")
        expect(QuotaRefreshPolicy.allows(a, forced: false, now: now.addingTimeInterval(300)), "Ordinary interval remains available")
        expect(!QuotaRefreshPolicy.allows(a, forced: true, notificationAt: now, now: now.addingTimeInterval(2)), "Foreground success after delivery deduplicates tap refresh")
        expect(QuotaRefreshPolicy.allows(a, forced: false, notificationAt: now.addingTimeInterval(2), now: now.addingTimeInterval(2)), "New tap queries even within normal interval")
        a.snapshot!.metrics[0].resetAt = nil
        expect(!QuotaRefreshPolicy.hasUnobservedReset(a, now: now), "Unknown time never guesses a reset")
        a.snapshot!.metrics[0].resetAt = now.addingTimeInterval(2)
        expect(QuotaRefreshPolicy.nextCheckDelay([a], now: now) == 2, "Foreground wakes at real reset time")
        a.snapshot!.metrics[0].resetAt = now.addingTimeInterval(-2)
        expect(QuotaRefreshPolicy.nextCheckDelay([a], now: now) == 60, "Past reset cannot busy-loop the timer")
        a.snapshot!.metrics[0].unlimited = true
        expect(!QuotaRefreshPolicy.hasUnobservedReset(a, now: now), "Unlimited window never infers recovery")

        var metric = a.snapshot!.metrics[0]
        metric.resetAt = now
        expect(QuotaDisplayRules.resetText(metric, now: now) == "重置时间已到，等待刷新", "Reached reset shows waiting, not restored")
        metric.resetAt = nil
        expect(QuotaDisplayRules.resetText(metric, now: now) == "服务端未提供可靠重置时间", "Missing time remains unknown")
        let calendar = Calendar.current
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 8))!
        metric.resetAt = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 13, minute: 26))!
        expect(QuotaDisplayRules.resetText(metric, now: today) == "今天 13:26 重置", "Today's reset includes day and precise 24-hour time")
        metric.resetAt = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9, minute: 13))!
        expect(QuotaDisplayRules.resetText(metric, now: today) == "11月17日 09:13 重置", "Later reset includes accurate date and time")
    }
}
