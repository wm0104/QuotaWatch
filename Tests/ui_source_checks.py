"""Source/asset integration guards; not a runtime screenshot or device UI test."""
import json
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UIIntegrationChecks(unittest.TestCase):
    def test_provider_icons_are_in_section_titles_not_app_title(self):
        for name in ('CodexLogo', 'DeepSeekLogo'):
            asset = ROOT / ('QuotaWatch/Assets.xcassets/' + name + '.imageset')
            manifest = json.loads((asset / 'Contents.json').read_text())
            self.assertEqual({image['scale'] for image in manifest['images']}, {'1x', '2x', '3x'})
            for image in manifest['images']:
                data = (asset / image['filename']).read_bytes()
                self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))
                pixels = 24 * int(image['scale'][0])
                self.assertEqual(struct.unpack_from('>2I', data, 16), (pixels, pixels))
        source = (ROOT / 'QuotaWatch/OverviewView.swift').read_text()
        self.assertIn('Image(kind == .codex ? "CodexLogo" : "DeepSeekLogo")', source)
        self.assertIn('} header: {\n                            HStack(spacing: 8)', source)
        self.assertIn('Text(kind.name)', source)
        self.assertIn('.textCase(nil)', source)
        self.assertNotIn('Image("BrandMark")', source)
        self.assertNotIn('placement: .principal', source)
        self.assertIn('.navigationTitle("QuotaWatch")', source)
        models = (ROOT / 'QuotaWatch/Models.swift').read_text()
        self.assertIn('case .codex: return "Codex"', models)
        self.assertIn('case .deepseek: return "DeepSeek"', models)
        provenance = json.loads((ROOT / 'QuotaWatch/ProviderIconSources.json').read_text())
        self.assertEqual({entry['asset'] for entry in provenance['icons']}, {'CodexLogo', 'DeepSeekLogo'})

    def test_home_remains_native_digits_and_filters_credits(self):
        source = (ROOT / 'QuotaWatch/OverviewView.swift').read_text()
        self.assertIn('.listStyle(.insetGrouped)', source)
        self.assertIn('QuotaDisplayRules.overviewMetrics(snapshot)', source)
        self.assertNotIn('metrics.prefix(3)', source)
        self.assertNotIn('ProgressView(value:', source)
        self.assertIn('QuotaDisplayRules.isLow(metric, account: account, now: context.date)', source)
        self.assertIn('达到提醒阈值', source)
        self.assertIn('待刷新', source)
        self.assertIn('typeSize.isAccessibilitySize', source)
        self.assertIn('ViewThatFits(in: .horizontal)', source)

    def test_credits_detail_does_not_label_zero_subscription_exhausted(self):
        source = (ROOT / 'QuotaWatch/AccountDetailView.swift').read_text()
        self.assertIn('CreditsDetailSection(account: account)', source)
        self.assertIn('snapshot.creditsAvailable == false', source)
        self.assertIn('snapshot.creditsAvailable == nil', source)
        self.assertIn('metric.remaining == 0', source)
        self.assertIn('不能据此判断套餐不支持', source)
        self.assertIn('Credits 余额为 0，不等于订阅额度为 0', source)
        self.assertIn('管理原 Credits 提醒规则', source)
        self.assertNotIn('DetailProgressBar', source)
        card = source.split('private struct DetailMetricsCard:')[1].split('private struct DetailMetricRow:')[0]
        self.assertIn('MetricPresentation.value(metric, compact: true)', card)
        self.assertIn('ViewThatFits(in: .horizontal)', card)
        self.assertIn('metrics.count > 1 && !typeSize.isAccessibilitySize', card)
        self.assertIn('ForEach(metrics)', card)
        self.assertIn('Text("|")', card)
        self.assertNotIn('resetText', card)
        self.assertNotIn('ProgressView', card)
        self.assertNotIn('剩余', card)

    def test_compact_group_and_preserved_semantics(self):
        detail = (ROOT / 'QuotaWatch/AccountDetailView.swift').read_text()
        group = detail.split('ResetNotificationStatus(notifications: store.notifications)', 1)[1].split('.padding(.horizontal, 16)', 1)[0]
        self.assertEqual(group.count('DisclosureGroup('), 3)
        self.assertEqual(group.count('.background('), 1)
        self.assertEqual(group.count('.clipShape('), 1)
        self.assertEqual(group.count('Divider()'), 2)
        self.assertNotIn('detailDisclosureStyle', detail)
        for start, end in (('private struct CreditsDetailSection:', 'private struct DetailAccountCard:'),
                           ('private struct DetailAccountCard:', 'private struct CreditsInfoSheet:')):
            section = detail.split(start)[1].split(end)[0]
            self.assertNotIn('.background(', section)
            self.assertNotIn('.clipShape(', section)
        row = detail.split('private struct DetailMetricRow:')[1].split('private struct DetailEmptyCard:')[0]
        self.assertNotIn('Button(', row)
        self.assertIn('MetricPresentation.amount(rule.threshold, unit: metric.unit)', row)
        self.assertIn('重置提醒 开', row)
        self.assertNotIn('需系统通知权限及未来时间', detail)
        self.assertIn('notifications.resetIssue', detail)
        self.assertIn('if changed {', detail)
        self.assertIn('alias.trimmingCharacters(in: .whitespacesAndNewlines) != account.alias', detail)
        self.assertIn('catch { store.message = store.safeMessage(error) }', detail)
        presentation = (ROOT / 'QuotaWatch/OverviewView.swift').read_text().split('enum MetricPresentation {')[1]
        for fragment in ('compact: Bool = false', 'if metric.unlimited', 'guard let remaining = metric.remaining',
                         'unitLabel(metric.unit)', 'case .cny: return "¥', 'case .usd: return "$',
                         'case .credits: return', 'metric.unit == .percent && !compact'):
            self.assertIn(fragment, presentation)

    def test_all_existing_account_actions_are_preserved(self):
        overview = (ROOT / 'QuotaWatch/OverviewView.swift').read_text()
        detail = (ROOT / 'QuotaWatch/AccountDetailView.swift').read_text()
        for fragment in ('store.refreshAll(forced: true)', 'AccountEditor(store: store)', 'SettingsView(', 'store.delete(id)'):
            self.assertIn(fragment, overview)
        for fragment in ('store.rename(id, alias: alias)', 'store.refresh(account.id, forced: true)',
                         'RuleEditor(store:', 'AccountEditor(store: store, replacing: id)', 'store.delete(id)'):
            self.assertIn(fragment, detail)


    def test_uikit_menus_and_independent_disclosures(self):
        bridge = (ROOT / 'QuotaWatch/NativeMenuButton.swift').read_text()
        detail = (ROOT / 'QuotaWatch/AccountDetailView.swift').read_text()
        overview = (ROOT / 'QuotaWatch/OverviewView.swift').read_text()
        for fragment in ('UIViewRepresentable', 'UIButton(type: .system)',
                         'showsMenuAsPrimaryAction = true', 'button.menu = menu()',
                         'button.accessibilityLabel = accessibilityLabel'):
            self.assertIn(fragment, bridge)
        for source in (detail, overview):
            self.assertIn('NativeMenuButton(accessibilityLabel:', source)
            self.assertIn('UIMenu(children:', source)
            self.assertNotIn('.displayInline', source)
            self.assertNotRegex(source, r'(?<![A-Za-z])Menu\s*[({]')
        for state in ('quotaExpanded', 'creditsExpanded', 'accountExpanded'):
            self.assertIn(f'@State private var {state} = false', detail)
            self.assertIn(f'isExpanded: ${state}', detail)
        for title in ('提醒设置', '账户管理'):
            self.assertIn(f'UIMenu(title: "{title}"', detail)
        self.assertIn('state: enabled ? .on : .off', detail)
        self.assertIn('attributes: .destructive', detail)
        self.assertIn('.confirmationDialog(', detail)
        self.assertIn('CreditsInfoSheet()', detail)
        self.assertIn('if account.kind == .codex {', detail)
        self.assertIn('.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)', detail)
        self.assertNotIn('DetailActionsCard', detail)
        self.assertNotIn('.borderedProminent', detail)
        self.assertIn('DetailRefreshControl(store: store, account: account)', detail)
        self.assertIn('DetailStatusFooter(account: account)', detail)
        self.assertIn('.refreshable { await store.refreshAll(forced: true) }', overview)
        self.assertIn('.swipeActions(edge: .trailing)', overview)
        self.assertIn('Button { adding = true } label: { Image(systemName: "plus") }', overview)
        self.assertIn('ForEach(Array(metrics.dropFirst()))', overview)
        self.assertIn('ForEach(Array(metrics.enumerated()), id: \\.element.id)', overview)
        self.assertIn('HStack(alignment: .firstTextBaseline, spacing: 8)', overview)
        # The fallback is wrap/stack, never a one-line truncation or hidden metric cap.
        self.assertNotIn('.lineLimit(1)', overview)
        self.assertNotIn('metrics.prefix(', overview)

    def test_reset_lifecycle_and_serialized_worker_guards(self):
        store = (ROOT / 'QuotaWatch/AccountStore.swift').read_text()
        service = (ROOT / 'QuotaWatch/NotificationService.swift').read_text()
        planner = (ROOT / 'QuotaWatch/ResetNotificationPlanner.swift').read_text()
        app = (ROOT / 'QuotaWatch/QuotaWatchApp.swift').read_text()
        self.assertIn('current.revision == initial.revision', store)
        self.assertIn('previous.remoteID != credential.accountID || previous.identity != credential.identity', store)
        self.assertIn('value.resetAlerts = nil', store)
        self.assertIn('try LocalArchive.save(list)\n            accounts = list\n            notifications.reconcileResets(accounts: list)', store)
        self.assertIn('notifications.reconcileResets(accounts: accounts)', store)
        self.assertIn('store.reconcileResetNotifications()', app)
        self.assertIn('guard resetWorker == nil else { return }', service)
        self.assertIn('if generation == resetGeneration { break }', service)
        self.assertGreaterEqual(service.count('guard generation == resetGeneration else { return }'), 2)
        self.assertIn('resetGeneration &+= 1', service)
        self.assertIn('pending.count - owned.count', service)
        self.assertIn('candidates.count > plans.count', service)
        self.assertIn('!desired.contains($0)', service)
        self.assertIn('!enabled.contains($0)', service)
        self.assertIn('center.removePendingNotificationRequests(withIdentifiers: [plan.identifier])', service)
        self.assertIn('repeats: false', service)
        self.assertNotIn('repeats: true', service)
        self.assertIn('existing.content.userInfo["resetAt"] as? Double', service)
        self.assertIn('系统通知未获允许', service)
        self.assertIn('排程失败', service)
        self.assertIn('reset > now, reset > snapshot.capturedAt', planner)
        self.assertIn('reset.timeIntervalSince1970.isFinite', planner)
        self.assertIn('!account.requiresAuth', planner)
        self.assertNotIn('account.error == nil', planner)  # transient network errors retain schedules
        self.assertNotIn('durationSeconds', planner)  # no reset guesswork
        self.assertIn('56 - max(0, otherPending)', planner)
        self.assertIn('identifier: "low-\\(account.id.uuidString)"', service)
        self.assertIn('AlertEvaluator.evaluate', store)  # independent old low-alert path retained


if __name__ == '__main__':
    unittest.main(verbosity=2)
