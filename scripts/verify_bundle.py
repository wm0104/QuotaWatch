#!/usr/bin/env python3
"""Verify the signed app and its embedded WidgetKit extension (macOS only)."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from check_project import (
    APP_ENTITLEMENTS, APP_GROUP, BUNDLE_ID, MIN_OS, NAME, VERSION,
    WIDGET_ENTITLEMENTS, WIDGET_ID, check_info, check_widget_info, require,
)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def verify_bundle(bundle, executable_name, bundle_id, expected_entitlements, widget=False):
    with (bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if widget:
        check_widget_info(info, built=True)
    else:
        check_info(info, built=True)
    executable = bundle / executable_name
    require(executable.is_file(), "Missing executable: " + executable_name)
    require(not (bundle / "embedded.mobileprovision").exists(),
            "Unexpected provisioning profile")
    require((bundle / "_CodeSignature/CodeResources").is_file(),
            "Missing signed resource seal: " + executable_name)
    require(output("xcrun", "lipo", "-archs", str(executable)) == "arm64",
            "The product must contain arm64 only")
    build = output("xcrun", "vtool", "-show-build", str(executable))
    require(re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", build) == ["IOS"],
            "The Mach-O platform must be iOS, not simulator/macOS")
    require(re.findall(r"(?m)^\s*minos\s+(\S+)\s*$", build) == [MIN_OS],
            "Mach-O minimum OS does not match Info.plist")
    embedded = plistlib.loads(subprocess.check_output(["ldid", "-e", str(executable)]))
    require(embedded == expected_entitlements,
            "Embedded entitlements differ from the minimal allowlist: " + executable_name)
    signed = plistlib.loads(output("codesign", "--display", "--entitlements", ":-", str(bundle)).encode())
    require(signed == expected_entitlements,
            "Signed entitlements differ from the minimal allowlist: " + executable_name)
    subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(bundle)],
                   check=True)


def main():
    require(len(sys.argv) == 2, "Usage: verify_bundle.py path/to/QuotaWatch.app")
    app = Path(sys.argv[1]).resolve()
    require(app.is_dir() and app.name == "QuotaWatch.app", "Expected QuotaWatch.app")
    with (app / "Info.plist").open("rb") as stream:
        check_info(plistlib.load(stream), built=True)
    require((app / "Assets.car").is_file(), "Missing compiled asset catalog")
    icons = plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleIcons", {})
    primary = icons.get("CFBundlePrimaryIcon", {})
    require(primary.get("CFBundleIconName") == "AppIcon", "Missing compiled AppIcon metadata")
    require(bool(primary.get("CFBundleIconFiles")), "Missing compiled icon files")

    plugins = app / "PlugIns"
    require(plugins.is_dir(), "Missing extension PlugIns directory")
    extensions = sorted(plugins.glob("*.appex"))
    require([p.name for p in extensions] == ["QuotaWatchWidget.appex"],
            "Expected exactly one QuotaWatchWidget.appex")
    extension = extensions[0]
    verify_bundle(extension, "QuotaWatchWidget", WIDGET_ID, WIDGET_ENTITLEMENTS, widget=True)
    verify_bundle(app, "QuotaWatch", BUNDLE_ID, APP_ENTITLEMENTS)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
                   check=True)
    print("Verified: QuotaWatch 0.2.1 (7) + QuotaWatchWidget, iOS 16.3, arm64, "
          "isolated minimal entitlements")


if __name__ == "__main__":
    main()
