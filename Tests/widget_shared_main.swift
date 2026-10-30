import Foundation

// Run from the repository root:
// swiftc QuotaWatchWidgetShared/WidgetSnapshot.swift \
//   QuotaWatchWidgetShared/WidgetSnapshotStore.swift \
//   QuotaWatchWidgetShared/WidgetRefreshRules.swift \
//   QuotaWatchWidgetShared/WidgetCredentialStore.swift \
//   Tests/widget_shared_main.swift -o build/tests/widget-shared-tests && \
//   build/tests/widget-shared-tests
//
// Network is not exercised. No real credentials, account IDs, emails or response bodies exist here.

let widgetClock = Date(timeIntervalSince1970: 1_700_000_000)
var widgetChecks = 0

func widgetExpect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    widgetChecks += 1
    guard condition() else { fatalError(message, file: file, line: line) }
}

func widgetDecimal(_ text: String) -> Decimal {
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("Invalid synthetic decimal")
    }
    return value
}

func widgetMetric(_ id: String, unit: String = "percent", remaining: Decimal? = nil,
            resetAt: Date? = nil, unlimited: Bool = false,
            durationSeconds: Int? = nil, title: String = "测试额度") -> WidgetMetricSnapshot {
    WidgetMetricSnapshot(id: id, title: title, unit: unit, remaining: remaining,
                         resetAt: resetAt, unlimited: unlimited,
                         durationSeconds: durationSeconds)
}

func widgetAccount(id: UUID = UUID(), provider: String = "codex", alias: String = "工作",
             metrics: [WidgetMetricSnapshot] = [], credits: Bool? = nil,
             capturedAt: Date = widgetClock, lastError: String? = nil) -> WidgetAccountSnapshot {
    WidgetAccountSnapshot(id: id, provider: provider, displayAlias: alias,
                          metrics: metrics, creditsAvailable: credits,
                          capturedAt: capturedAt, lastError: lastError)
}

func widgetJSONObject(_ data: Data) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fatalError("Synthetic JSON is not an object")
    }
    return object
}

func widgetEncodedObject(_ object: [String: Any]) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        fatalError("Synthetic JSON object could not be encoded")
    }
    return data
}

