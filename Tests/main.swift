import Foundation

// Run from the repository root:
// swiftc QuotaWatch/Models.swift QuotaWatch/QuotaParser.swift QuotaWatch/QuotaDisplayRules.swift Tests/main.swift -o tests && ./tests
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

func testCredentialRotation() {
    let old = Credential(refreshToken: "synthetic-original", accountID: "fixture-account")
    let new = Credential(refreshToken: "synthetic-rotated", accountID: "fixture-account")
    expect(CredentialRotation.canCommit(new, previous: old, current: old, accountExists: true),
           "A rotated token survives cancellation or a UI-only revision change")
    expect(!CredentialRotation.canCommit(new, previous: old, current: old, accountExists: false),
           "A token rotation cannot resurrect a deleted account")
    expect(!CredentialRotation.canCommit(new, previous: old, current: new, accountExists: true),
           "A late rotation cannot overwrite newer credentials")
    expect(!CredentialRotation.canCommit(new, previous: old, current: nil, accountExists: true),
           "Missing credentials cannot be recreated by a stale request")
    let changed = Credential(refreshToken: "synthetic-original", accountID: "other-fixture-account")
    expect(!CredentialRotation.canCommit(new, previous: old, current: changed, accountExists: true),
           "A different current account blocks stale rotation")
    expect(!CredentialRotation.canCommit(changed, previous: old, current: old, accountExists: true),
           "A refresh response cannot switch the account")
}

