import SwiftUI
import WidgetKit

struct ProbeEntry: TimelineEntry {
    let date: Date
    let readAt: Date
    let snapshot: ProbeSnapshot?
    let status: String
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        preview()
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(context.isPreview ? preview() : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let entry = read()
        let entries = ProbeTimeline.dates(snapshot: entry.snapshot, now: entry.date).map {
            ProbeEntry(date: $0, readAt: entry.readAt, snapshot: entry.snapshot, status: entry.status)
        }
        completion(Timeline(entries: entries, policy: .after(
            ProbeTimeline.nextReload(snapshot: entry.snapshot, now: entry.date))))
    }

    private func preview() -> ProbeEntry {
        let now = Date()
        return ProbeEntry(date: now, readAt: now, snapshot: .fake(revision: 1, now: now),
                          status: "图库预览 · 非共享容器读取")
    }

    private func read() -> ProbeEntry {
        let now = Date()
        do {
            let store = try ProbeStore.appGroup()
            var snapshot: ProbeSnapshot?
            var status: String
            var result: String
            do {
                snapshot = try store.readSnapshot()
                status = snapshot == nil ? "无测试快照；先打开 QuotaProbe 写入" : "共享文件缓存 · 无网络"
                result = snapshot == nil ? "missing" : "ok"
            } catch {
                status = "文件损坏 / 锁定 / 不可读：\(error.localizedDescription)"
                result = "error"
            }
            do {
                try store.writeDiagnostic(ProbeReadDiagnostic(schemaVersion: 1,
                    revision: snapshot?.revision, readAt: now, result: result))
            } catch { status += "；诊断写入失败：\(error.localizedDescription)" }
            return ProbeEntry(date: now, readAt: now, snapshot: snapshot, status: status)
        } catch {
            return ProbeEntry(date: now, readAt: now, snapshot: nil, status: error.localizedDescription)
        }
    }
}

private struct ProbeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProbeEntry
    private var large: Bool { family == .systemLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 8 : 3) {
            HStack {
                Text("TEST / 模拟").font(.system(size: large ? 26 : 20, weight: .black))
                    .foregroundColor(.orange)
                Spacer(minLength: 4)
                Text("QuotaProbe").font(.caption2.bold())
            }
            Text("\(entry.snapshot.map { "r\($0.revision)" } ?? "无版本") · 读取 \(clock(entry.readAt))")
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            if let snapshot = entry.snapshot {
                ForEach(Array(snapshot.accounts.prefix(large ? 3 : 2))) { account in
                    accountRow(account)
                }
                if !large {
                    Text("+1 模拟 DeepSeek 账户 · 大尺寸显示全部")
                        .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                }
                if ProbeTimeline.isStale(snapshot, at: entry.date) {
                    Text("已过期 · 需回 App 写入 · 数值未重置")
                        .font(.caption2.bold()).foregroundColor(.orange)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(entry.status).font(.system(size: large ? 11 : 9))
                    .foregroundColor(.secondary).lineLimit(large ? 3 : 1).minimumScaleFactor(0.75)
                if large {
                    Text("本地时间线只改变过期提示，不更新额度。\n点击打开测试 App；重载 / 系统重绘可能延迟。")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                Text(entry.status).font(.caption).foregroundColor(.orange)
                    .lineLimit(large ? 8 : 3).minimumScaleFactor(0.8)
                Text("点击打开独立 QuotaProbe · 无网络")
                    .font(.caption2)
                Spacer(minLength: 0)
            }
        }
        .padding(large ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .widgetURL(URL(string: "quotaprobe://open"))
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func accountRow(_ account: ProbeAccount) -> some View {
        VStack(alignment: .leading, spacing: large ? 4 : 1) {
            HStack {
                Text(account.id).font(large ? .caption.bold() : .system(size: 11, weight: .semibold))
                Spacer(minLength: 3)
                if let percent = account.remainingPercent {
                    Text("\(percent, specifier: "%.0f")% 剩余")
                }
                if let balance = account.balanceUSD {
                    Text("USD \(balance, specifier: "%.2f")")
                }
            }
            .font(large ? .headline : .system(size: 12, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.75)
            if let reset = account.expectedResetAt {
                Text(ProbeTimeline.resetPassed(account, at: entry.date)
                    ? "预计重置已过 · 需刷新，未恢复 100%"
                    : "预计重置 \(clock(reset)) · 非额度更新")
                    .font(.system(size: large ? 11 : 9))
                    .foregroundColor(ProbeTimeline.resetPassed(account, at: entry.date) ? .orange : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            } else if large {
                Text("模拟货币余额 · 无自动重置时间")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(large ? 8 : 0)
        .background(large ? Color.orange.opacity(0.08) : Color.clear)
        .cornerRadius(8)
    }
}

@main
struct QuotaProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ProbeIdentity.kind, provider: ProbeProvider()) { entry in
            ProbeWidgetView(entry: entry)
        }
        .configurationDisplayName("QuotaProbe · 模拟 TEST")
        .description("仅假数据 / 无网络。中尺寸 2+1，大尺寸全部三账户；不是真实余额组件。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