func testWidgetSanitizeAndBounds() throws {
    let longAlias = String(repeating: "辅", count: 80)
    let emailAlias = "me@example.com"
    let valid = widgetAccount(
        id: UUID(), provider: "codex", alias: longAlias,
        metrics: [
            widgetMetric("codex.primary.604800", remaining: 42, resetAt: widgetClock.addingTimeInterval(60),
                   durationSeconds: 604800),
            widgetMetric("codex.secondary.18000", remaining: 70, durationSeconds: 18000),
            widgetMetric("bad unit", unit: "eur", remaining: 1),
            widgetMetric("codex.too.high", remaining: 101),
            widgetMetric("codex.negative", remaining: -1),
            widgetMetric("codex.duration.zero", remaining: 5, durationSeconds: 0),
            widgetMetric("codex.duration.big", remaining: 5, durationSeconds: 999_999_999)
        ],
        credits: true, lastError: "HTTP 500 {\"detail\":\"do-not-echo\"}")
    let email = widgetAccount(provider: "deepseek", alias: emailAlias,
                        metrics: [widgetMetric("deepseek.balance.cny", unit: "cny",
                                         remaining: widgetDecimal("12.34"))])
    let unknown = widgetAccount(provider: "other", metrics: [widgetMetric("other.metric")])
    let snapshot = WidgetSnapshot(generatedAt: widgetClock, accounts: [valid, email, unknown])
    guard let clean = snapshot.sanitized() else { fatalError("Valid snapshot was rejected") }

    widgetExpect(clean.schemaVersion == 1, "Schema version is fixed at 1")
    widgetExpect(clean.accounts.count == 2, "Unknown providers are filtered")
    widgetExpect(clean.accounts[0].displayAlias.count == WidgetSnapshotLimits.maximumAliasLength,
           "Alias is bounded")
    widgetExpect(clean.accounts[0].metrics.count == 4,
           "Invalid units and values are filtered; invalid optional durations are cleared")
    widgetExpect(clean.accounts[0].metrics[0].remaining == 42, "Valid percent is unchanged")
    widgetExpect(clean.accounts[0].metrics[0].durationSeconds == 604800, "Valid duration is kept")
    widgetExpect(clean.accounts[0].metrics[1].durationSeconds == 18000, "Second window is separate")
    widgetExpect(clean.accounts[0].metrics[2].durationSeconds == nil
            && clean.accounts[0].metrics[3].durationSeconds == nil,
           "Out-of-range optional durations are cleared, not invented")
    widgetExpect(clean.accounts[0].creditsAvailable == true, "Credits availability is retained")
    widgetExpect(clean.accounts[0].lastError == nil, "Raw response-like errors are not retained")
    widgetExpect(!clean.accounts[1].displayAlias.contains("@"), "Email-like alias is redacted")
    widgetExpect(clean.accounts[1].displayAlias == "[已隐藏]", "Email redaction uses a fixed marker")
    widgetExpect(WidgetSnapshot(generatedAt: widgetClock, accounts: [unknown]).sanitized() == nil,
           "A non-empty snapshot with only unknown providers is invalid")

    let duplicateID = UUID()
    let duplicateMetric = widgetMetric("codex.primary.604800", remaining: 10)
    let manyMetrics = (0..<10).map { widgetMetric("codex.metric.\($0)", remaining: Decimal($0)) }
    let manyAccounts = (0..<6).map { index in
        widgetAccount(id: index == 0 ? duplicateID : UUID(), provider: "codex",
                alias: "A\(index)", metrics: [duplicateMetric] + manyMetrics)
    }
    guard let limited = WidgetSnapshot(generatedAt: widgetClock, accounts: manyAccounts).sanitized() else {
        fatalError("Bounded snapshot was rejected")
    }
    widgetExpect(limited.accounts.count == 5, "At most five accounts survive")
    widgetExpect(Set(limited.accounts.map { $0.id }).count == 5, "Duplicate account UUIDs are removed")
    widgetExpect(limited.accounts.allSatisfy { $0.metrics.count == 8 }, "At most eight metrics survive")
    widgetExpect(limited.accounts[0].metrics.filter { $0.id == duplicateMetric.id }.count == 1,
           "Duplicate metric IDs are removed")

    let badCapture = widgetAccount(capturedAt: Date(timeIntervalSince1970: 5_000_000_000))
    widgetExpect(WidgetSnapshot(generatedAt: widgetClock, accounts: [badCapture]).sanitized() == nil,
           "Out-of-range capture dates are rejected")
    let futureCapture = widgetAccount(capturedAt: widgetClock.addingTimeInterval(301))
    widgetExpect(WidgetSnapshot(generatedAt: widgetClock, accounts: [futureCapture]).sanitized() == nil,
           "Capture dates far newer than generatedAt are rejected")
    widgetExpect(WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: .infinity),
                          accounts: []).sanitized() == nil,
           "Non-finite generatedAt is rejected")

    let empty = WidgetSnapshot(generatedAt: widgetClock, accounts: [])
    widgetExpect(empty.sanitized() != nil, "An empty cache is a valid empty state")
    _ = try empty.jsonData()
}