func testLegacyCache() throws {
    // Same version-1 envelope shape as LocalArchive, without importing iOS Security.
    struct CachedEnvelope: Codable {
        var schemaVersion: Int
        var accounts: [Account]
    }
    let json = #"""
    {"schemaVersion":1,"accounts":[{
      "id":"00000000-0000-0000-0000-000000000001","kind":"codex","alias":"旧缓存 🐈",
      "remoteID":"synthetic-account","identity":"synthetic@example.invalid",
      "snapshot":{"capturedAt":721692800,"plan":"plus","available":true,"metrics":[
        {"id":"codex.primary.18000","title":"Codex 主要额度（5 小时）","unit":"percent","remaining":10,"resetAt":721693000,"unlimited":false},
        {"id":"codex.credits","title":"Codex 点数","unit":"credits","remaining":0,"unlimited":false}
      ]},
      "rules":[{"metricID":"codex.primary.18000","threshold":10,"enabled":true},
               {"metricID":"codex.credits","threshold":0,"enabled":false}],
      "latched":["codex.primary.18000","removed-metric"],"requiresAuth":false,
      "revision":"00000000-0000-0000-0000-000000000002","createdAt":721692700
    }]}
    """#
    expect(!json.contains("durationSeconds") && !json.contains("creditsAvailable"), "Legacy fixture omits both added fields")
    let archive = try JSONDecoder().decode(CachedEnvelope.self, from: Data(json.utf8))
    expect(archive.schemaVersion == 1 && archive.accounts.count == 1, "Version-1 cache still decodes")
    let account = archive.accounts[0]
    let expectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    expect(account.id == expectedID && account.alias == "旧缓存 🐈", "Legacy UUID and alias retained")
    expect(account.revision == UUID(uuidString: "00000000-0000-0000-0000-000000000002"), "Legacy revision retained")
    expect(account.remoteID == "synthetic-account" && account.identity == "synthetic@example.invalid", "Legacy account metadata retained")
    expect(account.createdAt == clock.addingTimeInterval(-100), "Legacy creation date retained")
    expect(account.rules == [AlertRule(metricID: "codex.primary.18000", threshold: 10),
                             AlertRule(metricID: "codex.credits", threshold: 0, enabled: false)], "Legacy metric IDs, thresholds and enabled state retained")
    expect(account.latched == ["codex.primary.18000", "removed-metric"], "Legacy latches, including removed metric, retained")
    guard let snapshot = account.snapshot else { fatalError("Legacy snapshot lost") }
    expect(snapshot.creditsAvailable == nil && snapshot.metrics.allSatisfy { $0.durationSeconds == nil }, "Missing added optionals decode as unknown")
    expect(metric(snapshot, "codex.credits").remaining == 0, "Legacy raw zero credits retained")
    expect(QuotaDisplayRules.title(snapshot.metrics[0]) == "5 小时", "Legacy duration falls back to stable ID")
    expect(QuotaDisplayRules.isLow(snapshot.metrics[0], account: account, now: clock), "Legacy configured low remains visible despite latch")
    let separateCredential = Credential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", accountID: "synthetic-account")
    let credentialData = try JSONEncoder().encode(separateCredential)
    let decodedCredential = try JSONDecoder().decode(Credential.self, from: credentialData)
    let vault = [expectedID: decodedCredential]
    expect(vault[account.id] == separateCredential, "Unchanged UUID still associates separately encoded credentials")
    let encoded = try JSONEncoder().encode(archive)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    for field in ["apiKey", "accessToken", "refreshToken", "synthetic-access", "synthetic-refresh"] {
        expect(!encodedText.contains(field), "Credentials never enter migrated account cache")
    }
    let restored = try JSONDecoder().decode(CachedEnvelope.self, from: encoded)
    expect(restored.accounts == archive.accounts, "Legacy cache round trip preserves every account field")
}

func testCreditsDisplayAndAlerts() throws {
    let rule = AlertRule(metricID: "codex.credits", threshold: 20)
    for (availability, expected) in [("false", Optional(false)), ("true", Optional(true)), ("null", nil), ("", nil)] {
        for balance in ["0", "12.75", "25", "null", ""] {
            let fields = [availability.isEmpty ? nil : "\"has_credits\":\(availability)",
                          balance.isEmpty ? nil : "\"balance\":\(balance)"].compactMap { $0 }.joined(separator: ",")
            let snapshot = try parse("{\"credits\":{\(fields)}}", .codex)
            let credits = metric(snapshot, "codex.credits")
            let remaining: Decimal? = (balance == "null" || balance.isEmpty) ? nil : decimal(balance)
            expect(snapshot.creditsAvailable == expected, "Credits false/true/null/absent is preserved")
            expect(snapshot.metrics.count == 1 && credits.remaining == remaining, "Credits raw zero/nonzero/unknown is never dropped or invented")
            expect(QuotaDisplayRules.title(credits) == "Credits 余额", "Old/new credits titles normalize without changing cached raw title")
            expect(QuotaDisplayRules.overviewMetrics(snapshot).isEmpty, "Credits are detail-only for every availability")
            let account = Account(kind: .codex, alias: "Synthetic", snapshot: snapshot, rules: [rule])
            let shouldWarn = expected != false && (remaining.map { $0 <= 20 } ?? false)
            let result = AlertEvaluator.evaluate(snapshot: snapshot, rules: [rule], latched: [], interval: 300, now: clock)
            expect(result.notify == (shouldWarn ? [credits.id] : []), "Only explicit false suppresses meaningful numeric credits warnings")
            expect(QuotaDisplayRules.isLow(credits, account: account, now: clock) == shouldWarn, "Display shares credits warning semantics")
            let held: Set<String> = [credits.id, "unrelated"]
            let heldResult = AlertEvaluator.evaluate(snapshot: snapshot, rules: [rule], latched: held, interval: 300, now: clock)
            let shouldRearm = expected != false && (remaining.map { $0 > 20 } ?? false)
            expect(heldResult.latched == (shouldRearm ? ["unrelated"] : held), "Unavailable/unknown credits preserve notification latch")
            let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
            expect(restored == snapshot, "All credits availability states and raw balances round trip")
        }
    }
    let snapshot = try parse(#"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000}},"credits":{"has_credits":false,"balance":0}}"#, .codex)
    let window = metric(snapshot, "codex.primary.18000")
    let rules = [rule, AlertRule(metricID: window.id, threshold: 0)]
    let result = AlertEvaluator.evaluate(snapshot: snapshot, rules: rules, latched: [], interval: 300, now: clock)
    expect(result.notify == [window.id], "Credits false never suppresses a normal window warning")
    for availability in ["false", "true", "null"] {
        let unlimited = try parse("{\"credits\":{\"has_credits\":\(availability),\"unlimited\":true,\"balance\":0}}", .codex)
        let account = Account(kind: .codex, alias: "Synthetic", snapshot: unlimited, rules: [rule])
        expect(metric(unlimited, rule.metricID).remaining == 0, "Unlimited credits retain the upstream raw balance")
        expect(!QuotaDisplayRules.isLow(unlimited.metrics[0], account: account, now: clock), "Unlimited credits never appear low")
    }
}

func testDisplayTitlesAndOverview() throws {
    for (seconds, title) in [(18000, "5 小时"), (604800, "7 天"), (7200, "2 小时"),
                             (9000, "150 分钟"), (300, "5 分钟"), (42, "42 秒"), (12345, "12345 秒")] {
        let snapshot = try parse("{\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":\(seconds)},\"secondary_window\":{\"limit_window_seconds\":\(seconds)}}}", .codex)
        for metric in snapshot.metrics {
            expect(metric.durationSeconds == seconds, "Parser preserves actual window duration independently of role")
            expect(QuotaDisplayRules.title(metric) == title, "Main labels derive from actual duration, not primary/secondary assumptions")
            var cached = metric
            cached.durationSeconds = nil
            expect(QuotaDisplayRules.title(cached) == title, "Legacy positive final ID component supplies duration")
        }
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        expect(restored == snapshot, "New duration metadata round trips without ID changes")
    }
    for plan in ["free", "plus", "pro", "team", "future-plan"] {
        let snapshot = try parse("{\"plan_type\":\"\(plan)\",\"rate_limit\":{\"primary_window\":{},\"secondary_window\":{}}}", .codex)
        expect(QuotaDisplayRules.title(snapshot.metrics[0]) == "主要窗口", "Missing duration never inferred from plan")
        expect(QuotaDisplayRules.title(snapshot.metrics[1]) == "次要窗口", "Unknown secondary never assumed weekly")
        expect(snapshot.metrics.allSatisfy { $0.durationSeconds == nil && $0.remaining == nil }, "No invented duration or zero quota")
    }
    let metadataWins = QuotaMetric(id: "codex.primary.604800", title: "Old title", unit: .percent, remaining: 10, durationSeconds: 18000)
    expect(QuotaDisplayRules.title(metadataWins) == "5 小时", "Explicit duration takes precedence over cached ID")
    let metadataOnly = QuotaMetric(id: "codex.secondary", title: "Old title", unit: .percent, remaining: nil, durationSeconds: 604800)
    expect(QuotaDisplayRules.title(metadataOnly) == "7 天", "Duration metadata works without ID suffix")
    for id in ["codex.primary", "codex.primary.0", "codex.primary.-1", "codex.primary.bad", "codex.primary.99999999999999999999999999"] {
        let metric = QuotaMetric(id: id, title: "Cached", unit: .percent, remaining: nil)
        expect(QuotaDisplayRules.title(metric) == "主要窗口", "Invalid or missing cached duration remains unknown")
    }
    let extra = try parse(#"{"additional_rate_limits":[{"limit_name":"模型 主要额度 α","metered_feature":"model","rate_limit":{"primary_window":{"limit_window_seconds":18000},"secondary_window":{}}},{"limit_name":"Review","rate_limit":{"secondary_window":{"limit_window_seconds":604800}}}]}"#, .codex)
    expect(QuotaDisplayRules.title(extra.metrics[0]) == "模型 主要额度 α 5 小时", "Only redundant suffix removed; upstream model words retained")
    expect(QuotaDisplayRules.title(extra.metrics[1]) == "模型 主要额度 α 次要窗口", "Extra unknown window retains model name and role")
    expect(QuotaDisplayRules.title(extra.metrics[2]) == "Review 7 天", "Extra duration labels retain upstream model name")
    var legacyExtra = extra.metrics[0]
    legacyExtra.durationSeconds = nil
    expect(QuotaDisplayRules.title(legacyExtra) == "模型 主要额度 α 5 小时", "Legacy additional label uses ID duration safely")
    var custom = extra.metrics[0]
    custom.title = "模型自己的 主要额度 文案"
    expect(QuotaDisplayRules.title(custom) == custom.title, "Unrecognized upstream label is not rewritten")
    let money = QuotaMetric(id: "deepseek.balance.cny", title: "CNY 余额", unit: .cny, remaining: nil)
    expect(QuotaDisplayRules.title(money) == money.title, "Non-Codex labels unchanged")
    let windows = (0..<5).map { QuotaMetric(id: "synthetic.window.\($0)", title: "Window \($0)", unit: .percent, remaining: Decimal($0)) }
    let credits = QuotaMetric(id: "nonstandard.credit.id", title: "Credits", unit: .credits, remaining: 0)
    let snapshot = QuotaSnapshot(capturedAt: clock, metrics: [credits] + windows + [money, credits])
    expect(QuotaDisplayRules.overviewMetrics(snapshot) == windows + [money], "Overview filters by credits unit, preserves order and every non-credit metric beyond three")
    expect(snapshot.metrics.count == 8 && snapshot.metrics[0] == credits, "Overview filtering never mutates stored metrics")
}

func testDisplayFreshnessAndLow() {
    let rule = AlertRule(metricID: alertID, threshold: 10)
    let original = Account(kind: .codex, alias: "Synthetic", snapshot: alertSnapshot(10), rules: [rule], latched: [alertID])
    let originalMetric = original.snapshot!.metrics[0]
    func verify(_ account: Account, fresh: Bool, low: Bool, refresh: Bool, _ message: String) {
        let value = account.snapshot?.metrics.first(where: { $0.id == alertID }) ?? originalMetric
        expect(QuotaDisplayRules.isFresh(value, account: account, now: clock) == fresh, "Freshness: \(message)")
        expect(QuotaDisplayRules.isLow(value, account: account, now: clock) == low, "Low display: \(message)")
        expect(QuotaDisplayRules.needsRefresh(account, now: clock) == refresh, "Refresh hint: \(message)")
    }
    verify(original, fresh: true, low: true, refresh: false, "Equality remains low even with a notification latch")
    for rules in [[], [AlertRule(metricID: alertID, threshold: 10, enabled: false)],
                  [AlertRule(metricID: "other-window", threshold: 100)]] {
        var account = original
        account.rules = rules
        verify(account, fresh: true, low: false, refresh: false, "No default threshold, disabled rule or wrong metric")
    }
    for threshold in [decimal("-0.01"), .nan, decimal("100.01")] {
        var account = original
        account.rules = [AlertRule(metricID: alertID, threshold: threshold)]
        verify(account, fresh: true, low: false, refresh: false, "Invalid percent threshold")
    }
    let remainingValues: [Decimal?] = [nil, decimal("-0.01"), .nan, decimal("100.01"), decimal("10.0000000000000001")]
    for remaining in remainingValues {
        var account = original
        account.snapshot!.metrics[0].remaining = remaining
        verify(account, fresh: true, low: false, refresh: false, "Unknown/invalid/above-threshold remaining")
    }
    for value in [Decimal(0), 100] {
        var account = original
        account.rules = [AlertRule(metricID: alertID, threshold: value)]
        account.snapshot!.metrics[0].remaining = value
        verify(account, fresh: true, low: true, refresh: false, "Inclusive valid percent endpoint")
    }
    var unlimited = original
    unlimited.snapshot!.metrics[0].unlimited = true
    verify(unlimited, fresh: true, low: false, refresh: false, "Unlimited never appears low")
    for age in [TimeInterval(0), 600, 600.001, 900, -1, .infinity, -.infinity, .nan] {
        var account = original
        account.snapshot!.capturedAt = clock.addingTimeInterval(-age)
        let fresh = age.isFinite && age >= 0 && age <= 600
        verify(account, fresh: fresh, low: fresh, refresh: !fresh, "Inclusive age boundary, stale, future or nonfinite timestamp")
    }
    for reset in [clock.addingTimeInterval(-1), clock, clock.addingTimeInterval(1)] {
        var account = original
        account.snapshot!.metrics[0].resetAt = reset
        let fresh = reset > clock
        verify(account, fresh: fresh, low: fresh, refresh: !fresh, "Per-metric reset boundary")
    }
    var failed = original
    failed.error = "Synthetic failure"
    verify(failed, fresh: false, low: false, refresh: true, "Account error invalidates cached low")
    failed.error = ""
    verify(failed, fresh: false, low: false, refresh: true, "Even empty non-nil error invalidates data")
    var auth = original
    auth.requiresAuth = true
    verify(auth, fresh: false, low: false, refresh: true, "Authentication required")
    var missing = original
    missing.snapshot = nil
    verify(missing, fresh: false, low: false, refresh: true, "No snapshot")
    var empty = original
    empty.snapshot!.metrics = []
    verify(empty, fresh: false, low: false, refresh: false, "Empty but fresh snapshot is not low")
    let foreign = QuotaMetric(id: "not-in-snapshot", title: "Synthetic", unit: .percent, remaining: 0)
    expect(!QuotaDisplayRules.isFresh(foreign, account: original, now: clock), "Freshness requires matching metric ID in snapshot")
    expect(!QuotaDisplayRules.isLow(foreign, account: original, now: clock), "Detached metric cannot inherit another metric's low rule")
    var futureNow = original
    futureNow.snapshot!.capturedAt = clock
    expect(!QuotaDisplayRules.isFresh(originalMetric, account: futureNow, now: Date(timeIntervalSince1970: .nan)), "Nonfinite now cannot be fresh")
    expect(QuotaDisplayRules.needsRefresh(futureNow, now: Date(timeIntervalSince1970: .nan)), "Nonfinite now requests refresh")

    for (remaining, threshold, low) in [("150.10", "150.10", true), ("150.1000000000000001", "150.10", false),
                                       ("0.0000000000000001", "0.0000000000000001", true), ("0.10", "0.09", false)] {
        var account = original
        account.kind = .deepseek
        account.snapshot!.metrics[0].unit = .cny
        account.snapshot!.metrics[0].remaining = decimal(remaining)
        account.rules = [AlertRule(metricID: alertID, threshold: decimal(threshold))]
        account.snapshot!.capturedAt = clock.addingTimeInterval(-1200)
        verify(account, fresh: true, low: low, refresh: false, "Decimal amounts are exact, uncapped and use provider interval")
        account.snapshot!.capturedAt = clock.addingTimeInterval(-1200.001)
        verify(account, fresh: false, low: false, refresh: true, "DeepSeek twice-interval expiry")
    }
    expect(original.latched == [alertID] && original.rules == [rule], "Display evaluation never mutates rules or notification latch")
}

func testWindowIndependence() throws {
    let snapshot = try parse(#"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_at":1699999999},"secondary_window":{"used_percent":90,"limit_window_seconds":604800,"reset_at":1700000100}},"credits":{"has_credits":false,"balance":0}}"#, .codex)
    let primary = snapshot.metrics[0]
    let secondary = snapshot.metrics[1]
    var account = Account(kind: .codex, alias: "Synthetic", snapshot: snapshot,
                          rules: [AlertRule(metricID: primary.id, threshold: 10), AlertRule(metricID: secondary.id, threshold: 10)],
                          latched: [secondary.id])
    expect(QuotaDisplayRules.needsRefresh(account, now: clock), "One expired visible window requests refresh")
    expect(!QuotaDisplayRules.isFresh(primary, account: account, now: clock), "Expired window alone is stale")
    expect(!QuotaDisplayRules.isLow(primary, account: account, now: clock), "Expired window never shows low")
    expect(QuotaDisplayRules.isFresh(secondary, account: account, now: clock), "Another live window remains independently fresh")
    expect(QuotaDisplayRules.isLow(secondary, account: account, now: clock), "Expired sibling and notification latch never mask a live window's configured low")
    account.rules = [AlertRule(metricID: primary.id, threshold: 100)]
    expect(!QuotaDisplayRules.isLow(secondary, account: account, now: clock), "Rules never bleed between windows")
    account.snapshot!.metrics = [snapshot.metrics[2]]
    account.snapshot!.metrics[0].resetAt = clock.addingTimeInterval(-1)
    expect(!QuotaDisplayRules.needsRefresh(account, now: clock), "Hidden credits expiry alone does not stale the overview")
    expect(QuotaDisplayRules.overviewMetrics(account.snapshot!).isEmpty, "Credit-only snapshots have no overview windows")
    expect(!QuotaDisplayRules.isLow(account.snapshot!.metrics[0], account: account, now: clock), "Empty visible overview never fabricates low")
}

do {
    testCredentialRotation()
    try testModels()
    try testDeepSeek()
    try testCodex()
    testInvalidResponses()
    try testAlerts()
    try testLegacyCache()
    try testCreditsDisplayAndAlerts()
    try testDisplayTitlesAndOverview()
    testDisplayFreshnessAndLow()
    try testWindowIndependence()
    print("PASS: \(checks) checks (synthetic fixtures; no network or secrets)")
} catch {
    fatalError("Unexpected test error: \(error.localizedDescription)")
}
