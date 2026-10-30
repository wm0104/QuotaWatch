import Foundation
import WidgetKit

// The widget gets a redacted snapshot for display and a separate, minimal credential copy for
// best-effort refresh. It never receives the app's account archive or refresh token.
enum WidgetBridge {
    static let kind = WidgetSnapshotLimits.widgetKind
    private static let maximumAccounts = WidgetSnapshotLimits.maximumAccounts

    static func publish(_ accounts: [Account]) {
        let generatedAt = Date()
        let selected = accounts.prefix(maximumAccounts)
        let items = selected.map { account -> WidgetAccountSnapshot in
            let metrics = (account.snapshot?.metrics ?? []).map { metric in
                WidgetMetricSnapshot(
                    id: metric.id, title: metric.title, unit: metric.unit.rawValue,
                    remaining: metric.remaining, resetAt: metric.resetAt,
                    unlimited: metric.unlimited, durationSeconds: metric.durationSeconds)
            }
            return WidgetAccountSnapshot(
                id: account.id, provider: account.kind.rawValue, displayAlias: account.alias,
                metrics: metrics, creditsAvailable: account.snapshot?.creditsAvailable,
                capturedAt: account.snapshot?.capturedAt ?? account.lastAttempt ?? generatedAt,
                lastError: account.error.flatMap { WidgetSnapshotSanitizer.errorText($0) })
        }
        let snapshot = WidgetSnapshot(generatedAt: generatedAt, accounts: Array(items))
        guard let store = try? WidgetSnapshotStore.appGroup() else { return }
        try? store.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
