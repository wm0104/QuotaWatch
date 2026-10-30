#!/usr/bin/env python3
"""Verify the actual signed product, not just the source build settings (macOS)."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from check_project import NAME, MIN_OS, ENTITLEMENTS, check_info, require


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    require(len(sys.argv) == 2, "Usage: verify_bundle.py path/to/QuotaWatch.app")
    app = Path(sys.argv[1]).resolve()
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    check_info(info, built=True)
    executable = app / NAME
    require(executable.is_file(), "Missing app executable")
    require(not (app / "embedded.mobileprovision").exists(), "Unexpected provisioning profile")
    require((app / "_CodeSignature/CodeResources").is_file(), "Missing signed resource seal")
    require((app / "Assets.car").is_file(), "Missing compiled asset catalog")
    icons = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    require(icons.get("CFBundleIconName") == "AppIcon", "Missing compiled AppIcon metadata")
    require(bool(icons.get("CFBundleIconFiles")), "Missing compiled icon files")
    ipad = info.get("CFBundleIcons~ipad", {}).get("CFBundlePrimaryIcon", {})
    require(ipad.get("CFBundleIconName") == "AppIcon", "Missing iPad AppIcon metadata")
    require(output("xcrun", "lipo", "-archs", str(executable)) == "arm64",
            "The product must contain arm64 only")
    build = output("xcrun", "vtool", "-show-build", str(executable))
    require(re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", build) == ["IOS"],
            "The Mach-O platform must be iOS, not simulator/macOS")
    require(re.findall(r"(?m)^\s*minos\s+(\S+)\s*$", build) == [MIN_OS],
            "Mach-O minimum OS does not match Info.plist")
    actual = plistlib.loads(subprocess.check_output(["ldid", "-e", str(executable)]))
    require(actual == ENTITLEMENTS, "Signed entitlements differ from the minimal allowlist")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Verified: QuotaWatch 0.1.0 (1), iOS 16.3, iPhone/iPad, arm64, minimal ad-hoc signature")


if __name__ == "__main__":
    main()
