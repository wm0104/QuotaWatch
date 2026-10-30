#!/usr/bin/env python3
"""Small stdlib-only guards for the build's identity and security boundary."""
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "QuotaWatch"
BUNDLE_ID = "com.wm0104.quotawatch"
WIDGET_ID = BUNDLE_ID + ".widget"
APP_GROUP = "group.com.wm0104.quotawatch"
VERSION = "0.2.1"
BUILD = "7"
MIN_OS = "16.3"
APP_ENTITLEMENTS = {
    "application-identifier": BUNDLE_ID,
    "keychain-access-groups": [BUNDLE_ID, WIDGET_ID],
    "com.apple.security.application-groups": [APP_GROUP],
    "get-task-allow": False,
}
WIDGET_ENTITLEMENTS = {
    "application-identifier": WIDGET_ID,
    "keychain-access-groups": [WIDGET_ID],
    "com.apple.security.application-groups": [APP_GROUP],
    "get-task-allow": False,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_info(info, built=False):
    expected = {
        "CFBundleDisplayName": NAME,
        "CFBundleExecutable": NAME if built else "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": BUNDLE_ID if built else "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": NAME if built else "$(PRODUCT_NAME)",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION if built else "$(MARKETING_VERSION)",
        "CFBundleVersion": BUILD if built else "$(CURRENT_PROJECT_VERSION)",
        "UIBackgroundModes": ["fetch"],
        "BGTaskSchedulerPermittedIdentifiers": [BUNDLE_ID + ".refresh"],
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "UIRequiredDeviceCapabilities": ["arm64"],
    }
    if built:
        expected.update(MinimumOSVersion=MIN_OS, UIDeviceFamily=[1, 2],
                        CFBundleSupportedPlatforms=["iPhoneOS"])
    for key, value in expected.items():
        require(info.get(key) == value, "Incorrect Info.plist field: " + key)


def check_widget_info(info, built=False):
    expected = {
        "CFBundleDisplayName": NAME,
        "CFBundleExecutable": "QuotaWatchWidget" if built else "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": WIDGET_ID if built else "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "QuotaWatchWidget" if built else "$(PRODUCT_NAME)",
        "CFBundlePackageType": "XPC!",
        "CFBundleShortVersionString": VERSION if built else "$(MARKETING_VERSION)",
        "CFBundleVersion": BUILD if built else "$(CURRENT_PROJECT_VERSION)",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
    }
    if built:
        expected.update(MinimumOSVersion=MIN_OS, UIDeviceFamily=[1, 2],
                        CFBundleSupportedPlatforms=["iPhoneOS"])
    for key, value in expected.items():
        require(info.get(key) == value, "Incorrect widget Info.plist field: " + key)


def main():
    text = (ROOT / "project.yml").read_text()
    expected = {
        "MARKETING_VERSION": VERSION, "CURRENT_PROJECT_VERSION": BUILD,
        "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": MIN_OS,
        "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "NO", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos", "DEVELOPMENT_TEAM": "",
        "CODE_SIGN_IDENTITY": "", "CODE_SIGNING_REQUIRED": "NO",
        "CODE_SIGNING_ALLOWED": "NO",
        "xcodeVersion": "15.4", "objectVersion": "56",
    }
    for key, value in expected.items():
        matches = re.findall(r"(?m)^ +" + re.escape(key) + r": ([^\n]*)$", text)
        require(len(matches) == 1 and matches[0].strip().strip('"') == value,
                "Incorrect project.yml setting: " + key)

    counts = {
        r'(?m)^\s*PRODUCT_BUNDLE_IDENTIFIER: com\.wm0104\.quotawatch\s*$': 1,
        r'(?m)^\s*PRODUCT_BUNDLE_IDENTIFIER: com\.wm0104\.quotawatch\.widget\s*$': 1,
        r'(?m)^\s*PRODUCT_NAME: QuotaWatch\s*$': 1,
        r'(?m)^\s*PRODUCT_NAME: QuotaWatchWidget\s*$': 1,
        r'(?m)^\s*INFOPLIST_FILE: QuotaWatch/Info\.plist\s*$': 1,
        r'(?m)^\s*INFOPLIST_FILE: QuotaWatchWidget/Info\.plist\s*$': 1,
        r'(?m)^\s*CODE_SIGN_ENTITLEMENTS: QuotaWatch/QuotaWatch\.entitlements\s*$': 1,
        r'(?m)^\s*CODE_SIGN_ENTITLEMENTS: QuotaWatchWidget/QuotaWatchWidget\.entitlements\s*$': 1,
        r'(?m)^\s*TARGETED_DEVICE_FAMILY: "1,2"\s*$': 2,
        r'(?m)^\s*ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\s*$': 1,
        r'(?m)^\s*GENERATE_INFOPLIST_FILE: "NO"\s*$': 2,
        r'(?m)^\s*APPLICATION_EXTENSION_API_ONLY: "YES"\s*$': 1,
        r'(?m)^\s*SKIP_INSTALL: "YES"\s*$': 1,
        r'(?m)^\s*embed: true\s*$': 1,
    }
    for pattern, count in counts.items():
        require(len(re.findall(pattern, text)) == count,
                "Incorrect project.yml occurrence count: " + pattern)

    targets = re.findall(r'(?m)^ +deploymentTarget: "([^"]+)"$', text)
    require(targets == [MIN_OS, MIN_OS], "Deployment targets are not synchronized")

    with (ROOT / NAME / "Info.plist").open("rb") as stream:
        check_info(plistlib.load(stream))
    with (ROOT / NAME / (NAME + ".entitlements")).open("rb") as stream:
        require(plistlib.load(stream) == APP_ENTITLEMENTS,
                "App entitlements exceed the minimal allowlist")
    with (ROOT / "QuotaWatchWidget" / "Info.plist").open("rb") as stream:
        check_widget_info(plistlib.load(stream), built=False)
    with (ROOT / "QuotaWatchWidget" / "QuotaWatchWidget.entitlements").open("rb") as stream:
        require(plistlib.load(stream) == WIDGET_ENTITLEMENTS,
                "Widget entitlements exceed the minimal allowlist")
    print("Build identity, app/widget entitlements, version and background mode: passed")


if __name__ == "__main__":
    main()
