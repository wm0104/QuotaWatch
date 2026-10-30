import SwiftUI

struct AccountEditor: View {
    @ObservedObject var store: AccountStore
    var replacing: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ProviderKind.codex
    @State private var alias = ""
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    Picker("平台", selection: $kind) {
                        ForEach(ProviderKind.allCases) { Text($0.name).tag($0) }
                    }.disabled(replacing != nil || saving)
                    TextField("账户别名，例如主账号", text: $alias).disabled(saving)
                    if kind == .deepseek {
                        SecureField("DeepSeek API Key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(saving)
                    }
                }
                Section {
                    Button {
                        operation = Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await store.add(kind: kind, alias: alias, key: key, replacing: replacing)
                                if !Task.isCancelled { dismiss() }
                            } catch is CancellationError { }
                            catch { if !Task.isCancelled { self.error = store.safeMessage(error) } }
                        }
                    } label: {
                        HStack {
                            Text(kind == .codex ? "通过 OpenAI 登录并验证额度" : "验证余额并保存")
                            Spacer()
                            if saving { ProgressView() }
                        }
                    }.disabled(saving || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text(kind == .codex
                        ? "将打开 OpenAI 登录页。请核对实际账号，必要时先退出网页中的旧账号。新 App 独立授权，不读取 Minis 的凭据。登录及用量读取参考 Codex 客户端流程，并非官方开放的第三方配额接口。"
                        : "密钥仅保存到本机钥匙串，用于官方余额查询，不调用聊天模型；不同密钥可能共享余额。")
                }
                if saving { Text("请完成浏览器登录或等待服务响应；可点取消安全退出。").font(.footnote).foregroundColor(.secondary) }
            }
            .navigationTitle(replacing == nil ? "添加账户" : "更新凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { operation?.cancel(); store.oauth.cancel(); dismiss() }
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                if let id = replacing, let account = store.account(id) { kind = account.kind; alias = account.alias }
            }
            .onDisappear { operation?.cancel() }
            .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var store: AccountStore
    let accountID: UUID
    let metric: QuotaMetric
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var threshold = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(metric.title) {
                    Toggle("低额度提醒", isOn: $enabled)
                    if enabled {
                        TextField(metric.unit == .percent ? "剩余百分比，例如 20" : "剩余金额／credits", text: $threshold)
                            .keyboardType(.decimalPad)
                        Text("剩余值小于或等于该阈值时提醒一次；持续低位不重复。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                Section {
                    Button("保存规则") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                let amount: Decimal
                                if enabled {
                                    let raw = threshold.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard raw.range(of: #"^[0-9]{1,12}([.,][0-9]{1,6})?$"#, options: .regularExpression) != nil,
                                          let value = Decimal(string: raw.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) else {
                                        throw QuotaError.message("请输入有效的非负数字，最多 6 位小数。")
                                    }
                                    amount = value
                                    if metric.unit == .percent && amount > 100 { throw QuotaError.message("百分比应为 0–100。") }
                                    if store.notifications.status == .notDetermined { try await store.notifications.authorize() }
                                } else { amount = 0 }
                                try await store.setRule(accountID, metricID: metric.id, enabled: enabled, threshold: amount)
                                if enabled && !store.notifications.permitted {
                                    store.message = "规则已保存，但系统通知未获允许；请在设置中开启。"
                                }
                                dismiss()
                            } catch { self.error = store.safeMessage(error) }
                        }
                    }.disabled(saving)
                } footer: { Text("规则按账户、窗口／币种分别生效。不保证后台准时检查。") }
            }
            .navigationTitle("自定义提醒").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) } }
            .onAppear {
                if let rule = store.account(accountID)?.rules.first(where: { $0.metricID == metric.id }) {
                    enabled = rule.enabled; threshold = NSDecimalNumber(decimal: rule.threshold).stringValue
                }
            }
            .task { await store.notifications.reload() }
            .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