func testWidgetJSONAndCorruption() throws {
    let id = UUID()
    let source = WidgetSnapshot(generatedAt: widgetClock, accounts: [
        widgetAccount(id: id, provider: "codex", alias: "工作",
                metrics: [widgetMetric("codex.primary.604800", remaining: 42,
                                 resetAt: widgetClock.addingTimeInterval(60))],
                credits: false, lastError: "HTTP 500 []")
    ])
    guard let clean = source.sanitized() else { fatalError("Fixture rejected") }
    let data = try source.jsonData()
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in ["apiKey", "accessToken", "refreshToken", "accountID", "remoteID",
                      "email", "Bearer ", "do-not-echo"] {
        widgetExpect(!text.contains(forbidden), "Snapshot JSON omits \(forbidden)")
    }
    widgetExpect(!text.contains("\n"), "Snapshot JSON is single-line enough for diagnostics")
    widgetExpect(WidgetSnapshot.decode(data) == clean, "JSON round-trip preserves sanitized values")
    widgetExpect(WidgetSnapshot.decode(data)?.accounts[0].id == id, "Only the local UUID identifies an account")

    for corrupt in [Data(), Data("not json".utf8), Data("[]".utf8), Data("{}".utf8)] {
        widgetExpect(WidgetSnapshot.decode(corrupt) == nil, "Corrupt root data returns nil")
    }

    var object = widgetJSONObject(data)
    object["schemaVersion"] = 2
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object)) == nil,
           "Unknown schema version returns nil")

    object = widgetJSONObject(data)
    object.removeValue(forKey: "accounts")
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object)) == nil,
           "Missing accounts key returns nil")

    object = widgetJSONObject(data)
    var accounts = object["accounts"] as? [[String: Any]] ?? []
    accounts.append(["id": "not-a-uuid", "provider": "codex"])
    object["accounts"] = accounts
    let mixed = WidgetSnapshot.decode(widgetEncodedObject(object))
    widgetExpect(mixed?.accounts.count == 1, "One malformed account does not discard a valid sibling")

    object["accounts"] = [["id": "not-a-uuid", "provider": "codex"]]
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object)) == nil,
           "All malformed accounts are corruption, not empty success")

    object = widgetJSONObject(data)
    accounts = object["accounts"] as? [[String: Any]] ?? []
    let captured = accounts[0].removeValue(forKey: "capturedAt")
    accounts[0]["capturesAt"] = captured
    object["accounts"] = accounts
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object))?.accounts[0].capturedAt == widgetClock,
           "Legacy capturesAt key is accepted without changing the canonical model")

    object = widgetJSONObject(data)
    accounts = object["accounts"] as? [[String: Any]] ?? []
    accounts[0]["provider"] = "unknown"
    object["accounts"] = accounts
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object)) == nil,
           "Only filtered providers are corruption, not empty success")

    object = widgetJSONObject(data)
    object["generatedAt"] = 5_000_000_000_000
    widgetExpect(WidgetSnapshot.decode(widgetEncodedObject(object)) == nil,
           "Out-of-range generatedAt returns nil")

    let invalid = WidgetSnapshot(generatedAt: widgetClock, accounts: [widgetAccount(provider: "other")])
    do {
        _ = try invalid.jsonData()
        widgetExpect(false, "Invalid snapshot must not encode")
    } catch {
        widgetExpect(true, "Invalid snapshot throws a sanitized error")
    }
}

func testWidgetStore() throws {
    widgetExpect(WidgetSnapshotStore.appGroupID == "group.com.wm0104.quotawatch",
           "Exact App Group identifier")
    widgetExpect(WidgetSnapshotStore.fileName == "widget-snapshot-v1.json",
           "Exact versioned file name")
    #if !os(iOS)
    do {
        _ = try WidgetSnapshotStore.appGroup()
        widgetExpect(false, "Non-iOS appGroup must not fall back")
    } catch {
        widgetExpect(true, "Non-iOS appGroup reports unavailable")
    }
    #endif

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuotaWatchWidgetShared-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("nested", isDirectory: true)
    let store = WidgetSnapshotStore(directoryURL: directory)
    widgetExpect(store.fileURL.lastPathComponent == WidgetSnapshotStore.fileName,
           "Store writes the fixed file name")
    widgetExpect(store.fileURL.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL, "Store never escapes the injected directory")

    let source = WidgetSnapshot(generatedAt: widgetClock, accounts: [
        widgetAccount(provider: "deepseek", alias: "个人",
                metrics: [widgetMetric("deepseek.balance.cny", unit: "cny",
                                 remaining: widgetDecimal("12.34"))])
    ])
    try store.write(source)
    widgetExpect(store.read() == source.sanitized(), "Write/read round-trip")
    widgetExpect(FileManager.default.fileExists(atPath: store.fileURL.path), "Atomic file exists")

    try Data("garbage".utf8).write(to: store.fileURL)
    widgetExpect(store.read() == nil, "Corrupt file reads as no cache")

    try Data(repeating: 0x7b, count: WidgetSnapshotLimits.maximumFileBytes + 1)
        .write(to: store.fileURL)
    widgetExpect(store.read() == nil, "Oversized file reads as no cache")

    try store.write(source)
    let before = try Data(contentsOf: store.fileURL)
    do {
        try store.write(WidgetSnapshot(generatedAt: widgetClock, accounts: [widgetAccount(provider: "other")]))
        widgetExpect(false, "Invalid write must throw")
    } catch {
        widgetExpect(true, "Invalid write throws")
    }
    let after = try Data(contentsOf: store.fileURL)
    widgetExpect(after == before, "Invalid write preserves the previous file")

    try store.remove()
    widgetExpect(store.read() == nil, "Removed file reads as no cache")
    try store.remove()
    widgetExpect(true, "Removing an absent file is successful")
}

