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
                Form {
                    Section("剩余额度") {
                        if let snapshot = account.snapshot {
                            let metrics = QuotaDisplayRules.overviewMetrics(snapshot)
                            if metrics.isEmpty { Text("服务未返回可展示的订阅窗口或余额。") }
                            ForEach(metrics) { metric in
                                MetricDetailRow(account: account, metric: metric) { editingRule = metric }
                            }
                            Text("更新于 \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                if QuotaDisplayRules.needsRefresh(account, now: context.date) {
                                    Text("旧数据仅供参考，过期或已到重置时间不代表额度已恢复。")
                                        .font(.footnote).foregroundColor(.orange)
                                }
                            }
                        } else { Text("暂无数据，请刷新。") }
                        if let error = account.error { Text(error).foregroundColor(.orange).font(.footnote) }
                        if let until = account.nextAllowedAt, until > Date() {
                            Text("下次允许查询：\(until.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Button { Task { await store.refresh(id, forced: true) } } label: {
                            HStack { Text("刷新额度"); Spacer(); if store.busy.contains(id) { ProgressView() } }
                        }.disabled(store.busy.contains(id) || account.requiresAuth)
                    }
                    if account.kind == .codex {
                        CreditsDetailSection(account: account) { editingRule = $0 }
                    }
                    Section("账户") {
                        LabeledContent("平台", value: account.kind.name)
                        if let identity = account.identity { LabeledContent("登录身份", value: identity) }
                        if let plan = account.snapshot?.plan { LabeledContent("套餐（服务端报告）", value: plan) }
                        TextField("账户别名", text: $alias)
                        if alias.trimmingCharacters(in: .whitespacesAndNewlines) != account.alias {
                            Button("保存别名") {
                                do { try store.rename(id, alias: alias) } catch { store.message = store.safeMessage(error) }
                            }
                        }
                    }
                    Section {
                        Button(account.kind == .codex ? "重新登录" : "更换 API Key") { editAccount = true }
                        Link("打开官方用量页面", destination: URL(string: account.kind == .codex
                            ? "https://chatgpt.com/codex/settings/usage" : "https://platform.deepseek.com/usage")!)
                    } footer: {
                        Text(account.kind == .codex
                            ? "Codex 使用客户端未公开的用量接口，可能变化或不可用。各窗口独立，不等于固定剩余请求数。"
                            : "不同 API Key 可能共享同一账户余额，不要重复相加；不同币种分别展示。")
                    }
                    Section {
                        Button("删除本机账户", role: .destructive) { deleting = true }
                    }
                }
                .navigationTitle(account.alias)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { alias = account.alias }
                .sheet(isPresented: $editAccount) { AccountEditor(store: store, replacing: id) }
                .sheet(item: $editingRule) { metric in RuleEditor(store: store, accountID: id, metric: metric) }
                .confirmationDialog("删除账户和本机凭据？不会注销远端账号。", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        do { try store.delete(id); dismiss() } catch { store.message = store.safeMessage(error) }
                    }
                }
            } else { Text("账户已删除").foregroundColor(.secondary) }
        }
    }
}

private struct MetricDetailRow: View {
    let account: Account
    let metric: QuotaMetric
    let editRule: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let fresh = QuotaDisplayRules.isFresh(metric, account: account, now: context.date)
            let low = QuotaDisplayRules.isLow(metric, account: account, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                MetricValueRow(metric: metric, emphasized: fresh, detail: true, low: low)
                if metric.unit == .percent, let remaining = metric.remaining {
                    ProgressView(value: NSDecimalNumber(decimal: remaining).doubleValue, total: 100)
                        .tint(low ? .orange : (fresh ? .accentColor : .secondary))
                        .accessibilityLabel("剩余比例")
                        .accessibilityValue(MetricPresentation.value(metric))
                }
                if let reset = metric.resetAt {
                    Text("重置：\(reset.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                }
                if !fresh {
                    Label("待刷新，旧值仅供参考", systemImage: "clock")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let granted = metric.granted {
                    Text("赠金：\(MetricPresentation.number(granted))").font(.caption).foregroundColor(.secondary)
                }
                if let toppedUp = metric.toppedUp {
                    Text("充值余额：\(MetricPresentation.number(toppedUp))").font(.caption).foregroundColor(.secondary)
                }
                if !metric.unlimited {
                    Button(action: editRule) {
                        HStack {
                            Image(systemName: "bell")
                            if let rule = account.rules.first(where: { $0.metricID == metric.id && $0.enabled }) {
                                Text("剩余 ≤ \(MetricPresentation.number(rule.threshold))\(metric.unit == .percent ? "%" : "") 时提醒")
                            } else { Text("设置低额提醒") }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.subheadline).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }.buttonStyle(.borderless)
                }
            }.padding(.vertical, 4)
        }
    }
}

private struct CreditsDetailSection: View {
    let account: Account
    let editRule: (QuotaMetric) -> Void

    var body: some View {
        Section {
            if let snapshot = account.snapshot {
                if snapshot.creditsAvailable == false {
                    Label("当前无可用 Credits", systemImage: "info.circle")
                        .font(.subheadline)
                    Text("接口报告当前无可用 Credits；这不表示 5 小时或其他订阅窗口已经用尽，也不能据此判断套餐不支持额外用量。")
                        .font(.footnote).foregroundColor(.secondary)
                    if let metric = snapshot.metrics.first(where: { $0.unit == .credits }),
                       account.rules.contains(where: { $0.metricID == metric.id && $0.enabled }) {
                        Button("管理原 Credits 提醒规则") { editRule(metric) }
                        Text("原规则已保留；服务未报告可用 Credits 时，不据此触发低额提醒。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    if let metric = snapshot.metrics.first(where: { $0.unit == .credits }) {
                        MetricDetailRow(account: account, metric: metric) { editRule(metric) }
                        if metric.remaining == 0 && !metric.unlimited {
                            Text("Credits 余额为 0，不等于订阅额度为 0。订阅剩余情况请看上方各窗口。")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    } else {
                        Text("Credits 余额未知").font(.subheadline)
                    }
                    if snapshot.creditsAvailable == nil {
                        Text("适用情况未知：本次数据没有提供可用标志；若有余额，仅展示服务端报告值，请以官方用量页为准。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                Text("这些信息对应最近一次查询，不代表实时余额。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("暂无 Credits 数据，请先刷新账户。")
            }
        } header: {
            Text("Credits · 额外用量余额")
        } footer: {
            Text("Credits 是与订阅用量窗口不同的计费余额，部分套餐可购买额外用量；不是人民币、美元、token 数或剩余消息次数。是否可用及扣费规则以官方账户页面为准。")
        }
    }
}
