import SwiftUI
import UIKit

struct OverviewView: View {
    @ObservedObject var store: AccountStore
    @State private var adding = false
    @State private var settings = false
    @State private var deleteID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError {
                    Section {
                        Label(error, systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundColor(.orange)
                        Button("重试读取（不覆盖原文件）") { store.reloadArchive() }
                    }
                }
                if store.accounts.isEmpty && store.loadError == nil {
                    Section {
                        VStack(spacing: 14) {
                            Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundColor(.accentColor)
                            Text("添加你的第一个账户").font(.headline)
                            Text("Codex 登录后查询订阅用量；DeepSeek 使用 API Key 查询余额。")
                                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                            Button("添加账户") { adding = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }
                ForEach(ProviderKind.allCases) { kind in
                    let items = store.accounts.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { account in
                                NavigationLink {
                                    AccountDetailView(store: store, id: account.id)
                                } label: {
                                    AccountSummary(account: account, refreshing: store.busy.contains(account.id))
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteID = account.id } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(kind == .codex ? "CodexLogo" : "DeepSeekLogo")
                                    .renderingMode(.original)
                                    .resizable().scaledToFit().frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .accessibilityHidden(true)
                                Text(kind.name)
                            }
                            .textCase(nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                Section { } footer: {
                    Label("低额提醒在成功查询后判断；重置提醒按服务端预计时间排程，均不保证准时。", systemImage: "info.circle")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("QuotaWatch")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .refreshable { await store.refreshAll(forced: true) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NativeMenuButton(accessibilityLabel: "更多操作") {
                        UIMenu(children: [
                            UIAction(title: "刷新全部", image: UIImage(systemName: "arrow.clockwise"),
                                     attributes: store.loadError == nil ? [] : .disabled) { _ in
                                Task { await store.refreshAll(forced: true) }
                            },
                            UIAction(title: "设置", image: UIImage(systemName: "gearshape")) { _ in settings = true }
                        ])
                    }.frame(width: 44, height: 44)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .disabled(store.loadError != nil).accessibilityLabel("添加账户")
                }
            }
            .sheet(isPresented: $adding) { AccountEditor(store: store) }
            .sheet(isPresented: $settings) { SettingsView(notifications: store.notifications) }
            .confirmationDialog("删除此账户及本机凭据？此操作不会注销远端账号。", isPresented: Binding(
                get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
                Button("删除账户", role: .destructive) {
                    if let id = deleteID { do { try store.delete(id) } catch { store.message = store.safeMessage(error) } }
                    deleteID = nil
                }
            }
            .alert("提示", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("知道了", role: .cancel) { store.message = nil }
            } message: { Text(store.message ?? "") }
        }
    }
}

struct AccountSummary: View {
    let account: Account
    let refreshing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if let snapshot = account.snapshot {
                    let metrics = QuotaDisplayRules.overviewMetrics(snapshot)
                    if account.kind == .deepseek, let first = metrics.first {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(account.alias).font(.headline).fixedSize()
                                Spacer(minLength: 8)
                                Text(MetricPresentation.value(first)).font(.headline.monospacedDigit()).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.alias).font(.headline)
                                Text(MetricPresentation.value(first)).font(.headline.monospacedDigit())
                            }
                        }
                        Text("\(QuotaDisplayRules.title(first)) · \(DateDisplay.short(snapshot.capturedAt))")
                            .font(.caption).foregroundColor(.secondary)
                        ForEach(Array(metrics.dropFirst())) { metric in
                            MetricValueRow(metric: metric,
                                emphasized: QuotaDisplayRules.isFresh(metric, account: account, now: context.date),
                                low: QuotaDisplayRules.isLow(metric, account: account, now: context.date))
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(account.alias).font(.headline).fixedSize()
                                Spacer(minLength: 0)
                                HStack(spacing: 5) {
                                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                                        if index > 0 { Text("·").foregroundColor(.secondary) }
                                        Text("\(QuotaDisplayRules.title(metric)) \(MetricPresentation.value(metric))")
                                            .foregroundColor(QuotaDisplayRules.isLow(metric, account: account, now: context.date) ? .orange :
                                                (QuotaDisplayRules.isFresh(metric, account: account, now: context.date) ? .primary : .secondary))
                                            .fixedSize()
                                    }
                                }.font(.subheadline.monospacedDigit())
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.alias).font(.headline)
                                metricRows(metrics, now: context.date)
                            }
                        }
                        Text(DateDisplay.short(snapshot.capturedAt)).font(.caption).foregroundColor(.secondary)
                    }
                    if metrics.isEmpty {
                        Text(account.kind == .codex ? "暂无订阅窗口，Credits 请查看详情" : "服务未返回可展示的余额")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if metrics.contains(where: { QuotaDisplayRules.isLow($0, account: account, now: context.date) }) {
                        Label("达到提醒阈值", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                    if QuotaDisplayRules.needsRefresh(account, now: context.date) {
                        Label("数据已过期／待刷新", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundColor(.orange)
                    }
                } else {
                    Text(account.alias).font(.headline)
                    Text("暂无数据").font(.subheadline).foregroundColor(.secondary)
                }
                if refreshing { Label("正在刷新", systemImage: "arrow.clockwise").font(.caption).foregroundColor(.secondary) }
                if account.requiresAuth {
                    Label("需要重新登录或更换密钥", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundColor(.orange)
                }
                if let error = account.error {
                    Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 2)
        }
    }

    private func metricRows(_ metrics: [QuotaMetric], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(metrics) { metric in
                MetricValueRow(metric: metric,
                    emphasized: QuotaDisplayRules.isFresh(metric, account: account, now: now),
                    low: QuotaDisplayRules.isLow(metric, account: account, now: now))
            }
        }
    }
}

struct MetricValueRow: View {
    let metric: QuotaMetric
    var emphasized = true
    var detail = false
    var low = false
    var pendingRefresh = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var amount: some View {
        Text(MetricPresentation.value(metric))
            .font((detail ? Font.title2 : Font.subheadline).weight(.semibold).monospacedDigit())
            .foregroundColor(low ? .orange : (emphasized ? .primary : .secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(QuotaDisplayRules.title(metric)).font(.subheadline).foregroundColor(.secondary)
                    amount
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(QuotaDisplayRules.title(metric)).font(.subheadline).foregroundColor(.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                        amount.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(QuotaDisplayRules.title(metric)).font(.subheadline).foregroundColor(.secondary)
                        amount
                    }
                }
            }
            if low {
                Label("达到提醒阈值", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundColor(.orange)
            } else if pendingRefresh {
                Label("待刷新", systemImage: "clock")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

enum MetricPresentation {
    static func number(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func value(_ metric: QuotaMetric) -> String {
        if metric.unlimited { return "不限量（服务端报告）" }
        guard let remaining = metric.remaining else { return "未知" }
        switch metric.unit {
        case .percent: return "\(number(remaining))% 剩余"
        case .cny: return "¥\(number(remaining))"
        case .usd: return "$\(number(remaining))"
        case .credits: return "\(number(remaining)) credits"
        }
    }
}
