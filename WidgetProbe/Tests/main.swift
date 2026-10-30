import Foundation

// Inline fixture keeps this executable independent of working directory and resources.
let fixture = Data("""
{"schemaVersion":1,"isFake":true,"revision":7,"writtenAt":1700000000000,"staleAt":1700000600000,
 "accounts":[
 {"id":"FAKE-CODEX-A","provider":"codex","remainingPercent":65,"expectedResetAt":1700000120000},
 {"id":"FAKE-CODEX-B","provider":"codex","remainingPercent":38,"expectedResetAt":1700000240000},
 {"id":"FAKE-DEEPSEEK-C","provider":"deepseek","balanceUSD":14.59}]}
""".utf8)

var assertions = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !condition() { fatalError("FAIL: \(message)") }
}
func rejects(_ message: String, _ action: () throws -> Void) {
    assertions += 1
    do { try action() } catch { return }
    fatalError("FAIL: expected error: \(message)")
}
func mutated(_ change: (inout [String: Any]) -> Void) throws -> ProbeSnapshot {
    var object = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
    change(&object)
    let data = try JSONSerialization.data(withJSONObject: object)
    return try ProbeCodec.decode(ProbeSnapshot.self, from: data).validated()
}

do {
    let snapshot = try ProbeCodec.decode(ProbeSnapshot.self, from: fixture).validated()
    try check(snapshot.revision == 7 && snapshot.accounts.count == 3, "fixture revision and count")
    let roundTrip = try ProbeCodec.decode(ProbeSnapshot.self, from: ProbeCodec.encode(snapshot)).validated()
    try check(roundTrip.revision == snapshot.revision && roundTrip.writtenAt == snapshot.writtenAt,
              "versioned JSON round trip")
    rejects("schema") { _ = try mutated { $0["schemaVersion"] = 2 } }
    rejects("fake marker") { _ = try mutated { $0["isFake"] = false } }
    rejects("revision zero") { _ = try mutated { $0["revision"] = 0 } }
    rejects("revision upper bound") { _ = try mutated { $0["revision"] = ProbeIdentity.maximumRevision + 1 } }
    rejects("stale timestamp") { _ = try mutated { $0["staleAt"] = 1699999999000 } }
    rejects("percent > 100") {
        _ = try mutated {
            var accounts = $0["accounts"] as! [[String: Any]]
            accounts[0]["remainingPercent"] = 101
            $0["accounts"] = accounts
        }
    }
    rejects("negative USD") {
        _ = try mutated {
            var accounts = $0["accounts"] as! [[String: Any]]
            accounts[2]["balanceUSD"] = -1
            $0["accounts"] = accounts
        }
    }
    rejects("unexpected identity") {
        _ = try mutated {
            var accounts = $0["accounts"] as! [[String: Any]]
            accounts[0]["id"] = "NOT-FAKE"
            $0["accounts"] = accounts
        }
    }
    rejects("truncated JSON") {
        _ = try ProbeCodec.decode(ProbeSnapshot.self, from: Data(fixture.prefix(20)))
    }
    for revision in [1, 2, 19, 20, ProbeIdentity.maximumRevision] {
        _ = try ProbeSnapshot.fake(revision: revision, now: snapshot.writtenAt).validated()
    }
    try check(ProbeSnapshot.fake(revision: 1, now: snapshot.writtenAt).accounts[0].remainingPercent !=
              ProbeSnapshot.fake(revision: 2, now: snapshot.writtenAt).accounts[0].remainingPercent,
              "next revision has distinct fake numbers")
    let reset = snapshot.accounts[0].expectedResetAt!
    try check(!ProbeTimeline.resetPassed(snapshot.accounts[0], at: reset.addingTimeInterval(-1)), "before reset")
    try check(ProbeTimeline.resetPassed(snapshot.accounts[0], at: reset), "expected reset boundary passed")
    try check(snapshot.accounts[0].remainingPercent == 65, "reset must never synthesize 100 percent")
    try check(!ProbeTimeline.isStale(snapshot, at: snapshot.staleAt.addingTimeInterval(-1)), "before stale")
    try check(ProbeTimeline.isStale(snapshot, at: snapshot.staleAt), "stale boundary")
    let dates = ProbeTimeline.dates(snapshot: snapshot, now: snapshot.writtenAt)
    try check(dates == [snapshot.writtenAt, reset, snapshot.accounts[1].expectedResetAt!, snapshot.staleAt],
              "local reset and stale timeline boundaries")
    let expiredNow = snapshot.staleAt.addingTimeInterval(1)
    try check(ProbeTimeline.dates(snapshot: snapshot, now: expiredNow) == [expiredNow], "no past timeline entries")
    try check(ProbeTimeline.nextReload(snapshot: snapshot, now: expiredNow) > expiredNow, "future stale retry")
    try check(ProbeTimeline.dates(snapshot: nil, now: expiredNow) == [expiredNow], "missing file timeline")

    // Never calls appGroup(); only explicit temporary URLs reach storage tests.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProbeStore(directoryURL: directory)
    try check(try store.readSnapshot() == nil, "missing is not corruption")
    try store.writeSnapshot(snapshot)
    try check(try store.readSnapshot()?.revision == 7, "atomic write and validated read")
    try store.writeSnapshot(.fake(revision: 8, now: snapshot.writtenAt))
    try check(try store.readSnapshot()?.revision == 8, "atomic replacement")
    rejects("invalid write leaves previous valid file") {
        try store.writeSnapshot(.fake(revision: 0, now: snapshot.writtenAt))
    }
    try check(try store.readSnapshot()?.revision == 8, "failed validation preserves old revision")
    let diagnostic = ProbeReadDiagnostic(schemaVersion: 1, revision: 8, readAt: reset, result: "ok")
    try store.writeDiagnostic(diagnostic)
    try check(try store.readDiagnostic()?.revision == 8, "separate diagnostic JSON")
    rejects("diagnostic cannot claim ok without revision") {
        try store.writeDiagnostic(ProbeReadDiagnostic(schemaVersion: 1, revision: nil, readAt: reset, result: "ok"))
    }
    let sentinel = directory.appendingPathComponent("unrelated-test-file")
    try Data("leave me".utf8).write(to: sentinel)
    try store.removeSnapshot()
    try store.removeSnapshot()
    try check(try store.readSnapshot() == nil, "idempotent snapshot removal")
    try check(try store.readDiagnostic()?.revision == 8, "removal preserves diagnostic")
    try check(try Data(contentsOf: sentinel) == Data("leave me".utf8), "removal touches only snapshot")
    try Data("broken".utf8).write(to: directory.appendingPathComponent(ProbeIdentity.snapshotFile))
    rejects("disk corruption surfaces") { _ = try store.readSnapshot() }
    let missingDirectory = ProbeStore(directoryURL: directory.appendingPathComponent("not-created"))
    rejects("no fallback directory on failed write") { try missingDirectory.writeSnapshot(snapshot) }
    print("PASS: \(assertions) WidgetProbe assertions (synthetic Foundation tests only)")
} catch {
    fatalError("FAIL: unexpected error: \(error)")
}
