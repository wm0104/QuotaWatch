import SwiftUI

struct AccountDetailView: View {
    @ObservedObject var store: AccountStore
    let id: UUID
    @State private var editAccount = false
    @State private var editingRule: QuotaMetric?
    @State private var alias = ""
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let account = store.account(id) {
                ScrollView {
                    VStack(spacing: 18) {
                        if let snapshot = account.snapshot {
                            DetailMetricsCard(account: account, snapshot: snapshot) { editingRule = $0 }
                        } else {
                            DetailEmptyCard(account: account)
                        }
                        DetailRefreshControl(store: store, account: account)
                        DetailStatusFooter(account: account)
                        if account.kind == .codex {
                            CreditsDetailSection(account: account) { editingRule = $0 }
                        }
                        DetailAccountCard(store: store, id: id, account: account, alias: $alias)
                        DetailActionsCard(account: account, editAccount: $editAccount)
                        Button(role: .destructive) { deleting = true } label: {
                            Text("删除本机账户")
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("删除只清理本机凭据和数据，不会注销远端账号。")
                            .font(.footnote).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(account.alias)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { alias = account.alias }
                .sheet(isPresented: $editAccount) { AccountEditor(store: store, replacing: id) }
                .sheet(item: $editingRule) { metric in
                    RuleEditor(store: store, accountID: id, metric: metric)
                }
                .confirmationDialog("删除账户和本机凭据？不会注销远端账号。", isPresented: $deleting,
                                    titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        do { try store.delete(id); dismiss() }
                        catch { store.message = store.safeMessage(error) }
                    }
                }
            } else {
                Text("账户已删除").foregroundColor(.secondary)
            }
        }
    }
}

