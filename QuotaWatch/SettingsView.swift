import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @ObservedObject var notifications: NotificationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @State private var backgroundStatus = UIApplication.shared.backgroundRefreshStatus

    private var notificationLabel: String {
        switch notifications.status {
        case .authorized: return "已允许"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时会话授权"
        case .denied: return "已关闭"
        case .notDetermined: return "尚未授权"
        @unknown default: return "未知"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("系统通知") {
                    LabeledContent("权限", value: notificationLabel)
                    Button("请求通知权限") {
                        Task { do { try await notifications.authorize() } catch { self.error = "通知授权未完成。" } }
                    }
                    Button("发送测试通知") {
                        Task { do { try await notifications.test() } catch { self.error = error.localizedDescription } }
                    }
                    Button("打开系统设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Section("刷新方式") {
                    LabeledContent("后台刷新", value: backgroundStatus == .available ? "系统允许，执行时间不保证" : "不可用／已关闭")
                    Text("前台：Codex 默认每 5 分钟、DeepSeek 每 10 分钟检查到期账户；下拉可手动刷新，30 秒防抖。")
                    Text("后台：仅向 iOS 申请刷新机会。关闭 App、低电量、系统调度或通知权限可能影响提醒；TrollStore 不等于后台常驻。")
                        .foregroundColor(.secondary)
                }.font(.subheadline)
                Section("隐私与限制") {
                    Label("凭据只进本机钥匙串，不上传至开发者服务器。", systemImage: "lock.shield")
                    Label("Codex 使用客户端未公开的用量接口，不保证长期可用。", systemImage: "exclamationmark.triangle")
                    Label("不使用聊天模型推算额度，不合并不同窗口或币种。", systemImage: "chart.bar.xaxis")
                }.font(.footnote)
                Section("关于") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    Link("公开源码与问题反馈", destination: URL(string: "https://github.com/wm0104/QuotaWatch")!)
                    Text("首个测试版：需要使用你自己的账号进行登录和真机验证。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await notifications.reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                backgroundStatus = UIApplication.shared.backgroundRefreshStatus
                Task { await notifications.reload() }
            }
            .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
