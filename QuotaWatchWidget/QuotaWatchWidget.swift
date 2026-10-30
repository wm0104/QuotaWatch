import SwiftUI
import WidgetKit

struct QuotaWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let reason: String?
}

struct QuotaWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaWatchWidgetEntry {
        let now = Date()
        let preview = WidgetAccountSnapshot(
            provider: "codex", displayAlias: "示例账户",
            metrics: [
                WidgetMetricSnapshot(id: "codex.primary.18000", title: "Codex",
                                     unit: "percent", remaining: 72,
                                     resetAt: now.addingTimeInterval(3200),
                                     durationSeconds: 18000),
                WidgetMetricSnapshot(id: "codex.secondary.604800", title: "Codex",
                                     unit: "percent", remaining: 38,
                                     resetAt: now.addingTimeInterval(86400),
                                     durationSeconds: 604800)
            ],
            capturedAt: now)
        return QuotaWatchWidgetEntry(
            date: now,
            snapshot: WidgetSnapshot(generatedAt: now, accounts: [preview]),
            reason: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaWatchWidgetEntry) -> Void) {
        completion(cachedEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaWatchWidgetEntry>) -> Void) {
        let now = Date()
        let store = try? WidgetSnapshotStore.appGroup()
        let cached = store?.read()
        var snapshot = cached
        if let cached, let store {
            snapshot = refreshIfNeeded(cached, store: store, now: now)
        }
        let reason: String?
        if snapshot == nil {
            reason = store == nil ? "无法读取共享数据，请打开 QuotaWatch" : "打开 QuotaWatch 添加账户"
        } else if snapshot?.accounts.isEmpty == true {
            reason = "打开 QuotaWatch 添加账户"
        } else {
            reason = nil
        }
        let next = WidgetRefreshRules.nextRefreshDate(snapshot, at: now)
            ?? now.addingTimeInterval(900)
        var dates = [now]
        if next > now { dates.append(next) }
        let entries = dates.map {
            QuotaWatchWidgetEntry(date: $0, snapshot: snapshot, reason: reason)
        }
        completion(Timeline(entries: entries,
                            policy: .after(max(next, now.addingTimeInterval(60)))))
    }

    private func cachedEntry() -> QuotaWatchWidgetEntry {
        let now = Date()
        let store = try? WidgetSnapshotStore.appGroup()
        let snapshot = store?.read()
        let reason: String?
        if snapshot == nil {
            reason = store == nil ? "无法读取共享数据，请打开 QuotaWatch" : "打开 QuotaWatch 添加账户"
        } else if snapshot?.accounts.isEmpty == true {
            reason = "打开 QuotaWatch 添加账户"
        } else {
            reason = nil
        }
        return QuotaWatchWidgetEntry(date: now, snapshot: snapshot, reason: reason)
    }

    private func refreshIfNeeded(_ snapshot: WidgetSnapshot,
                                 store: WidgetSnapshotStore,
                                 now: Date) -> WidgetSnapshot {
        let candidates = snapshot.accounts.filter {
            WidgetRefreshRules.needsRefresh($0, at: now)
        }
        guard !candidates.isEmpty else { return snapshot }
        let allowed = Set(snapshot.accounts.map(\.id))
        let jobs: [(UUID, ProviderKind, WidgetCredentialRecord)] = candidates.compactMap { account in
            guard let kind = ProviderKind(rawValue: account.provider),
                  let record = try? WidgetCredentialStore.load(
                    accountID: account.id, provider: account.provider,
                    allowedAccountIDs: allowed) else { return nil }
            if kind == .codex, let expiresAt = record.expiresAt,
               expiresAt.timeIntervalSince(now) < 60 { return nil }
            return (account.id, kind, record)
        }
        guard !jobs.isEmpty else { return snapshot }

        let box = ReplacementBox()
        let finished = DispatchSemaphore(value: 0)
        let work = Task {
            await withTaskGroup(of: WidgetFetchResult.self) { group in
                for (id, kind, record) in jobs {
                    group.addTask {
                        WidgetFetchResult(
                            id: id,
                            quota: try? await WidgetQuotaClient.fetch(
                                kind: kind, credential: record, now: now))
                    }
                }
                for await result in group {
                    if let quota = result.quota {
                        box.set(quota, for: result.id)
                    }
                }
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + 18) == .timedOut {
            work.cancel()
            return snapshot
        }

        let accounts = snapshot.accounts.map { account -> WidgetAccountSnapshot in
            guard let quota = box.quota(for: account.id) else { return account }
            return WidgetAccountSnapshot(
                id: account.id, provider: account.provider,
                displayAlias: account.displayAlias,
                metrics: quota.metrics.map { metric in
                    WidgetMetricSnapshot(
                        id: metric.id, title: metric.title, unit: metric.unit.rawValue,
                        remaining: metric.remaining, resetAt: metric.resetAt,
                        unlimited: metric.unlimited, durationSeconds: metric.durationSeconds)
                },
                creditsAvailable: quota.creditsAvailable,
                capturedAt: quota.capturedAt,
                lastError: nil)
        }
        let updated = WidgetSnapshot(generatedAt: now, accounts: accounts)
        try? store.write(updated)
        return updated
    }
}

