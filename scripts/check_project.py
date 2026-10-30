#!/usr/bin/env python3
"""Small stdlib-only guards for the build's identity and security boundary."""
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "QuotaWatch"
BUNDLE_ID = "com.wm0104.quotawatch"
VERSION = "0.1.2"
BUILD = "3"
MIN_OS = "16.3"
ENTITLEMENTS = {
    "application-identifier": BUNDLE_ID,
    "keychain-access-groups": [BUNDLE_ID],
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


def main():
    text = (ROOT / "project.yml").read_text()
    expected = {
        "MARKETING_VERSION": VERSION, "CURRENT_PROJECT_VERSION": BUILD,
        "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": MIN_OS,
        "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "NO", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos", "DEVELOPMENT_TEAM": "",
        "CODE_SIGN_IDENTITY": "", "CODE_SIGNING_REQUIRED": "NO",
        "CODE_SIGNING_ALLOWED": "NO", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": NAME, "TARGETED_DEVICE_FAMILY": "1,2",
        "INFOPLIST_FILE": NAME + "/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": NAME + "/" + NAME + ".entitlements",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "xcodeVersion": "15.4", "objectVersion": "56",
    }
    for key, value in expected.items():
        matches = re.findall(r"(?m)^ +" + re.escape(key) + r": ([^\n]*)$", text)
        require(len(matches) == 1 and matches[0].strip().strip('"') == value,
                "Incorrect project.yml setting: " + key)
    targets = re.findall(r'(?m)^ +(?:iOS|deploymentTarget): "([^"]+)"$', text)
    require(targets == [MIN_OS, MIN_OS], "Deployment targets are not synchronized")
    with (ROOT / NAME / "Info.plist").open("rb") as stream:
        check_info(plistlib.load(stream))
    with (ROOT / NAME / (NAME + ".entitlements")).open("rb") as stream:
        require(plistlib.load(stream) == ENTITLEMENTS, "Entitlements exceed the minimal allowlist")
    print("Build identity, version, background mode, ATS and entitlements: passed")


if __name__ == "__main__":
    main()
