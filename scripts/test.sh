#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_project.py
python3 scripts/generate_icons.py --check
python3 scripts/patch_project.py --self-test
mkdir -p build/tests
xcrun swiftc -swift-version 5 \
  QuotaWatch/Models.swift QuotaWatch/QuotaParser.swift QuotaWatch/QuotaDisplayRules.swift Tests/main.swift \
  -o build/tests/quotawatch-core-tests
build/tests/quotawatch-core-tests
# Source checks are optional while core tests are mandatory.
for check in Tests/*.py; do
  if [[ -f "$check" ]]; then
    python3 "$check"
  fi
done
