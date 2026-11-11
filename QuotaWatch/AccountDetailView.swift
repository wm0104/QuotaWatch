import SwiftUI
import UIKit

struct AccountDetailView: View {
    @ObservedObject var store: AccountStore
    let id: UUID
    @State private var editAccount = false
    @State private var editingRule: QuotaMetric?
    @State private var alias = ""
    @State private var renaming = false
    @State private var deleting = false
    @State private var quotaExpanded = false
    @State private var creditsExpanded = false
    @State private var accountExpanded = false
    @State private var creditsInfo = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var route = NotificationRoute.shared

    var body: some View {
        Group {
            if let account = store.account(id) {
                ScrollView {
                    VStack(spacing: 10) {
                        if let snapshot = account.snapshot {
                            DetailMetricsCard(account: account, snapshot: snapshot)
                        } else { DetailEmptyCard(account: account) }
                        DetailRefreshControl(store: store, account: account)
                        DetailStatusFooter(account: account)
                        ResetNotificationStatus(notifications: store.notifications)
                        DisclosureGroup("额度详情", isExpanded: $quotaExpanded) {
                            if let snapshot = account.snapshot {
                                ForEach(QuotaDisplayRules.overviewMetrics(snapshot)) { metric in
                                    DetailMetricRow(account: account, metric: metric,
                                                    editRule: { editingRule = metric })
                                }
                            } else { Text("暂无额度数据").foregroundColor(.secondary) }
                        }.detailDisclosureStyle()
                        if account.kind == .codex {
                            DisclosureGroup(isExpanded: $creditsExpanded) {
                                CreditsDetailSection(account: account) { editingRule = $0 }
                                Button("关于 Credits") { creditsInfo = true }.frame(minHeight: 44)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Credits")
                                    Text(creditsSummary(account)).font(.caption).foregroundColor(.secondary)
                                }
                            }.detailDisclosureStyle()
                        }
                        DisclosureGroup("账户信息", isExpanded: $accountExpanded) {
                            DetailAccountCard(store: store, id: id, account: account, alias: $alias)
                        }.detailDisclosureStyle()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(account.alias).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NativeMenuButton(accessibilityLabel: "账户更多操作") { accountMenu(account) }
                            .frame(width: 44, height: 44)
                    }
                }
                .onAppear { alias = account.alias }
                .sheet(isPresented: $editAccount) { AccountEditor(store: store, replacing: id) }
                .sheet(item: $editingRule) { metric in RuleEditor(store: store, accountID: id, metric: metric) }
                .sheet(isPresented: $creditsInfo) { CreditsInfoSheet() }
                .alert("修改别名", isPresented: $renaming) {
                    TextField("账户别名", text: $alias)
                    Button("保存") {
                        do { try store.rename(id, alias: alias) }
                        catch { store.message = store.safeMessage(error) }
                    }
                    Button("取消", role: .cancel) { }
                }
                .confirmationDialog("删除账户和本机凭据？不会注销远端账号。", isPresented: $deleting,
                                    titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        do { try store.delete(id); dismiss() }
                        catch { store.message = store.safeMessage(error) }
                    }
                }
            } else { Text("账户已删除").foregroundColor(.secondary) }
        }
        .task(id: route.pending?.id) {
            guard route.pending != nil, await route.waitForActivation(store: store) else { return }
            editAccount = false; editingRule = nil; creditsInfo = false
            renaming = false; deleting = false
        }
    }

    private func creditsSummary(_ account: Account) -> String {
        guard let snapshot = account.snapshot else { return "暂无数据" }
        if snapshot.creditsAvailable == false { return "当前无可用 Credits" }
        let value = snapshot.metrics.first { $0.unit == .credits }.map(MetricPresentation.value) ?? "余额未知"
        return snapshot.creditsAvailable == nil ? "\(value) · 适用情况未知" : value
    }

    private func accountMenu(_ account: Account) -> UIMenu {
        let windowMenus: [UIMenu] = (account.snapshot?.metrics ?? []).map { metric in
            var actions: [UIMenuElement] = []
            if account.kind == .codex && metric.unit == .percent && !metric.unlimited {
                let enabled = account.resetAlerts?.contains(metric.id) == true
                actions.append(UIAction(title: "重置提醒", image: UIImage(systemName: "bell.badge"),
                                        state: enabled ? .on : .off) { _ in
                    Task {
                        do { try await store.setResetAlert(id, metricID: metric.id, enabled: !enabled) }
                        catch { store.message = store.safeMessage(error) }
                    }
                })
            }
            if !metric.unlimited || account.rules.contains(where: { $0.metricID == metric.id }) {
                actions.append(UIAction(title: "设置低额提醒", image: UIImage(systemName: "bell")) { _ in editingRule = metric })
            }
            return UIMenu(title: QuotaDisplayRules.title(metric), children: actions)
        }.filter { !$0.children.isEmpty }
        var reminderMenus: [UIMenuElement] = windowMenus
        let currentResetIDs = Set((account.snapshot?.metrics ?? []).filter { $0.unit == .percent && !$0.unlimited }.map(\.id))
        for metricID in (account.resetAlerts ?? []).subtracting(currentResetIDs).sorted() {
            reminderMenus.append(UIMenu(title: metricID, children: [
                UIAction(title: "重置提醒", state: .on) { _ in
                    Task {
                        do { try await store.setResetAlert(id, metricID: metricID, enabled: false) }
                        catch { store.message = store.safeMessage(error) }
                    }
                }
            ]))
        }
        // Old rules remain manageable even if the service no longer returns their metric.
        let currentIDs = Set((account.snapshot?.metrics ?? []).map(\.id))
        for rule in account.rules where !currentIDs.contains(rule.metricID) {
            reminderMenus.append(UIMenu(title: rule.metricID, children: [
                UIAction(title: "关闭旧低额提醒", state: rule.enabled ? .on : .off) { _ in
                    do { try store.removeMissingRule(id, metricID: rule.metricID) }
                    catch { store.message = store.safeMessage(error) }
                }
            ]))
        }
        let refresh = UIAction(title: "刷新额度", image: UIImage(systemName: "arrow.clockwise"),
                               attributes: store.busy.contains(id) || account.requiresAuth ? .disabled : []) { _ in
            Task { await store.refresh(account.id, forced: true) }
        }
        let management = UIMenu(title: "账户管理", children: [
            UIAction(title: "修改别名", image: UIImage(systemName: "pencil")) { _ in alias = account.alias; renaming = true },
            UIAction(title: account.kind == .codex ? "重新登录" : "更换 API Key", image: UIImage(systemName: "key")) { _ in editAccount = true },
            UIAction(title: "删除账户", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in deleting = true }
        ])
        var children: [UIMenuElement] = [refresh]
        if !reminderMenus.isEmpty { children.append(UIMenu(title: "提醒设置", children: reminderMenus)) }
        children.append(management)
        children.append(UIAction(title: "官方用量页", image: UIImage(systemName: "safari")) { _ in
            openURL(URL(string: account.kind == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://platform.deepseek.com/usage")!)
        })
        return UIMenu(children: children)
    }
}

private extension View {
    func detailDisclosureStyle() -> some View {
        self.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ResetNotificationStatus: View {
    @ObservedObject var notifications: NotificationService
    var body: some View {
        if let issue = notifications.resetIssue {
            Text(issue).font(.caption).foregroundColor(.orange).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailMetricsCard: View {
    let account: Account
    let snapshot: QuotaSnapshot
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let metrics = QuotaDisplayRules.overviewMetrics(snapshot)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                        count: QuotaDisplayRules.detailColumnCount(metricCount: metrics.count,
                                                                  accessibility: typeSize.isAccessibilitySize)),
                      alignment: .leading, spacing: 12) {
                ForEach(metrics) { metric in
                    let fresh = QuotaDisplayRules.isFresh(metric, account: account, now: context.date)
                    let low = QuotaDisplayRules.isLow(metric, account: account, now: context.date)
                    VStack(alignment: .leading, spacing: 5) {
                        MetricValueRow(metric: metric, emphasized: fresh, detail: true, low: low, showsStatus: false)
                        Text(QuotaDisplayRules.resetText(metric, now: context.date))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if low { Text("达到提醒阈值").font(.caption).foregroundColor(.orange) }
                        if !fresh { Text("待刷新").font(.caption).foregroundColor(.orange) }
                    }.accessibilityElement(children: .combine)
                }
                if metrics.isEmpty { Text("服务未返回可展示的订阅窗口或余额。").font(.subheadline).foregroundColor(.secondary) }
            }
            .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct DetailMetricRow: View {
    let account: Account
    let metric: QuotaMetric
    let editRule: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(QuotaDisplayRules.title(metric)).font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(QuotaDisplayRules.resetText(metric, now: context.date)).font(.caption).foregroundColor(.secondary)
            }
            if account.kind == .codex && metric.unit == .percent {
                Text(account.resetAlerts?.contains(metric.id) == true ? "重置提醒：已开启（需系统通知权限及未来时间）" : "重置提醒：关闭")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let rule = account.rules.first(where: { $0.metricID == metric.id && $0.enabled }) {
                Text("低额提醒：≤ \(MetricPresentation.number(rule.threshold)) \(metric.unit.rawValue)")
                    .font(.caption).foregroundColor(.secondary)
            } else { Text("低额提醒：关闭").font(.caption).foregroundColor(.secondary) }
            if let granted = metric.granted { Text("赠金 \(MetricPresentation.number(granted))").font(.caption) }
            if let toppedUp = metric.toppedUp { Text("充值 \(MetricPresentation.number(toppedUp))").font(.caption) }
            if !metric.unlimited {
                Button("设置低额提醒", action: editRule).font(.subheadline).frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.snapshot.map { "更新于 " + DateDisplay.short($0.capturedAt) } ?? "尚未更新")
                    .font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button {
                    Task { await store.refresh(account.id, forced: true) }
                } label: {
                    Label(busy ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
                        .font(.subheadline).frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundColor(.accentColor)
                .disabled(busy || cooling || account.requiresAuth)
            }
        }
    }
}

private struct DetailStatusFooter: View {
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if account.requiresAuth {
                    Label("认证已失效，请重新登录或更换密钥。", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote).foregroundColor(.orange)
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
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

private struct CreditsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text("Credits 是与订阅用量窗口不同的计费余额，部分套餐可购买额外用量；不是人民币、美元、token 数或剩余消息次数。")
                Text("没有可用 Credits 不等于订阅窗口已用尽，也不能据此判断套餐不支持额外用量。数据对应最近一次查询，请以官方用量页为准。")
            }
            .navigationTitle("关于 Credits").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

enum DateDisplay {
    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 h:mm a"
        return formatter
    }()
    private static let withYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 h:mm a"
        return formatter
    }()
    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "h:mm a"
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

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }

}
