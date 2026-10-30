import Foundation

// Run from the repository root:
// swiftc QuotaWatch/Models.swift QuotaWatch/QuotaParser.swift Tests/main.swift -o tests && ./tests
let clock = Date(timeIntervalSince1970: 1_700_000_000)
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    checks += 1
    guard condition() else { fatalError(message, file: file, line: line) }
}

func decimal(_ text: String) -> Decimal {
    guard let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("Invalid synthetic decimal")
    }
    return result
}

func parse(_ json: String, _ kind: ProviderKind) throws -> QuotaSnapshot {
    try QuotaParser.parse(Data(json.utf8), kind: kind, now: clock)
}

func metric(_ snapshot: QuotaSnapshot, _ id: String) -> QuotaMetric {
    guard let result = snapshot.metrics.first(where: { $0.id == id }) else {
        fatalError("Missing synthetic metric: \(id)")
    }
    return result
}

func rejects(_ json: String, _ kind: ProviderKind) {
    do {
        _ = try parse(json, kind)
        fatalError("Malformed synthetic response was accepted")
    } catch let error as QuotaError {
        expect(!error.localizedDescription.isEmpty, "Errors are user-readable")
        expect(!error.localizedDescription.contains("do-not-echo-fixture"), "Errors do not expose responses")
    } catch {
        fatalError("Parser must expose only sanitized QuotaError")
    }
}

func testModels() throws {
    expect(ProviderKind.codex.interval == 300 && ProviderKind.deepseek.interval == 600, "Refresh intervals")
    expect(ProviderKind.codex.id == "codex" && ProviderKind.deepseek.name == "DeepSeek", "Provider metadata")
    let credential = Credential(apiKey: "synthetic-only", identity: "测试 🐈", expiresAt: clock)
    expect(credential.accessToken == nil && credential.refreshToken == nil, "Credential defaults")
    let encodedCredential = try JSONEncoder().encode(credential)
    let decodedCredential = try JSONDecoder().decode(Credential.self, from: encodedCredential)
    expect(decodedCredential == credential, "Credential Codable")
    let rule = AlertRule(metricID: "deepseek.balance.cny", threshold: decimal("0.10"))
    expect(rule.enabled && rule.id == rule.metricID, "Alert rule defaults")
    let account = Account(kind: .deepseek, alias: "个人/工作 🐈‍⬛", rules: [rule], createdAt: clock)
    let encoded = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(Account.self, from: encoded)
    expect(decoded == account, "Unicode account Codable")
    expect(account.snapshot == nil && account.latched.isEmpty && !account.requiresAuth, "Account defaults")
    let text = String(decoding: encoded, as: UTF8.self)
    expect(!text.contains("apiKey") && !text.contains("accessToken"), "Account cache has no credentials")
}