func testWidgetProviderWindowCurrencySeparation() throws {
    let deepseek = widgetAccount(provider: "deepseek", alias: "余额", metrics: [
        widgetMetric("deepseek.balance.cny", unit: "cny", remaining: widgetDecimal("12.34"),
               title: "CNY 余额"),
        widgetMetric("deepseek.balance.usd", unit: "usd", remaining: widgetDecimal("5.67"),
               title: "USD 余额")
    ])
    let summaries = WidgetRefreshRules.summaryMetrics(deepseek, at: widgetClock)
    widgetExpect(summaries.count == 2, "Currency rows stay separate")
    widgetExpect(summaries[0].metric.unit == "cny" && summaries[0].metric.remaining == widgetDecimal("12.34"),
           "CNY value is unchanged")
    widgetExpect(summaries[1].metric.unit == "usd" && summaries[1].metric.remaining == widgetDecimal("5.67"),
           "USD value is unchanged")
    widgetExpect(summaries[0].metric.id != summaries[1].metric.id, "Currencies do not share a metric ID")

    let codex = widgetAccount(provider: "codex", metrics: [
        widgetMetric("codex.primary.604800", remaining: 70, durationSeconds: 604800),
        widgetMetric("codex.secondary.18000", remaining: 40, durationSeconds: 18000)
    ])
    let windows = WidgetRefreshRules.summaryMetrics(codex, at: widgetClock)
    widgetExpect(windows.count == 2, "Quota windows stay separate")
    widgetExpect(windows[0].metric.remaining == 70 && windows[1].metric.remaining == 40,
           "Window values are never summed or averaged")
    widgetExpect(windows[0].metric.durationSeconds != windows[1].metric.durationSeconds,
           "Different windows remain distinguishable")

    let encoded = try WidgetSnapshot(generatedAt: widgetClock, accounts: [deepseek]).jsonData()
    widgetExpect(!String(decoding: encoded, as: UTF8.self).contains("\"total\""),
           "Snapshot has no aggregate total field")

    let noValue = widgetAccount(provider: "deepseek", metrics: [
        widgetMetric("deepseek.balance.cny", unit: "cny", remaining: nil)
    ])
    let missing = WidgetRefreshRules.summaryMetrics(noValue, at: widgetClock)
    widgetExpect(missing.count == 1 && missing[0].metric.remaining == nil,
           "Missing values remain unknown, never zero")
}

