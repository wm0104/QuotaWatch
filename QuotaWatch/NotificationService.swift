import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationService: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    var permitted: Bool { status == .authorized || status == .provisional || status == .ephemeral }

    func reload() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func authorize() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await reload()
    }
    func send(account: Account, stillValid: () -> Bool) async throws -> Bool {
        await reload()
        guard permitted, stillValid() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "额度提醒"
        content.body = "\(account.alias) 已达到你设置的低额度阈值，请打开 QuotaWatch 查看。"
        content.sound = .default
        content.userInfo = ["accountID": account.id.uuidString]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "low-\(account.id.uuidString)", content: content, trigger: nil))
        return true
    }
    func test() async throws {
        await reload()
        guard permitted else { throw QuotaError.message("请先允许系统通知。") }
        let content = UNMutableNotificationContent()
        content.title = "QuotaWatch 测试通知"
        content.body = "通知请求已提交。正式提醒只在成功查询并达到阈值后触发。"
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    }
    func remove(accountID: UUID) {
        let center = UNUserNotificationCenter.current()
        let id = "low-\(accountID.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