func testDeepSeek() throws {
    let snapshot = try parse(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12345678901234567890.123456789","granted_balance":"2.25","topped_up_balance":"3.50"},{"currency":"USD","total_balance":"0.10","granted_balance":"0.00"}]}"#, .deepseek)
    let cny = metric(snapshot, "deepseek.balance.cny")
    let usd = metric(snapshot, "deepseek.balance.usd")
    expect(snapshot.capturedAt == clock && snapshot.available == true, "Capture time and availability")
    expect(snapshot.metrics.count == 2 && cny.unit == .cny && usd.unit == .usd, "Separate currency units")
    expect(cny.remaining == decimal("12345678901234567890.123456789"), "Money uses Decimal, not Double")
    expect(cny.granted == decimal("2.25") && cny.toppedUp == decimal("3.50"), "Balance components retained")
    expect(usd.remaining == decimal("0.1") && usd.toppedUp == nil, "Missing is not zero")
    expect(snapshot.metrics.allSatisfy { $0.unit != .percent && $0.resetAt == nil }, "No fabricated DeepSeek percent/reset")
    let missing = try parse(#"{"is_available":false,"balance_infos":[{"currency":"CNY","granted_balance":"4","topped_up_balance":"8"}]}"#, .deepseek)
    expect(missing.available == false && missing.metrics[0].remaining == nil, "No inferred sum or unavailable zero")
    let empty = try parse(#"{"is_available":false,"balance_infos":[]}"#, .deepseek)
    expect(empty.metrics.isEmpty, "Empty valid balances are unknown")
    let zero = try parse(#"{"balance_infos":[{"currency":"CNY","total_balance":"0","granted_balance":null}]}"#, .deepseek)
    expect(zero.metrics[0].remaining == 0 && zero.metrics[0].granted == nil && zero.available == nil, "Explicit zero versus null")
    let numeric = try parse(#"{"balance_infos":[{"currency":"USD","total_balance":12.5}]}"#, .deepseek)
    expect(numeric.metrics[0].remaining == decimal("12.5"), "JSON numeric balances also supported")
    let roundTrip = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
    expect(roundTrip == snapshot, "Snapshot Codable preserves balances")
}

func testCodex() throws {
    let snapshot = try parse(#"{"plan_type":"团队 Pro 🚀","rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":87.5,"limit_window_seconds":12345,"reset_at":1700000200,"reset_after_seconds":10},"secondary_window":{"used_percent":104,"limit_window_seconds":765432,"reset_after_seconds":90}},"credits":{"has_credits":false,"unlimited":false,"balance":"123.4567890123456789"}}"#, .codex)
    let primary = metric(snapshot, "codex.primary.12345")
    let secondary = metric(snapshot, "codex.secondary.765432")
    expect(snapshot.plan == "团队 Pro 🚀" && snapshot.available == false, "Unicode/future plan and allowed flag")
    expect(snapshot.metrics.count == 3 && primary.unit == .percent, "Separate windows and credits")
    expect(primary.remaining == decimal("12.5") && secondary.remaining == 0, "100-used and valid overage clamp")
    expect(primary.resetAt == clock.addingTimeInterval(200), "Absolute reset takes precedence")
    expect(secondary.resetAt == clock.addingTimeInterval(90), "Relative reset fallback")
    let credits = metric(snapshot, "codex.credits")
    expect(credits.unit == .credits && credits.remaining == decimal("123.4567890123456789"), "Credits have no currency/price conversion")
    let unknown = try parse(#"{"rate_limit":{"allowed":false,"primary_window":{},"secondary_window":{"used_percent":null}},"credits":{"has_credits":false,"unlimited":true}}"#, .codex)
    expect(unknown.metrics.count == 3 && unknown.metrics.allSatisfy { $0.remaining == nil }, "Missing percentages/balance never become zero")
    expect(metric(unknown, "codex.primary").resetAt == nil, "No invented duration/reset")
    expect(metric(unknown, "codex.credits").unlimited, "Unlimited is separate from balance")
    let absent = try parse(#"{"rate_limit":{"allowed":false}}"#, .codex)
    expect(absent.metrics.isEmpty && absent.available == false, "Allowed false without windows is not 0%")
    let empty = try parse(#"{"plan_type":"free","rate_limit":null,"additional_rate_limits":[],"credits":null}"#, .codex)
    expect(empty.metrics.isEmpty, "Nullable/empty upstream quotas remain unknown")
    let metadataOnly = try parse(#"{"plan_type":"plus"}"#, .codex)
    expect(metadataOnly.metrics.isEmpty && metadataOnly.plan == "plus", "Recognized metadata-only payload")

    let extraA = #"{"limit_name":"图像 α","metered_feature":"图像/α","rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":42}}}"#
    let extraB = #"{"limit_name":"Review","metered_feature":"review","rate_limit":{"secondary_window":{"used_percent":10}}}"#
    let a = try parse("{\"additional_rate_limits\":[\(extraA),\(extraB)]}", .codex)
    let b = try parse("{\"additional_rate_limits\":[\(extraB),\(extraA)]}", .codex)
    expect(Set(a.metrics.map(\.id)) == Set(b.metrics.map(\.id)), "Additional IDs do not depend on array order")
    expect(a.metrics[0].id.hasPrefix("codex.additional.") && a.metrics[0].id.hasSuffix(".primary.42"), "Namespaced extra-window ID")
    expect(!a.metrics[0].id.contains("/") && a.metrics[0].title.contains("图像 α"), "Unicode names preserved in titles, escaped in IDs")
    expect(metric(a, "codex.additional.review.secondary").remaining == 90, "Extra limits parsed independently")
}

func testInvalidResponses() {
    for kind in ProviderKind.allCases {
        for json in ["", "{", "[]", "null", "true", "{}", #"{"error":"do-not-echo-fixture"}"#] {
            rejects(json, kind)
        }
    }
    for json in [
        #"{"balance_infos":null}"#, #"{"balance_infos":{}}"#,
        #"{"balance_infos":[null]}"#, #"{"balance_infos":[{}]}"#,
        #"{"balance_infos":[],"is_available":0}"#,
        #"{"balance_infos":[{"currency":"EUR","total_balance":"4"}]}"#,
        #"{"balance_infos":[{"currency":"人民币","total_balance":"4"}]}"#,
        #"{"balance_infos":[{"currency":"CNY"},{"currency":"CNY"}]}"#
    ] { rejects(json, .deepseek) }
    for value in [#""-1""#, "-1", "true", "[]", "{}", #""NaN""#, #""Infinity""#,
                  #""1.2junk""#, #""1,25""#, #""￥1.25""#, #""１２.５""#, #""""#, #""1\n""#] {
        for field in ["total_balance", "granted_balance", "topped_up_balance"] {
            rejects("{\"balance_infos\":[{\"currency\":\"CNY\",\"\(field)\":\(value)}]}", .deepseek)
        }
        rejects("{\"credits\":{\"balance\":\(value)}}", .codex)
    }
    for json in [
        #"{"plan_type":7}"#, #"{"plan_type":"  "}"#,
        #"{"rate_limit":[]}"#, #"{"rate_limit":{"allowed":1}}"#,
        #"{"rate_limit":{"limit_reached":"true"}}"#,
        #"{"rate_limit":{"primary_window":[]}}"#,
        #"{"rate_limit":{"secondary_window":"bad"}}"#,
        #"{"credits":[]}"#, #"{"credits":{"unlimited":"true"}}"#,
        #"{"credits":{"has_credits":0}}"#,
        #"{"additional_rate_limits":{}}"#,
        #"{"additional_rate_limits":[{}]}"#,
        #"{"additional_rate_limits":[{"limit_name":"","rate_limit":{}}]}"#,
        #"{"additional_rate_limits":[{"limit_name":"x","rate_limit":[] }]}"#
    ] { rejects(json, .codex) }
    for value in ["-0.1", "true", #""10""#, #""NaN""#, "[]", "{}"] {
        rejects("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(value)}}}", .codex)
    }
    for (field, values) in [
        ("limit_window_seconds", ["0", "-1", "1.5", "true", #""3600""#]),
        ("reset_at", ["-1", "1.5", "true", #""1700000000""#]),
        ("reset_after_seconds", ["-1", "1.5", "true", #""10""#])
    ] {
        for value in values {
            rejects("{\"rate_limit\":{\"primary_window\":{\"\(field)\":\(value)}}}", .codex)
        }
    }
    let duplicate = #"{"limit_name":"same","rate_limit":{"primary_window":{"used_percent":5}}}"#
    rejects("{\"additional_rate_limits\":[\(duplicate),\(duplicate)]}", .codex)
}

let alertID = "codex.primary.12345"
func alertSnapshot(_ remaining: Decimal?, age: TimeInterval = 0, reset: Date? = nil,
                   unit: QuotaUnit = .percent, unlimited: Bool = false) -> QuotaSnapshot {
    QuotaSnapshot(capturedAt: clock.addingTimeInterval(-age), metrics: [
        QuotaMetric(id: alertID, title: "Synthetic", unit: unit, remaining: remaining,
                    resetAt: reset, unlimited: unlimited)
    ])
}

func testAlerts() throws {
    let rule = AlertRule(metricID: alertID, threshold: 10)
    func evaluate(_ snapshot: QuotaSnapshot, _ latch: Set<String> = [],
                  rules: [AlertRule]? = nil, interval: TimeInterval = 300) -> (notify: [String], latched: Set<String>) {
        AlertEvaluator.evaluate(snapshot: snapshot, rules: rules ?? [rule], latched: latch,
                                interval: interval, now: clock)
    }
    let original: Set<String> = []
    let first = evaluate(alertSnapshot(10), original)
    expect(first.notify == [alertID] && first.latched == [alertID], "First low, including equality, emits and latches")
    expect(original.isEmpty, "Latch is prospective; input is not mutated")
    let second = evaluate(alertSnapshot(9), first.latched)
    expect(second.notify.isEmpty && second.latched == first.latched, "Low -> low emits once")
    let healthy = evaluate(alertSnapshot(decimal("10.01")), second.latched)
    expect(healthy.notify.isEmpty && healthy.latched.isEmpty, "Healthy above threshold rearms")
    let lowAgain = evaluate(alertSnapshot(0), healthy.latched)
    expect(lowAgain.notify == [alertID], "Low -> low -> healthy -> low emits again")

    let held: Set<String> = [alertID, "removed-or-unknown-metric"]
    let missing = QuotaSnapshot(capturedAt: clock, metrics: [])
    expect(evaluate(missing, held).latched == held, "Missing metric keeps every latch")
    expect(evaluate(alertSnapshot(nil), held).latched == held, "Unknown remaining does not rearm")
    expect(evaluate(alertSnapshot(11), held).latched == ["removed-or-unknown-metric"], "Healthy only clears its own latch")
    expect(evaluate(alertSnapshot(0), held, rules: []).latched == held, "Removed rules preserve latches")
    let disabled = AlertRule(metricID: alertID, threshold: 10, enabled: false)
    expect(evaluate(alertSnapshot(0), rules: [disabled]).notify.isEmpty, "Disabled rules never notify")
    expect(evaluate(alertSnapshot(11), held, rules: [disabled]).latched == held, "Disabled rules do not rearm")
    expect(evaluate(alertSnapshot(0), rules: [rule, rule]).notify == [alertID], "Duplicate rules do not double notify")

    expect(evaluate(alertSnapshot(10, age: 600)).notify == [alertID], "Freshness boundary is inclusive")
    for age in [600.001, 900, -1] {
        expect(evaluate(alertSnapshot(0, age: age)).notify.isEmpty, "Stale/future low cannot notify")
        expect(evaluate(alertSnapshot(11, age: age), held).latched == held, "Stale/future healthy cannot rearm")
    }
    for interval in [TimeInterval(0), -1, .infinity, .nan] {
        expect(evaluate(alertSnapshot(0), held, interval: interval).latched == held, "Invalid interval preserves latch")
        expect(evaluate(alertSnapshot(0), interval: interval).notify.isEmpty, "Invalid interval cannot notify")
    }
    for reset in [clock, clock.addingTimeInterval(-1)] {
        expect(evaluate(alertSnapshot(0, reset: reset)).notify.isEmpty, "Expired/reset-now low is unknown")
        expect(evaluate(alertSnapshot(11, reset: reset), held).latched == held, "Reset does not rearm")
    }
    expect(evaluate(alertSnapshot(0, reset: clock.addingTimeInterval(1))).notify == [alertID], "Future reset is live")
    let expired = try parse(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":12345,"reset_at":1699999999,"reset_after_seconds":500}}}"#, .codex)
    expect(evaluate(expired, held).latched == held, "Expired absolute reset is not advanced by a relative hint")
    let nextWindow = evaluate(alertSnapshot(0, reset: clock.addingTimeInterval(500)), held)
    expect(nextWindow.notify.isEmpty && nextWindow.latched == held, "A new reset time alone does not rearm")
    let resetZero = try parse(#"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":12345,"reset_after_seconds":0}}}"#, .codex)
    expect(evaluate(resetZero).notify.isEmpty, "Zero relative reset is expired, not absent")

    for threshold in [decimal("-1"), .nan, decimal("100.01")] {
        let invalid = AlertRule(metricID: alertID, threshold: threshold)
        expect(evaluate(alertSnapshot(0), rules: [invalid]).notify.isEmpty, "Invalid percent thresholds cannot notify")
        expect(evaluate(alertSnapshot(100), held, rules: [invalid]).latched == held, "Invalid threshold does not rearm")
    }
    for remaining in [decimal("-1"), .nan, decimal("100.01")] {
        expect(evaluate(alertSnapshot(remaining)).notify.isEmpty, "Invalid cached values cannot notify")
        expect(evaluate(alertSnapshot(remaining), held).latched == held, "Invalid cached values cannot rearm")
    }
    let hundred = AlertRule(metricID: alertID, threshold: 100)
    expect(evaluate(alertSnapshot(100), rules: [hundred]).notify == [alertID], "100% equality is allowed")
    let moneyRule = AlertRule(metricID: alertID, threshold: decimal("150.10"))
    expect(evaluate(alertSnapshot(decimal("150.10"), unit: .cny), rules: [moneyRule]).notify == [alertID], "Money thresholds are not capped at 100")
    expect(evaluate(alertSnapshot(nil, unit: .credits, unlimited: true), held).latched == held, "Unlimited/missing balance remains non-numeric, not zero/healthy")
    expect(evaluate(alertSnapshot(0, unit: .credits, unlimited: true)).notify.isEmpty, "Unlimited credits never trigger")
}

do {
    try testModels()
    try testDeepSeek()
    try testCodex()
    testInvalidResponses()
    try testAlerts()
    print("PASS: \(checks) checks (synthetic fixtures; no network or secrets)")
} catch {
    fatalError("Unexpected test error: \(error.localizedDescription)")
}