func testWidgetStaleAndResetRules() throws {
    widgetExpect(WidgetRefreshRules.interval(for: "codex") == 300, "Codex interval")
    widgetExpect(WidgetRefreshRules.interval(for: "deepseek") == 600, "DeepSeek interval")
    widgetExpect(WidgetRefreshRules.interval(for: "other") == nil, "Unknown provider has no interval")

    let codex = widgetAccount(provider: "codex", metrics: [widgetMetric("codex.primary.604800", remaining: 42)])
    widgetExpect(!WidgetRefreshRules.isStale(codex, at: widgetClock.addingTimeInterval(299.9)),
           "Codex is fresh before 300 seconds")
    widgetExpect(WidgetRefreshRules.isStale(codex, at: widgetClock.addingTimeInterval(300)),
           "Codex is stale at 300 seconds")
    let deepseek = widgetAccount(provider: "deepseek", metrics: [])
    widgetExpect(!WidgetRefreshRules.isStale(deepseek, at: widgetClock.addingTimeInterval(599)),
           "DeepSeek is fresh before 600 seconds")
    widgetExpect(WidgetRefreshRules.isStale(deepseek, at: widgetClock.addingTimeInterval(600)),
           "DeepSeek is stale at 600 seconds")
    widgetExpect(WidgetRefreshRules.isStale(widgetAccount(capturedAt: widgetClock.addingTimeInterval(10)), at: widgetClock),
           "Future capture time is treated as stale")

    let reset = widgetClock.addingTimeInterval(60)
    let resetMetric = widgetMetric("codex.primary.604800", remaining: 42, resetAt: reset)
    widgetExpect(WidgetRefreshRules.resetStatus(resetMetric, at: widgetClock) == .pending(reset),
           "Future reset is pending")
    widgetExpect(WidgetRefreshRules.resetStatus(resetMetric, at: reset) == .passed(reset),
           "Elapsed reset is passed, awaiting confirmation")
    widgetExpect(WidgetRefreshRules.resetStatus(widgetMetric("codex.primary.604800", remaining: 42), at: widgetClock)
            == .none, "Missing reset is unknown")

    let awaiting = widgetAccount(metrics: [resetMetric])
    let summary = WidgetRefreshRules.summaryMetrics(awaiting, at: reset)
    widgetExpect(summary.count == 1, "Passed reset still shows the cached row")
    widgetExpect(summary[0].metric.remaining == 42, "Passed reset keeps the cached remaining value")
    widgetExpect(summary[0].metric.remaining != 100 && summary[0].metric.remaining != 0,
           "Passed reset never synthesizes 100% or 0%")
    widgetExpect(summary[0].resetStatus == .passed(reset), "Reset status is exposed separately")

    let fresh = widgetAccount(metrics: [widgetMetric("codex.primary.604800", remaining: 42,
                                         resetAt: widgetClock.addingTimeInterval(60))])
    widgetExpect(!WidgetRefreshRules.needsRefresh(fresh, at: widgetClock), "Fresh data does not need refresh")
    widgetExpect(WidgetRefreshRules.needsRefresh(fresh, at: widgetClock.addingTimeInterval(61)),
           "A passed reset requests refresh even before the kind interval")
    widgetExpect(WidgetRefreshRules.needsRefresh(widgetAccount(capturedAt: widgetClock.addingTimeInterval(-301)),
                                           at: widgetClock),
           "A stale account requests refresh")
    widgetExpect(WidgetRefreshRules.needsRefresh(
        WidgetSnapshot(generatedAt: widgetClock, accounts: [fresh]), at: widgetClock.addingTimeInterval(61)),
        "Snapshot refresh aggregates account need without changing values")
    widgetExpect(!WidgetRefreshRules.needsRefresh(nil, at: widgetClock), "No snapshot has no refresh need")

    let passedSummary = WidgetRefreshRules.summaryMetrics(
        widgetAccount(metrics: [widgetMetric("codex.primary.604800", remaining: nil, resetAt: widgetClock)]),
        at: widgetClock)
    widgetExpect(passedSummary.count == 1 && passedSummary[0].metric.remaining == nil,
           "Passed reset with unknown remaining does not invent zero")

    let unknownDate = widgetMetric("codex.primary.604800", remaining: 10,
                             resetAt: Date(timeIntervalSince1970: 5_000_000_000))
    widgetExpect(WidgetRefreshRules.resetStatus(unknownDate, at: widgetClock) == .none,
           "Out-of-range reset is treated as unknown")
}

