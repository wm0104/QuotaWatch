import SwiftUI

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
                        } header: { Text(kind.name) }
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Label("成功查询后判断低额提醒；后台由 iOS 择机检查，不保证准点。", systemImage: "info.circle")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("QuotaWatch")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .refreshable { await store.refreshAll(forced: true) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("BrandMark")
                            .resizable().scaledToFit().frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text("QuotaWatch").font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置与通知权限")
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(account.alias).font(.headline).foregroundColor(.primary)
                    Spacer(minLength: 0)
                    if refreshing { ProgressView().controlSize(.small).accessibilityLabel("正在刷新") }
                    else if account.requiresAuth {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .foregroundColor(.orange).accessibilityLabel("需要重新登录")
                    }
                }
                if let snapshot = account.snapshot {
                    let metrics = QuotaDisplayRules.overviewMetrics(snapshot)
                    ForEach(metrics) { metric in
                        let fresh = QuotaDisplayRules.isFresh(metric, account: account, now: context.date)
                        MetricValueRow(metric: metric, emphasized: fresh,
                                       low: QuotaDisplayRules.isLow(metric, account: account, now: context.date),
                                       pendingRefresh: !fresh)
                    }
                    if metrics.isEmpty {
                        Text(account.kind == .codex ? "暂无订阅窗口，Credits 请查看详情" : "服务未返回可展示的余额")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    let stale = QuotaDisplayRules.needsRefresh(account, now: context.date)
                    Label(stale ? "数据已过期／待刷新" : "更新于 \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))",
                          systemImage: stale ? "exclamationmark.circle" : "clock")
                        .font(.caption).foregroundColor(stale ? .orange : .secondary)
                } else {
                    Text("暂无数据").font(.subheadline).foregroundColor(.secondary)
                }
                if let error = account.error {
                    Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 8)
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
            .font((detail ? Font.title2 : Font.title3).weight(.semibold).monospacedDigit())
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
