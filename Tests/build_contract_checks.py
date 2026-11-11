"""Packaging contract tests with synthetic bundles/mocked Apple tools; not real signing."""
import copy
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import check_project as contract
import verify_bundle as verifier


class BuildContractChecks(unittest.TestCase):
    def info(self):
        info = plistlib.loads((ROOT / 'QuotaWatch/Info.plist').read_bytes())
        info.update(CFBundleExecutable=contract.NAME, CFBundleIdentifier=contract.BUNDLE_ID,
                    CFBundleName=contract.NAME, CFBundleShortVersionString=contract.VERSION,
                    CFBundleVersion=contract.BUILD, MinimumOSVersion=contract.MIN_OS,
                    UIDeviceFamily=[1, 2], CFBundleSupportedPlatforms=['iPhoneOS'],
                    CFBundleIcons={'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon',
                                                         'CFBundleIconFiles': ['AppIcon60x60']}})
        return info

    def bundle(self, folder):
        app = Path(folder) / 'QuotaWatch.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps(self.info()))
        (app / 'QuotaWatch').write_bytes(b'synthetic-not-a-Mach-O')
        (app / 'Assets.car').write_bytes(b'synthetic')
        (app / '_CodeSignature').mkdir()
        (app / '_CodeSignature/CodeResources').write_bytes(b'synthetic')
        return app

    def test_project_and_formal_workflow_are_app_only(self):
        contract.main()
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        package = (ROOT / 'scripts/package.sh').read_text()
        for source in (workflow, package):
            self.assertNotIn('QuotaWatchWidget', source)
            self.assertNotIn('WidgetProbe', source)
        self.assertIn('bash scripts/test.sh', workflow)
        self.assertIn('runs-on: macos-15', workflow)
        self.assertIn('/Applications/Xcode_16.4.app/Contents/Developer', workflow)
        self.assertIn("rg -x 'Xcode 16\\.4'", workflow)
        self.assertNotIn('runs-on: macos-14', workflow)
        self.assertIn('bash scripts/package.sh', workflow)
        self.assertEqual(package.count('python3 scripts/verify_bundle.py'), 2)
        self.assertIn('codesign --force --sign - --entitlements QuotaWatch/QuotaWatch.entitlements', package)
        self.assertIn('shasum -a 256 -c', package)
        self.assertTrue((ROOT / 'WidgetProbe/project.yml').is_file())
        self.assertTrue((ROOT / '.github/workflows/widget-probe.yml').is_file())
        self.assertEqual(set(contract.APP_ENTITLEMENTS),
                         {'application-identifier', 'keychain-access-groups', 'get-task-allow'})

    def test_bad_build_metadata_rejected(self):
        contract.check_info(self.info(), built=True)
        for key, bad in [('CFBundleVersion', '9'), ('CFBundleShortVersionString', '0.1.1'),
                         ('CFBundleIdentifier', 'wrong'), ('MinimumOSVersion', '17.0'),
                         ('CFBundleSupportedPlatforms', ['iPhoneSimulator']),
                         ('UIDeviceFamily', [1]), ('UIBackgroundModes', ['audio'])]:
            with self.subTest(key=key):
                info = self.info()
                info[key] = bad
                with self.assertRaises(ValueError):
                    contract.check_info(info, built=True)

    def test_forbidden_plugins_and_provisioning_rejected(self):
        with tempfile.TemporaryDirectory(prefix='quotawatch-contract-') as folder:
            app = self.bundle(folder)
            with patch.object(sys, 'argv', ['verify_bundle.py', str(app)]), \
                    patch.object(verifier, 'verify_bundle') as verify, \
                    patch('builtins.print'), \
                    patch.object(verifier.subprocess, 'run'):
                verifier.main()
                self.assertEqual(verify.call_count, 1)
                (app / 'PlugIns').mkdir()
                verifier.main()  # An empty PlugIns directory is harmless.
                (app / 'PlugIns/Unexpected.appex').mkdir()
                with self.assertRaisesRegex(ValueError, 'must not embed'):
                    verifier.main()
            (app / 'embedded.mobileprovision').write_bytes(b'synthetic')
            with self.assertRaisesRegex(ValueError, 'provisioning'):
                verifier.verify_bundle(app, contract.NAME, contract.BUNDLE_ID, contract.APP_ENTITLEMENTS)

    def test_signature_arch_and_platform_guards(self):
        with tempfile.TemporaryDirectory(prefix='quotawatch-signature-') as folder:
            app = self.bundle(folder)
            entitlements = copy.deepcopy(contract.APP_ENTITLEMENTS)
            arch, build = 'arm64', ' platform IOS\n minos 16.3\n'
            signed = copy.deepcopy(entitlements)

            def output(*args):
                if args[:2] == ('xcrun', 'lipo'):
                    return arch
                if args[:2] == ('xcrun', 'vtool'):
                    return build
                if args[0] == 'codesign':
                    return plistlib.dumps(signed).decode()
                raise AssertionError('Unexpected tool')

            def embedded(args):
                self.assertEqual(args[:2], ['ldid', '-e'])
                return plistlib.dumps(entitlements)

            with patch.object(verifier, 'output', side_effect=output), \
                    patch.object(verifier.subprocess, 'check_output', side_effect=embedded), \
                    patch.object(verifier.subprocess, 'run') as codesign:
                verify = lambda: verifier.verify_bundle(app, contract.NAME, contract.BUNDLE_ID, contract.APP_ENTITLEMENTS)
                verify()
                self.assertIn('--strict', codesign.call_args.args[0])
                arch = 'arm64 x86_64'
                with self.assertRaisesRegex(ValueError, 'arm64 only'):
                    verify()
                arch = 'arm64'
                build = ' platform IOSSIMULATOR\n minos 16.3\n'
                with self.assertRaisesRegex(ValueError, 'platform'):
                    verify()
                build = ' platform IOS\n minos 17.0\n'
                with self.assertRaisesRegex(ValueError, 'minimum OS'):
                    verify()
                build = ' platform IOS\n minos 16.3\n'
                for key, value in [('com.apple.security.application-groups', ['group.unwanted']),
                                   ('get-task-allow', True), ('keychain-access-groups', ['wrong'])]:
                    entitlements = dict(contract.APP_ENTITLEMENTS, **{key: value})
                    with self.assertRaisesRegex(ValueError, 'Embedded entitlements'):
                        verify()
                entitlements = copy.deepcopy(contract.APP_ENTITLEMENTS)
                signed['get-task-allow'] = True
                with self.assertRaisesRegex(ValueError, 'Signed entitlements'):
                    verify()


if __name__ == '__main__':
    unittest.main(verbosity=2)
