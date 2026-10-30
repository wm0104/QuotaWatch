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
                        while !Task.isCancelled {
                            await store.refreshAll()
                            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
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
