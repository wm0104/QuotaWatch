#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
case "${1:-}" in
  ''|--source-only) ;;
  *) echo 'Usage: scripts/test.sh [--source-only]' >&2; exit 2 ;;
esac
python3 scripts/check_project.py
python3 scripts/generate_icons.py --check
python3 scripts/patch_project.py --self-test
python3 scripts/check_widget_probe.py --self-test
python3 scripts/verify_widget_probe.py --self-test
# Source/security guards must run even on hosts without an Apple toolchain.
for check in Tests/*.py; do
  python3 "$check"
done
if [[ "${1:-}" == --source-only ]]; then
  echo 'SOURCE ONLY: Swift fixtures and iOS compilation NOT executed.'
  exit 0
fi
command -v xcrun >/dev/null || { echo 'Apple xcrun required for mandatory Swift fixtures.' >&2; exit 1; }
CACHE=$(mktemp -d "${TMPDIR:-/tmp}/quotawatch-tests.XXXXXX")
trap 'rm -rf "$CACHE"' EXIT
xcrun swiftc -swift-version 5 \
  QuotaWatch/Models.swift QuotaWatch/QuotaParser.swift QuotaWatch/QuotaDisplayRules.swift Tests/main.swift \
  -o "$CACHE/quotawatch-core-tests"
"$CACHE/quotawatch-core-tests"
xcrun swiftc -swift-version 5 -parse-as-library \
  QuotaWatch/Models.swift QuotaWatch/QuotaDisplayRules.swift QuotaWatch/ResetNotificationPlanner.swift Tests/reset_main.swift \
  -o "$CACHE/quotawatch-reset-tests"
"$CACHE/quotawatch-reset-tests"
