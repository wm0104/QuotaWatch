#!/usr/bin/env python3
"""Validate both signed bundles, including a bounded, path-safe IPA round trip."""
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from check_widget_probe import PRODUCTS, MIN_OS, check_entitlements, check_info, require


def output(*args):
    return subprocess.check_output(args, timeout=120).strip()


def verify_bundle(bundle, name):
    info_path = bundle / "Info.plist"
    require(info_path.stat().st_size <= 1024 * 1024, "Oversized Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    check_info(info, name)
    executable = bundle / name
    require(executable.is_file() and os.access(executable, os.X_OK), "Missing executable: " + name)
    require((bundle / "_CodeSignature/CodeResources").is_file(), "Missing resource seal: " + name)
    require(output("xcrun", "lipo", "-archs", str(executable)) == b"arm64", "Must be arm64 only")
    build = output("xcrun", "vtool", "-show-build", str(executable)).decode()
    require(re.findall(r"(?m)^\s*platform\s+(\S+)\s*$", build) == ["IOS"], "Must be iOS device Mach-O")
    require(re.findall(r"(?m)^\s*minos\s+(\S+)\s*$", build) == [MIN_OS], "Wrong Mach-O deployment target")
    # Both inspectors must agree with the per-bundle allowlist; ldid is never a signer.
    check_entitlements(plistlib.loads(output("ldid", "-e", str(executable))), PRODUCTS[name])
    check_entitlements(plistlib.loads(output("codesign", "--display", "--entitlements", ":-",
                                             str(bundle))), PRODUCTS[name])
    subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(bundle)],
                   check=True, timeout=120)
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(bundle)],
                               capture_output=True, text=True, check=True, timeout=120)
    require("Signature=adhoc" in signature.stderr, "Expected native ad-hoc signature")


def verify_app(app):
    require(app.is_dir() and app.name == "QuotaProbe.app", "Expected QuotaProbe.app")
    entries = list(app.rglob("*"))
    require(len(entries) <= 10000, "Too many bundle entries")
    for path in entries:
        require(not path.is_symlink(), "Unexpected bundle symlink")
        require(path.name != "embedded.mobileprovision", "Unexpected provisioning profile")
        require(path.suffix not in (".framework", ".dylib", ".app"), "Unexpected nested code")
    plugins = app / "PlugIns"
    require(plugins.is_dir() and sorted(p.name for p in plugins.iterdir()) == ["QuotaProbeWidget.appex"],
            "Expected exactly one QuotaProbeWidget.appex")
    extension = plugins / "QuotaProbeWidget.appex"
    require([p for p in entries if p.suffix == ".appex"] == [extension], "Unexpected nested extension")
    verify_bundle(extension, "QuotaProbeWidget")
    verify_bundle(app, "QuotaProbe")
    print("Verified both bundles: 0.1.1 (2), iOS16.3, arm64, WidgetKit, isolated minimal entitlements")


def safe_members(archive):
    members = archive.infolist()
    require(0 < len(members) <= 10000, "Unexpected IPA entry count")
    seen, total = set(), 0
    for member in members:
        path = PurePosixPath(member.filename)
        require(not path.is_absolute() and ".." not in path.parts and "\\" not in member.filename,
                "Unsafe IPA path")
        require(member.filename not in seen, "Duplicate IPA member")
        seen.add(member.filename)
        require(path.parts[:1] == ("Payload",) and (len(path.parts) == 1 or
                path.parts[1] == "QuotaProbe.app"), "Unexpected IPA top-level payload")
        mode = member.external_attr >> 16
        require(not stat.S_ISLNK(mode), "IPA symlink not allowed")
        require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), "Unexpected IPA file type")
        require(not member.flag_bits & 1, "Encrypted IPA entry")
        total += member.file_size
        require(member.file_size <= 256 * 1024 * 1024 and total <= 512 * 1024 * 1024,
                "Oversized IPA")
    return members


def verify_ipa(path):
    require(path.stat().st_size <= 512 * 1024 * 1024, "Oversized IPA archive")
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix="widgetprobe-verify-") as temp:
        for member in safe_members(archive):
            # Stream reads enforce CRC, declared-size bounds and no dangerous extractall paths.
            dest = Path(temp).joinpath(*PurePosixPath(member.filename).parts)
            if member.is_dir():
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            written = 0
            with archive.open(member) as source, dest.open("xb") as target:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    written += len(chunk)
                    require(written <= member.file_size, "IPA entry exceeds declared size")
                    target.write(chunk)
            require(written == member.file_size, "Truncated IPA entry")
            dest.chmod((member.external_attr >> 16) & 0o777 or 0o644)
        verify_app(Path(temp) / "Payload/QuotaProbe.app")


def self_test():
    import io
    for name, accepted in (("Payload/QuotaProbe.app/Info.plist", True),
                           ("../escape", False), ("/Payload/x", False),
                           ("Payload/Other.app/x", False),
                           ("Payload/QuotaProbe.app/../../escape", False)):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr(name, b"test")
        stream.seek(0)
        try:
            with zipfile.ZipFile(stream) as archive:
                safe_members(archive)
        except ValueError:
            require(not accepted, "Safe path rejected")
        else:
            require(accepted, "Unsafe archive path accepted")
    print("Probe IPA path/bounds self-tests: passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        target = Path(sys.argv[1]).resolve()
        verify_ipa(target) if target.suffix == ".ipa" else verify_app(target)
    else:
        raise SystemExit("Usage: verify_widget_probe.py QuotaProbe.app|QuotaProbe.ipa|--self-test")