private final class WidgetFetchResult: @unchecked Sendable {
    let id: UUID
    let quota: QuotaSnapshot?

    init(id: UUID, quota: QuotaSnapshot?) {
        self.id = id
        self.quota = quota
    }
}

private final class ReplacementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: QuotaSnapshot] = [:]

    func set(_ value: QuotaSnapshot, for id: UUID) {
        lock.lock()
        values[id] = value
        lock.unlock()
    }

    func quota(for id: UUID) -> QuotaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }
}

private struct QuotaWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWatchWidgetEntry

    private var small: Bool { family == .systemSmall }
    private var large: Bool { family == .systemLarge }
    private var accountLimit: Int { small ? 1 : (large ? 5 : 2) }
    private var metricLimit: Int { small ? 1 : 2 }

    var body: some View {
        let summary = WidgetRefreshRules.displaySummary(
            entry.snapshot, limit: accountLimit, at: entry.date)
        VStack(alignment: .leading, spacing: small ? 4 : 7) {
            header(summary)
            if summary.accounts.isEmpty {
                Text(entry.reason ?? "打开 QuotaWatch 添加账户")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(summary.accounts) { account in
                    accountView(account, now: entry.date)
                    if account.id != summary.accounts.last?.id {
                        Divider()
                    }
                }
                if summary.overflowCount > 0 {
                    Text("还有 \(summary.overflowCount) 个账户")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(small ? 9 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }

    private func header(_ summary: WidgetDisplaySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("QuotaWatch").font(small ? .subheadline.bold() : .headline)
            Spacer(minLength: 4)
            if summary.needsRefresh {
                Text("待刷新")
                    .font(.caption2.weight(.semibold)).foregroundColor(.orange)
            } else if let snapshot = entry.snapshot {
                Text("更新 \(WidgetClock.time(snapshot.generatedAt))")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func accountView(_ account: WidgetAccountSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: small ? 2 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(account.displayAlias)
                    .font(small ? .caption.bold() : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(providerName(account.provider))
                    .font(.caption2).foregroundColor(.secondary)
            }
            let metrics = Array(WidgetRefreshRules.summaryMetrics(
                account, at: now, limit: WidgetSnapshotLimits.maximumMetricsPerAccount)
                .filter { $0.metric.unit != "credits" }
                .prefix(metricLimit))
            if metrics.isEmpty {
                Text("暂无订阅额度").font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(metrics) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metricTitle(item.metric, at: now))
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(metricValue(item.metric))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            if account.lastError?.isEmpty == false {
                Text("需打开 App 更新")
                    .font(.caption2).foregroundColor(.orange).lineLimit(1)
            }
        }
    }

    private func providerName(_ provider: String) -> String {
        provider == "codex" ? "Codex" : (provider == "deepseek" ? "DeepSeek" : "账户")
    }

    private func metricTitle(_ metric: WidgetMetricSnapshot, at now: Date) -> String {
        var base: String
        if metric.unit == "percent" {
            base = durationTitle(metric.durationSeconds)
                ?? codexDurationFromID(metric.id)
                ?? metric.title
            if base.isEmpty { base = "额度" }
        } else if metric.unit == "cny" {
            base = "CNY"
        } else if metric.unit == "usd" {
            base = "USD"
        } else if metric.unit == "credits" {
            base = "Credits"
        } else {
            base = metric.title
        }
        if let resetAt = metric.resetAt {
            let suffix = resetAt <= now ? "待刷新" : WidgetClock.time(resetAt)
            return base + " · " + suffix
        }
        return base
    }

    private func durationTitle(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds % 86400 == 0 { return "\(seconds / 86400)天" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)小时" }
        if seconds % 60 == 0 { return "\(seconds / 60)分钟" }
        return "\(seconds)秒"
    }

    private func codexDurationFromID(_ id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.first == "codex", parts.count >= 3,
              parts[1] == "primary" || parts[1] == "secondary",
              let seconds = Int(parts.last ?? "") else { return nil }
        return durationTitle(seconds)
    }

    private func metricValue(_ metric: WidgetMetricSnapshot) -> String {
        if metric.unlimited { return "不限" }
        guard let remaining = metric.remaining else { return "—" }
        switch metric.unit {
        case "percent":
            return "\(WidgetNumber.text(remaining, fractionDigits: 0))%"
        case "cny":
            return "¥\(WidgetNumber.text(remaining, fractionDigits: 2))"
        case "usd":
            return "$\(WidgetNumber.text(remaining, fractionDigits: 2))"
        case "credits":
            return WidgetNumber.text(remaining, fractionDigits: 2)
        default:
            return WidgetNumber.text(remaining, fractionDigits: 2)
        }
    }
}

private enum WidgetNumber {
    static func text(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
}

private enum WidgetClock {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ date: Date) -> String { formatter.string(from: date) }
}

@main
struct QuotaWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotLimits.widgetKind,
                            provider: QuotaWatchWidgetProvider()) { entry in
            QuotaWatchWidgetView(entry: entry)
        }
        .configurationDisplayName("QuotaWatch")
        .description("多账户额度和预计重置时间，显示最近查询结果；刷新时间由 iOS 调度。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
