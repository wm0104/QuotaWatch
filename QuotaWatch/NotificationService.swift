import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationService: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    var permitted: Bool { isPermitted(status) }
    private func isPermitted(_ value: UNAuthorizationStatus) -> Bool {
        value == .authorized || value == .provisional || value == .ephemeral
    }

    @Published private(set) var authorizationDiagnostic: String?
    private var authorizationTask: Task<Void, Error>?
    private var settingsGeneration: UInt64 = 0

    @discardableResult
    func reload() async -> UNAuthorizationStatus {
        settingsGeneration &+= 1
        let generation = settingsGeneration
        let value = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if generation == settingsGeneration { status = value }
        return value
    }
    func authorize() async throws {
        if let pending = authorizationTask { try await pending.value; return }
        let pending = Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let before = await self.reload()
            self.authorizationDiagnostic = "当前系统授权状态 \(before.rawValue)"
            if self.isPermitted(before) { return }
            guard before == .notDetermined else {
                if before == .denied {
                    throw QuotaError.message("系统返回通知权限已关闭，提醒未开启。iOS 不会再次弹出允许框，请在系统设置中允许 QuotaWatch 通知。")
                }
                throw QuotaError.message("系统通知授权状态未知（\(before.rawValue)），提醒未开启，请稍后重试。")
            }
            let granted: Bool
            do {
                // No intermediate permission UI: iOS owns the first-time authorization prompt.
                granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                let after = await self.reload()
                let code = (error as NSError).code
                let domain = (error as NSError).domain == UNErrorDomain ? "UNErrorDomain" : "系统错误"
                self.authorizationDiagnostic = "授权前 \(before.rawValue)；\(domain) 代码 \(code)；授权后 \(after.rawValue)"
                throw QuotaError.message("系统通知授权请求失败（\(domain) \(code)），提醒未开启。可在 App 设置查看授权诊断；这不表示你拒绝过通知。")
            }
            let after = await self.reload()
            self.authorizationDiagnostic = "授权前 \(before.rawValue)；系统返回 \(granted)；授权后 \(after.rawValue)"
            guard self.isPermitted(after) else {
                if after == .denied {
                    throw QuotaError.message("系统返回通知权限已关闭，提醒未开启。iOS 不会再次弹出允许框，请在系统设置中允许 QuotaWatch 通知。")
                }
                throw QuotaError.message("系统尚未授予通知权限（状态 \(after.rawValue)），提醒未开启。请重试并查看 App 设置中的授权诊断。")
            }
        }
        authorizationTask = pending
        defer { authorizationTask = nil }
        try await pending.value
    }
    func send(account: Account, stillValid: () -> Bool) async throws -> Bool {
        let permitted = isPermitted(await reload())
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
    @Published private(set) var resetIssue: String?
    private var resetAccounts: [Account] = []
    private var resetGeneration: UInt64 = 0
    private var resetWorker: Task<Void, Never>?

    // One serialized worker owns all reset request mutations. A stale add is followed by
    // another pass, never by an old task deleting a newer revision's replacement.
    func reconcileResets(accounts: [Account]) {
        resetAccounts = accounts
        resetGeneration &+= 1
        guard resetWorker == nil else { return }
        resetWorker = Task {
            while true {
                let generation = resetGeneration
                let values = resetAccounts
                await reconcileResetPass(accounts: values, generation: generation)
                if generation == resetGeneration { break }
            }
            resetWorker = nil
        }
    }

    private func reconcileResetPass(accounts: [Account], generation: UInt64) async {
        let center = UNUserNotificationCenter.current()
        let permitted = isPermitted(await reload())
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard generation == resetGeneration else { return }
        let owned = pending.filter { $0.identifier.hasPrefix(ResetNotificationPlanner.prefix) }
        let candidates = ResetNotificationPlanner.candidates(accounts: accounts, permitted: permitted)
        let plans = Array(candidates.prefix(ResetNotificationPlanner.capacity(otherPending: pending.count - owned.count)))
        let desired = Set(plans.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !desired.contains($0) })
        let enabled = permitted ? ResetNotificationPlanner.enabledIdentifiers(accounts) : []
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter {
            $0.hasPrefix(ResetNotificationPlanner.prefix) && !enabled.contains($0)
        })
        resetIssue = !permitted && accounts.contains(where: { !($0.resetAlerts ?? []).isEmpty })
            ? "重置提醒已设置，但系统通知未获允许；请在设置中开启。" : nil
        if candidates.count > plans.count {
            resetIssue = "系统通知容量有限，优先排程最近的重置窗口；其余将在下次对账时检查。"
        }
        for plan in plans {
            guard generation == resetGeneration else { return }
            if let existing = owned.first(where: { $0.identifier == plan.identifier }),
               existing.content.title == plan.title, existing.content.body == plan.body,
               existing.content.userInfo["resetAt"] as? Double == plan.resetAt.timeIntervalSince1970 {
                continue
            }
            // If replacement fails, never leave an obsolete reset time armed.
            center.removePendingNotificationRequests(withIdentifiers: [plan.identifier])
            guard plan.resetAt > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.userInfo = ["accountID": plan.accountID.uuidString, "metricID": plan.metricID,
                                "resetAt": plan.resetAt.timeIntervalSince1970]
            let components = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: plan.resetAt)
            let request = UNNotificationRequest(identifier: plan.identifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) }
            catch {
                if generation == resetGeneration { resetIssue = "重置通知排程失败；开关已保存，请稍后打开 App 重试。" }
            }
        }
    }

    func test() async throws {
        let permitted = isPermitted(await reload())
        guard permitted else { throw QuotaError.message("请先允许系统通知。") }
        let content = UNMutableNotificationContent()
        content.title = "QuotaWatch 测试通知"
        content.body = "通知请求已提交。低额提醒在成功查询后判断；重置提醒仅按服务端返回时间排程。"
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
