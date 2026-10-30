import Foundation

enum ProbeTimeline {
    static func isStale(_ snapshot: ProbeSnapshot, at date: Date) -> Bool {
        date >= snapshot.staleAt
    }

    static func resetPassed(_ account: ProbeAccount, at date: Date) -> Bool {
        account.expectedResetAt.map { date >= $0 } ?? false
    }

    static func dates(snapshot: ProbeSnapshot?, now: Date) -> [Date] {
        guard let snapshot = snapshot else { return [now] }
        let boundaries = snapshot.accounts.compactMap(\.expectedResetAt) + [snapshot.staleAt]
        return [now] + Array(Set(boundaries.filter { $0 > now })).sorted()
    }

    static func nextReload(snapshot: ProbeSnapshot?, now: Date) -> Date {
        guard let snapshot = snapshot, snapshot.staleAt > now else {
            return now.addingTimeInterval(900)
        }
        return snapshot.staleAt.addingTimeInterval(60)
    }
}