func testWidgetDisplayStateAndSelection() throws {
    let healthyMetric = widgetMetric("codex.primary.604800", remaining: 42,
                               resetAt: widgetClock.addingTimeInterval(600))
    let healthy = widgetAccount(alias: "健康", metrics: [healthyMetric])
    let empty = WidgetSnapshot(generatedAt: widgetClock, accounts: [])
    widgetExpect(WidgetRefreshRules.displaySummary(nil, at: widgetClock).state == .empty,
           "Nil snapshot is empty")
    widgetExpect(WidgetRefreshRules.displaySummary(empty, at: widgetClock).state == .empty,
           "Empty snapshot is empty")
    widgetExpect(WidgetRefreshRules.displayState(accounts: [healthy], at: widgetClock) == .healthy,
           "Fresh data is healthy")
    widgetExpect(WidgetRefreshRules.displayState(
        accounts: [widgetAccount(metrics: [healthyMetric], capturedAt: widgetClock.addingTimeInterval(-301))],
        at: widgetClock) == .stale, "Stale data is stale")
    widgetExpect(WidgetRefreshRules.displayState(
        accounts: [widgetAccount(metrics: [widgetMetric("codex.primary.604800", remaining: 42, resetAt: widgetClock)])],
        at: widgetClock) == .stale, "Passed reset is stale, awaiting confirmation")
    widgetExpect(WidgetRefreshRules.displayState(accounts: [widgetAccount(metrics: [])], at: widgetClock) == .stale,
           "No cached metrics is stale, not healthy")
    let errored = widgetAccount(metrics: [healthyMetric], lastError: "认证已失效")
    widgetExpect(WidgetRefreshRules.displayState(accounts: [errored], at: widgetClock) == .error,
           "All accounts failing is error")
    widgetExpect(WidgetRefreshRules.displayState(accounts: [errored, healthy], at: widgetClock) == .stale,
           "A partially failing overview is stale")
    widgetExpect(WidgetRefreshRules.displayState(accounts: [], at: widgetClock) == .empty,
           "No visible account is empty")

    let ids = (0..<6).map { _ in UUID() }
    let accounts = ids.enumerated().map { index, id in
        widgetAccount(id: id, alias: "A\(index)", metrics: [healthyMetric])
    }
    let snapshot = WidgetSnapshot(generatedAt: widgetClock, accounts: accounts)
    let selected = WidgetRefreshRules.selectedAccounts(
        snapshot, selectedIDs: [ids[3], ids[1], ids[1], UUID(), ids[2]])
    widgetExpect(selected.map { $0.id } == [ids[3], ids[1], ids[2]],
           "Selection preserves order, dedupes, and skips missing IDs")
    let all = WidgetRefreshRules.selectedAccounts(snapshot, selectedIDs: nil)
    widgetExpect(all.count == 5, "Selection without IDs is capped at five")

    let limited = WidgetRefreshRules.displaySummary(
        snapshot, selectedIDs: [ids[3], ids[1], ids[2]], limit: 2, at: widgetClock)
    widgetExpect(limited.accounts.count == 2 && limited.overflowCount == 1
            && limited.selectedCount == 3, "Visible/overflow count is explicit")
    widgetExpect(limited.needsRefresh == false, "Fresh selected accounts do not need refresh")
    let zero = WidgetRefreshRules.displaySummary(
        snapshot, selectedIDs: [ids[3], ids[1]], limit: 0, at: widgetClock)
    widgetExpect(zero.accounts.isEmpty && zero.overflowCount == 2 && zero.state == WidgetDisplayState.empty,
           "Zero visible accounts is empty with overflow count")

    let timeline = WidgetRefreshRules.nextRefreshDate(
        WidgetSnapshot(generatedAt: widgetClock, accounts: [
            widgetAccount(metrics: [widgetMetric("codex.primary.604800", remaining: 1,
                                      resetAt: widgetClock.addingTimeInterval(50))])
        ]), at: widgetClock)
    widgetExpect(timeline == widgetClock.addingTimeInterval(50), "Timeline picks the earliest reset")
    widgetExpect(WidgetRefreshRules.nextRefreshDate(nil, at: widgetClock) == nil,
           "No snapshot has no timeline hint")
}

