#!/usr/bin/env python3
"""Stdlib-only, fail-closed guards for the independent fake-data probe."""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.wm0104.quotawatch.widgetprobe"
GROUP = "group." + APP_ID
PRODUCTS = {"QuotaProbe": APP_ID, "QuotaProbeWidget": APP_ID + ".widget"}
VERSION, BUILD, MIN_OS = "0.1.0", "1", "16.3"
# Static tripwire, not a proof against deliberately obfuscated network/secret code.
FORBIDDEN = re.compile(
    r"\b(?:URLSession|URLRequest|NSURLConnection|CFNetwork|NWConnection|NWListener|"
    r"SecItem\w*|SecKey\w*|SecAccess\w*|Keychain\w*|WKWebView|SFSafariViewController|"
    r"socket|connect|getaddrinfo|dlopen|dlsym)\b|"
    r"\bimport\s+(?:Security|Network|WebKit|AuthenticationServices|CryptoKit)\b|"
    r"https?://|\bsk-[A-Za-z0-9_-]{16,}|\bBearer\s+[A-Za-z0-9_-]{12,}|"
    r"(?:group\.)?com\.wm0104\.quotawatch(?!\.widgetprobe(?:\b|\.))"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def entitlements(bundle_id):
    return {"application-identifier": bundle_id, "get-task-allow": False,
            "com.apple.security.application-groups": [GROUP]}


def check_entitlements(value, bundle_id):
    require(value == entitlements(bundle_id), "Entitlements exceed the exact probe allowlist")
    require(type(value.get("get-task-allow")) is bool, "get-task-allow must be boolean false")


def check_info(info, name):
    expected = {"CFBundleIdentifier": PRODUCTS[name], "CFBundleExecutable": name,
                "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD,
                "MinimumOSVersion": MIN_OS, "UIDeviceFamily": [1, 2],
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
                "CFBundlePackageType": "APPL" if name == "QuotaProbe" else "XPC!"}
    for key, value in expected.items():
        require(info.get(key) == value, name + ": incorrect " + key)
    require(not any(k in info for k in ("NSAppTransportSecurity", "UIBackgroundModes",
                                        "BGTaskSchedulerPermittedIdentifiers")),
            "Probe must not inherit main app networking/background configuration")
    if name == "QuotaProbe":
        require(info.get("CFBundleDisplayName") == name, "App display name must be QuotaProbe")
        require("NSExtension" not in info, "Container cannot be an extension")
    else:
        ext = info.get("NSExtension", {})
        require(ext.get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
                "Not a standard WidgetKit extension")


def source_check():
    probe = ROOT / "WidgetProbe"
    require((probe / "project.yml").is_file(), "Missing WidgetProbe/project.yml")
    files = list(probe.rglob("*"))
    require(len(files) <= 500, "Unexpectedly large probe source tree")
    total, swift, found = 0, [], {}
    for path in files:
        require(not path.is_symlink(), "Source symlink not allowed: " + str(path))
        if not path.is_file() or any(p.endswith(".xcodeproj") for p in path.parts):
            continue
        size = path.stat().st_size
        total += size
        require(size <= 2 * 1024 * 1024 and total <= 16 * 1024 * 1024,
                "Probe source exceeds bounded validation limits")
        if path.suffix == ".swift":
            swift.append(path)
            match = FORBIDDEN.search(path.read_text())
            require(match is None, "Forbidden network/security/main-app reference: " + str(path)
                    + (" (" + match.group() + ")" if match else ""))
        if path.suffix == ".entitlements":
            data = plistlib.loads(path.read_bytes())
            bundle_id = data.get("application-identifier")
            require(bundle_id in PRODUCTS.values(), "Unknown probe entitlement identity")
            require(bundle_id not in found, "Duplicate entitlement file")
            check_entitlements(data, bundle_id)
            found[bundle_id] = path
    require(len(swift) > 0, "No Swift source")
    require(set(found) == set(PRODUCTS.values()), "Need separate host and extension entitlements")
    require((probe / "Tests/main.swift").is_file(), "Missing portable core tests")
    require(bool(list((probe / "Shared").glob("*.swift"))), "Missing portable Shared sources")
    print("Probe source identity, isolated group, entitlement and no-network tripwires: passed")
    return found


def self_test():
    for token in ("URLSession.shared", "import Security", "SecItemCopyMatching(x)",
                  "https://example.com", 'suiteName: "group.com.wm0104.quotawatch"',
                  "NWConnection", "socket(AF_INET)"):
        require(FORBIDDEN.search(token) is not None, "Missing forbidden source tripwire")
    require(FORBIDDEN.search('"' + GROUP + '"') is None, "Probe group falsely rejected")
    check_entitlements(entitlements(APP_ID), APP_ID)
    for bad in ({**entitlements(APP_ID), "get-task-allow": 0},
                {**entitlements(APP_ID), "keychain-access-groups": [APP_ID]},
                entitlements(PRODUCTS["QuotaProbeWidget"])):
        try:
            check_entitlements(bad, APP_ID)
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted invalid entitlements")
    print("Probe guard self-tests: passed")


def check_settings(path):
    import json
    require(path.stat().st_size <= 8 * 1024 * 1024, "Oversized build settings")
    settings = json.loads(path.read_text())
    require(len(settings) == 2, "Expected only the two independent probe targets")
    require({item["target"] for item in settings} == set(PRODUCTS), "Unexpected targets")
    for item in settings:
        name, values = item["target"], item["buildSettings"]
        for key, expected in {"PRODUCT_BUNDLE_IDENTIFIER": PRODUCTS[name],
                              "PRODUCT_NAME": name, "MARKETING_VERSION": VERSION,
                              "CURRENT_PROJECT_VERSION": BUILD,
                              "IPHONEOS_DEPLOYMENT_TARGET": MIN_OS,
                              "ARCHS": "arm64", "SWIFT_VERSION": "5.0",
                              "TARGETED_DEVICE_FAMILY": "1,2"}.items():
            require(values.get(key) == expected, name + ": incorrect build setting " + key)
        if name == "QuotaProbeWidget":
            require(values.get("APPLICATION_EXTENSION_API_ONLY") == "YES", "Extension must be API-only")
            require(values.get("SKIP_INSTALL") == "YES", "Extension must skip standalone install")
        ent_path = Path(values["SRCROOT"]) / values["CODE_SIGN_ENTITLEMENTS"]
        require(ent_path.resolve().is_relative_to((ROOT / "WidgetProbe").resolve()),
                "Entitlements must belong to the independent probe")
        check_entitlements(plistlib.loads(ent_path.read_bytes()), PRODUCTS[name])
    print("Generated host/extension build settings: passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3 and sys.argv[1] == "--build-settings":
        check_settings(Path(sys.argv[2]))
    elif not sys.argv[1:]:
        source_check()
    else:
        raise SystemExit("Usage: check_widget_probe.py [--self-test | --build-settings FILE]")
