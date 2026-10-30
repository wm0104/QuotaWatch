#!/usr/bin/env python3
"""Normalize XcodeGen's format for Xcode 15.4; refuse unknown project objects."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def patch(text):
    if "PBXFileSystemSynchronized" in text:
        raise ValueError("Synchronized groups require newer Xcode; regenerate ordinary groups")
    fields = (
        (r'(?m)^([ \t]*objectVersion = )\d+(;)$', r'\g<1>56\2', 1),
        (r'(?m)^([ \t]*compatibilityVersion = )"[^"]+"(;)$',
         r'\g<1>"Xcode 14.0"\2', 1),
        (r'(?m)^([ \t]*preferredProjectObjectVersion = )\d+(;)$',
         r'\g<1>56\2', None),
    )
    for pattern, replacement, required in fields:
        text, count = re.subn(pattern, replacement, text)
        if (required is not None and count != required) or count > 1:
            raise ValueError("Unexpected Xcode project format: " + pattern)
    return text


def self_test():
    old = ('\tobjectVersion = 77;\n'
           '\t\t\tcompatibilityVersion = "Xcode 16.0";\n'
           '\t\t\tpreferredProjectObjectVersion = 77;\n')
    expected = old.replace("77", "56").replace("Xcode 16.0", "Xcode 14.0")
    assert patch(old) == expected
    assert patch(expected) == expected
    assert patch(old.split("\t\t\tpreferred")[0]).endswith('"Xcode 14.0";\n')
    for invalid in ("", old + old, old + "PBXFileSystemSynchronizedRootGroup"):
        try:
            patch(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted an incompatible project")
    print("Project format patch: self-tests passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif not sys.argv[1:]:
        path = ROOT / "QuotaWatch.xcodeproj/project.pbxproj"
        path.write_text(patch(path.read_text()))
        print("Project format: objectVersion 56 / Xcode 14.0 (idempotent)")
    else:
        raise SystemExit("Usage: patch_project.py [--self-test]")