func testWidgetCredentialRecord() throws {
    widgetExpect(WidgetCredentialStore.service == "com.wm0104.quotawatch.widget-credentials",
           "Separate Keychain service")
    widgetExpect(WidgetCredentialStore.service != "com.wm0104.quotawatch",
           "Widget credentials never use the app vault service")

    let token = "header.payload.signature"
    let record = WidgetCredentialRecord(
        provider: "codex", apiKey: "must-not-be-copied", accessToken: token,
        refreshToken: "refresh-token-value", accountID: "acct-123",
        identity: "测试 🐈", expiresAt: widgetClock.addingTimeInterval(3600))
    guard let clean = record.validated() else { fatalError("Valid credential rejected") }
    widgetExpect(clean.apiKey == nil, "Irrelevant provider secret is stripped")
    widgetExpect(clean.accessToken == token && clean.refreshToken == "refresh-token-value",
           "Codex tokens are preserved")
    widgetExpect(clean.accountID == "acct-123" && clean.identity == "测试 🐈",
           "Credential metadata is preserved")
    let encoded = try clean.encoded()
    let text = String(decoding: encoded, as: UTF8.self)
    widgetExpect(!text.contains("must-not-be-copied"), "Dropped secret is absent from payload")
    widgetExpect(WidgetCredentialRecord.decode(encoded) == clean, "Credential Codable round-trip")

    widgetExpect(WidgetCredentialRecord(provider: "codex", apiKey: "sk-1234567890").validated() == nil,
           "Codex requires an access token")
    widgetExpect(WidgetCredentialRecord(provider: "codex", accessToken: "bad token").validated() == nil,
           "Codex token must be header-safe")
    widgetExpect(WidgetCredentialRecord(provider: "codex", accessToken: token,
                                  accountID: "bad\nid").validated() == nil,
           "Remote account ID must be header-safe")
    widgetExpect(WidgetCredentialRecord(provider: "codex", accessToken: token,
                                  expiresAt: Date(timeIntervalSince1970: 5_000_000_000))
            .validated() == nil, "Out-of-range expiry is rejected")

    widgetExpect(WidgetCredentialRecord(provider: "deepseek", apiKey: "sk-1234567890").validated() != nil,
           "DeepSeek API key is accepted")
    widgetExpect(WidgetCredentialRecord(provider: "deepseek", apiKey: "short").validated() == nil,
           "Short DeepSeek key is rejected")
    widgetExpect(WidgetCredentialRecord(provider: "deepseek", apiKey: "has space").validated() == nil,
           "DeepSeek key must not contain whitespace")
    widgetExpect(WidgetCredentialRecord(provider: "deepseek", accessToken: token).validated() == nil,
           "DeepSeek does not accept an OAuth access token")
    widgetExpect(WidgetCredentialRecord(provider: "DeepSeek", apiKey: "sk-1234567890").validated() == nil,
           "Provider raw strings are exact")

    widgetExpect(WidgetCredentialRecord.decode(Data()) == nil, "Empty credential payload is invalid")
    widgetExpect(WidgetCredentialRecord.decode(Data("{}".utf8)) == nil, "Corrupt credential is invalid")
    widgetExpect(WidgetCredentialRecord.decode(Data("not json".utf8)) == nil,
           "Garbage credential is invalid")

    let snapshot = WidgetSnapshot(generatedAt: widgetClock, accounts: [widgetAccount()])
    let snapshotText = String(decoding: try snapshot.jsonData(), as: UTF8.self)
    widgetExpect(!snapshotText.contains(token) && !snapshotText.contains("refresh-token-value"),
           "Credentials never enter the widget snapshot")
}

func testWidgetCredentialAllowedAccountAPI() {
    let id = UUID()
    #if !os(iOS)
    do {
        _ = try WidgetCredentialStore.load(accountID: id, provider: "codex")
        widgetExpect(false, "Keychain is unavailable off iOS in tests")
    } catch {
        widgetExpect(true, "Off-iOS Keychain access fails closed")
    }
    do {
        _ = try WidgetCredentialStore.load(accountID: id, provider: "codex",
                                           allowedAccountIDs: [])
        widgetExpect(false, "Disallowed account must be rejected before Keychain")
    } catch let error as WidgetCredentialError {
        guard case .accountNotAllowed = error else {
            fatalError("Expected accountNotAllowed")
        }
        widgetExpect(true, "Disallowed account is rejected")
    } catch {
        fatalError("Unexpected disallowed-account error")
    }
    #endif
}

func widgetRun(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("PASS \(name)")
    } catch {
        fatalError("FAIL \(name): \(error)")
    }
}

widgetRun("sanitize and bounds", testWidgetSanitizeAndBounds)
widgetRun("JSON and corruption", testWidgetJSONAndCorruption)
widgetRun("store", testWidgetStore)
widgetRun("provider/window/currency separation", testWidgetProviderWindowCurrencySeparation)
widgetRun("stale and reset rules", testWidgetStaleAndResetRules)
widgetRun("display state and selection", testWidgetDisplayStateAndSelection)
widgetRun("credential record", testWidgetCredentialRecord)
widgetRun("credential allowed-account API", testWidgetCredentialAllowedAccountAPI)
print("widget shared checks passed: \(widgetChecks)")
