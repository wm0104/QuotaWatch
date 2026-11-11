"""Regression source wiring guards, NOT Swift execution or iPhone permission tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / 'QuotaWatch' / (name + '.swift')).read_text()
class NotificationRepairChecks(unittest.TestCase):
    def test_one_native_authorization_path(self):
        service = source('NotificationService')
        self.assertIn('private var authorizationTask: Task<Void, Error>?', service)
        self.assertEqual(service.count('requestAuthorization(options:'), 1)
        self.assertIn('authorizationDiagnostic', service)
        self.assertIn('try await notifications.authorize()', source('AccountStore'))
        self.assertNotIn('notifications.status == .notDetermined', source('AccountStore'))
        editor = source('AccountEditor')
        self.assertIn('try await store.notifications.authorize()', editor)
        self.assertNotIn('requestAuthorization(options:', editor)
        self.assertNotIn('notifications.status == .notDetermined', editor)
        self.assertIn('ReminderAuthorization.canCommit', editor)
        self.assertIn('ReminderAuthorization.canCommit', source('AccountStore'))
        self.assertLess(service.index('if self.isPermitted(before) { return }'), service.index('requestAuthorization(options:'))
        self.assertLess(service.index('guard before == .notDetermined'), service.index('requestAuthorization(options:'))
        self.assertIn('let before = await self.reload()', service)
        self.assertIn('let after = await self.reload()', service)
        self.assertIn('.disabled(notifications.status != .notDetermined)', source('SettingsView'))
    def test_detail_text_only_and_actual_count(self):
        detail = source('AccountDetailView')
        self.assertNotIn('DetailProgressBar', detail)
        self.assertNotIn('.adaptive(minimum:', detail)
        self.assertIn('QuotaDisplayRules.detailColumnCount', detail)
        self.assertIn('QuotaDisplayRules.resetText', detail)
        self.assertIn('MetricValueRow(metric:', detail)
    def test_click_cold_start_and_presentation_gate(self):
        app = source('QuotaWatchApp')
        home = source('OverviewView')
        self.assertIn('didReceive response: UNNotificationResponse', app)
        self.assertIn('NotificationRoute.shared.receive', app)
        self.assertIn('NotificationRoute.shared', home)
        self.assertIn('NavigationStack(path: $path)', home)
        self.assertIn('await route.waitForDismissal()', home)
        self.assertIn('notificationAt: event.deliveredAt', home)
        self.assertIn('route.pending != nil', source('AccountDetailView'))
        self.assertIn('defer { accountEditsInFlight -= 1 }', source('AccountStore'))
        self.assertIn('store.accountEditsInFlight > 0', app)
        self.assertIn('controller.transitionCoordinator', app)
        self.assertIn('controller.children.contains', app)
        self.assertIn('\n        .task(id: route.pending?.id)', home)
        self.assertIn('if pending?.id == event.id', app)
    def test_due_reset_bypasses_normal_interval_but_not_server_backoff(self):
        store = source('AccountStore')
        rules = source('QuotaDisplayRules')
        self.assertIn('QuotaRefreshPolicy.allows', store)
        self.assertIn('snapshot.capturedAt < reset', rules)
        self.assertIn('account.nextAllowedAt', rules)
        self.assertIn('account.requiresAuth', rules)
        self.assertIn('notificationAt', rules)
    def test_reset_copy_not_recovery(self):
        planner = source('ResetNotificationPlanner')
        self.assertIn('额度重置时间已到', planner)
        self.assertIn('点击查看恢复后的最新额度', planner)
        self.assertNotIn('预计', planner)
        self.assertNotIn('100%', planner)
if __name__ == '__main__':
    unittest.main()