private struct DetailMetricsCard: View {
    let account: Account
    let snapshot: QuotaSnapshot
    let editRule: (QuotaMetric) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let metrics = QuotaDisplayRules.overviewMetrics(snapshot)
            VStack(spacing: 0) {
                if metrics.isEmpty {
                    Text("服务未返回可展示的订阅窗口或余额。")
                        .font(.subheadline).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(metrics) { metric in
                        DetailMetricRow(account: account, metric: metric, now: context.date,
                                        editRule: { editRule(metric) })
                        if metric.id != metrics.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct DetailMetricRow: View {
    let account: Account
    let metric: QuotaMetric
    let now: Date
    let editRule: () -> Void

    private var fresh: Bool { QuotaDisplayRules.isFresh(metric, account: account, now: now) }
    private var low: Bool { QuotaDisplayRules.isLow(metric, account: account, now: now) }
    private var rule: AlertRule? {
        account.rules.first { $0.metricID == metric.id && $0.enabled }
    }
    private var ruleSuffix: String {
        switch metric.unit {
        case .percent: return "%"
        case .cny: return " 元"
        case .usd: return " USD"
        case .credits: return " credits"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(QuotaDisplayRules.title(metric))
                        .font(.headline)
                    if let reset = metric.resetAt {
                        Label("重置 \(DateDisplay.stamp(reset))", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(MetricPresentation.value(metric))
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundColor(low ? .orange : (fresh ? .primary : .secondary))
                    .fixedSize()
            }
            if metric.unit == .percent, let remaining = metric.remaining {
                DetailProgressBar(fraction: NSDecimalNumber(decimal: remaining).doubleValue / 100,
                                  low: low, fresh: fresh)
                    .accessibilityLabel("剩余比例")
                    .accessibilityValue(MetricPresentation.value(metric))
            }
            if metric.granted != nil || metric.toppedUp != nil {
                HStack(spacing: 12) {
                    if let granted = metric.granted {
                        Text("赠金 \(MetricPresentation.number(granted))")
                    }
                    if let toppedUp = metric.toppedUp {
                        Text("充值 \(MetricPresentation.number(toppedUp))")
                    }
                }
                .font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                if low {
                    Label("低于提醒阈值", systemImage: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                } else if !fresh {
                    Label("待刷新", systemImage: "clock")
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if !metric.unlimited {
                    Button(action: editRule) {
                        Label(rule.map { "≤ \(MetricPresentation.number($0.threshold))\(ruleSuffix)" } ?? "设置提醒",
                              systemImage: rule == nil ? "bell" : "bell.fill")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct DetailProgressBar: View {
    let fraction: Double
    let low: Bool
    let fresh: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .tertiarySystemFill))
                Capsule()
                    .fill(low ? Color.orange : (fresh ? Color.accentColor : Color.secondary))
                    .frame(width: CGFloat(max(0, min(1, fraction))) * geometry.size.width)
            }
        }
        .frame(height: 7)
        .animation(.easeInOut(duration: 0.25), value: fraction)
    }
}

private struct DetailEmptyCard: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("暂无额度数据").font(.headline)
            Text(account.requiresAuth
                 ? "需要重新登录或更换密钥后才能查询。"
                 : "点下方按钮刷新，或稍后由系统择机更新。")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DetailRefreshControl: View {
    @ObservedObject var store: AccountStore
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let busy = store.busy.contains(account.id)
            let cooling = account.nextAllowedAt.map { $0 > context.date } ?? false
            Button {
                Task { await store.refresh(account.id, forced: true) }
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(busy ? "正在刷新…" : "刷新额度")
                    Spacer()
                    if cooling, let until = account.nextAllowedAt {
                        Text("\(DateDisplay.time(until)) 后可查").font(.caption)
                    }
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy || cooling || account.requiresAuth)
            .opacity(account.requiresAuth ? 0.45 : 1)
        }
    }
}

private struct DetailStatusFooter: View {
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if let snapshot = account.snapshot {
                    HStack(spacing: 6) {
                        Image(systemName: QuotaDisplayRules.needsRefresh(account, now: context.date)
                              ? "exclamationmark.circle" : "clock")
                        Text("更新于 \(DateDisplay.stamp(snapshot.capturedAt))")
                    }
                    .font(.footnote)
                    .foregroundColor(QuotaDisplayRules.needsRefresh(account, now: context.date)
                                     ? .orange : .secondary)
                }
                if let error = account.error {
                    Text(error).font(.footnote).foregroundColor(.orange)
                }
                if let until = account.nextAllowedAt, until > context.date {
                    Text("下次允许查询：\(DateDisplay.stamp(until))")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if QuotaDisplayRules.needsRefresh(account, now: context.date) {
                    Text("旧数据仅供参考；过期或已到重置时间不代表额度已经恢复。")
                        .font(.footnote).foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

private struct CreditsDetailSection: View {
    let account: Account
    let editRule: (QuotaMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Credits").font(.headline)
                Spacer()
                Text("额外用量余额").font(.caption).foregroundColor(.secondary)
            }
            if let snapshot = account.snapshot {
                if snapshot.creditsAvailable == false {
                    Label("当前无可用 Credits", systemImage: "info.circle")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text("这只表示接口当前没有报告可用的额外用量余额；不代表 5 小时或其他订阅窗口已经用尽，也不能据此判断套餐不支持额外用量。")
                        .font(.caption).foregroundColor(.secondary)
                    if let metric = snapshot.metrics.first(where: { $0.unit == .credits }),
                       account.rules.contains(where: { $0.metricID == metric.id && $0.enabled }) {
                        Button("管理原 Credits 提醒规则") { editRule(metric) }
                            .font(.subheadline).frame(minHeight: 44)
                        Text("原规则已保留；服务未报告可用 Credits 时，不据此触发低额提醒。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                } else {
                    if let metric = snapshot.metrics.first(where: { $0.unit == .credits }) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("余额").font(.subheadline).foregroundColor(.secondary)
                            Spacer(minLength: 12)
                            Text(MetricPresentation.value(metric))
                                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        }
                        if metric.remaining == 0 && !metric.unlimited {
                            Text("Credits 余额为 0，不等于订阅额度为 0。订阅剩余情况请看上方各窗口。")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if !metric.unlimited {
                            Button {
                                editRule(metric)
                            } label: {
                                Label("设置 Credits 提醒", systemImage: "bell")
                                    .font(.subheadline).frame(minHeight: 44)
                            }
                            .buttonStyle(.plain).foregroundColor(.accentColor)
                        }
                    } else {
                        Text("Credits 余额未知").font(.subheadline).foregroundColor(.secondary)
                    }
                    if snapshot.creditsAvailable == nil {
                        Text("适用情况未知：本次数据没有提供可用标志；若有余额，仅展示服务端报告值，请以官方用量页为准。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text("这些信息对应最近一次查询，不代表实时余额。")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("暂无 Credits 数据，请先刷新账户。")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Text("Credits 是与订阅用量窗口不同的计费余额，部分套餐可购买额外用量；不是人民币、美元、token 数或剩余消息次数。")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DetailAccountCard: View {
    @ObservedObject var store: AccountStore
    let id: UUID
    let account: Account
    @Binding var alias: String

    private var changed: Bool {
        alias.trimmingCharacters(in: .whitespacesAndNewlines) != account.alias
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账户").font(.footnote.weight(.semibold))
                .foregroundColor(.secondary).textCase(.uppercase)
            VStack(spacing: 0) {
                DetailInfoRow(label: "平台", value: account.kind.name)
                if let identity = account.identity {
                    Divider().padding(.leading, 16)
                    DetailInfoRow(label: "登录身份", value: identity)
                }
                if let plan = account.snapshot?.plan {
                    Divider().padding(.leading, 16)
                    DetailInfoRow(label: "套餐", value: plan)
                }
                Divider().padding(.leading, 16)
                HStack(spacing: 10) {
                    Text("别名").font(.subheadline).foregroundColor(.secondary)
                    TextField("账户别名", text: $alias)
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                    if changed {
                        Button("保存") {
                            do { try store.rename(id, alias: alias) }
                            catch { store.message = store.safeMessage(error) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct DetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

private struct DetailActionsCard: View {
    let account: Account
    @Binding var editAccount: Bool

    private var officialURL: URL {
        URL(string: account.kind == .codex
            ? "https://chatgpt.com/codex/settings/usage"
            : "https://platform.deepseek.com/usage")!
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { editAccount = true } label: {
                DetailActionRow(icon: account.kind == .codex ? "person.badge.key" : "key",
                                title: account.kind == .codex ? "重新登录" : "更换 API Key",
                                subtitle: account.kind == .codex ? "重新授权此账户" : "更新本机保存的密钥")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            Link(destination: officialURL) {
                DetailActionRow(icon: "safari", title: "官方用量页面",
                                subtitle: "在浏览器核对服务端原始数据")
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DetailActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body).foregroundColor(.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundColor(.primary)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

enum DateDisplay {
    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
    private static let withYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func stamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + timeOnly.string(from: date) }
        if calendar.component(.year, from: date) != calendar.component(.year, from: Date()) {
            return withYear.string(from: date)
        }
        return full.string(from: date)
    }

    static func time(_ date: Date) -> String { timeOnly.string(from: date) }
}
