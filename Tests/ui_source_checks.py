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
        self.assertIn('ProgressView(value:', source)

    def test_all_existing_account_actions_are_preserved(self):
        overview = (ROOT / 'QuotaWatch/OverviewView.swift').read_text()
        detail = (ROOT / 'QuotaWatch/AccountDetailView.swift').read_text()
        for fragment in ('store.refreshAll(forced: true)', 'AccountEditor(store: store)', 'SettingsView(', 'store.delete(id)'):
            self.assertIn(fragment, overview)
        for fragment in ('store.rename(id, alias: alias)', 'store.refresh(id, forced: true)',
                         'RuleEditor(store:', 'AccountEditor(store: store, replacing: id)', 'store.delete(id)'):
            self.assertIn(fragment, detail)


if __name__ == '__main__':
    unittest.main(verbosity=2)
