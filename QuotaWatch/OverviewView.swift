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
                    Label("仅在成功查询后判断低额提醒；后台检查由 iOS 择机执行，不保证准点。", systemImage: "info.circle")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("QuotaWatch")
            .refreshable { await store.refreshAll(forced: true) }
            .toolbar {
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(account.alias).font(.headline)
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                else if account.requiresAuth { Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundColor(.orange) }
            }
            if let snapshot = account.snapshot {
                ForEach(snapshot.metrics.prefix(3)) { metric in
                    MetricValueRow(metric: metric, emphasized: !MetricPresentation.stale(account))
                }
                if snapshot.metrics.isEmpty { Text("服务未返回可展示的额度").font(.footnote).foregroundColor(.secondary) }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(MetricPresentation.stale(account, now: context.date) ? "数据已过期／待刷新" : "已更新 \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundColor(MetricPresentation.stale(account, now: context.date) ? .orange : .secondary)
                }
            } else { Text("暂无数据").font(.subheadline).foregroundColor(.secondary) }
            if let error = account.error { Text(error).font(.caption).foregroundColor(.orange).lineLimit(2) }
        }.padding(.vertical, 6)
    }
}

struct MetricValueRow: View {
    let metric: QuotaMetric
    var emphasized = true
    var detail = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var amount: some View {
        Text(MetricPresentation.value(metric))
            .font((detail ? Font.title2 : Font.title3).weight(.semibold).monospacedDigit())
            .foregroundColor(emphasized ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.title).font(.subheadline).foregroundColor(.secondary)
                    amount
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(metric.title).font(.subheadline).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    amount.layoutPriority(1)
                }
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
    static func stale(_ account: Account, now: Date = Date()) -> Bool {
        guard let snapshot = account.snapshot else { return true }
        return account.error != nil || now.timeIntervalSince(snapshot.capturedAt) > account.kind.interval * 2
            || snapshot.metrics.contains { $0.resetAt.map { $0 <= now } ?? false }
    }
}
