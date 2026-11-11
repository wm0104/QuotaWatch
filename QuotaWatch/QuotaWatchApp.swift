import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

@main
struct QuotaWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AccountStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            OverviewView(store: store)
                .task(id: phase) {
                    BackgroundRefresh.store = store
                    if phase == .active {
                        await store.notifications.reload()
                        store.reconcileResetNotifications()
                        while !Task.isCancelled {
                            await store.refreshAll()
                            let delay = QuotaRefreshPolicy.nextCheckDelay(store.accounts, now: Date())
                            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                            catch { break }
                        }
                    } else if phase == .background {
                        store.cancelRefreshes()
                        BackgroundRefresh.schedule()
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                let store = BackgroundRefresh.store ?? AccountStore()
                BackgroundRefresh.store = store
                BackgroundRefresh.schedule()
                await store.refreshAll()
                refresh.setTaskCompleted(success: !Task.isCancelled && store.loadError == nil)
            }
            refresh.expirationHandler = {
                work.cancel()
                Task { @MainActor in BackgroundRefresh.store?.cancelRefreshes() }
            }
        }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        let request = response.notification.request
        let event = NotificationTap(identifier: request.identifier, deliveredAt: response.notification.date,
                                    userInfo: request.content.userInfo)
        Task { @MainActor in
            NotificationRoute.shared.receive(event)
            completionHandler()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
enum BackgroundRefresh {
    static let identifier = "com.wm0104.quotawatch.refresh"
    static weak var store: AccountStore?
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        // shortcut: iOS decides when/if this runs; no fixed-interval background guarantee.
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
final class NotificationRoute: ObservableObject {
    static let shared = NotificationRoute()
    @Published private(set) var pending: NotificationTap?
    private var received: [String] = []

    func receive(_ event: NotificationTap) {
        guard !received.contains(event.id) else { return }
        received.append(event.id)
        if received.count > 64 { received.removeFirst() }
        pending = event
    }
    func finish(_ event: NotificationTap) {
        if pending?.id == event.id { pending = nil }
    }
    func waitForActivation(store: AccountStore) async -> Bool {
        // Preserve the full login/verification/save transaction, not only Safari's lifetime.
        while UIApplication.shared.applicationState != .active || store.oauth.isLoggingIn || store.accountEditsInFlight > 0 {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return !Task.isCancelled
    }
    func waitForDismissal() async -> Bool {
        @MainActor func presenting(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.transitionCoordinator != nil
                || controller.children.contains { presenting($0) }
        }
        while !Task.isCancelled {
            let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
            if UIApplication.shared.applicationState == .active, let root, !presenting(root) { return true }
            // Wait for actual UIKit dismissal, not an assumed animation duration.
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return false
    }
}
