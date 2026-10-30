#!/usr/bin/env bash
# Native ad-hoc signatures are for independent compatibility probing, not App Store distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1
mkdir -p build/widgetprobe
exec > >(tee build/widgetprobe-build.log) 2>&1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_15.4.app/Contents/Developer}"
for tool in xcodegen ldid rg python3 codesign ditto zip shasum; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool (brew install xcodegen ldid ripgrep)"; exit 1; }
done
test -d "$DEVELOPER_DIR"
xcodebuild -version | rg -x 'Xcode 15\.4'
xcrun swiftc --version
python3 scripts/check_widget_probe.py --self-test
python3 scripts/verify_widget_probe.py --self-test
# No probe sources are inspected until this build starts. Copy validated, distinct
# source entitlements to build-only files; never borrow main-app entitlements.
python3 - <<'PY'
import shutil
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from check_widget_probe import PRODUCTS, source_check
files = source_check()
for name, bundle_id in PRODUCTS.items():
    shutil.copyfile(files[bundle_id], Path('build/widgetprobe') / (name + '.entitlements'))
PY
xcrun swiftc -swift-version 5 WidgetProbe/Shared/*.swift WidgetProbe/Tests/main.swift \
  -o build/widgetprobe/core-tests
build/widgetprobe/core-tests
(
  cd WidgetProbe
  xcodegen generate --spec project.yml
)
# Reuse only the patch function: its CLI deliberately addresses the main app.
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from patch_project import patch
path = Path('WidgetProbe/QuotaProbe.xcodeproj/project.pbxproj')
path.write_text(patch(path.read_text()))
PY
plutil -lint WidgetProbe/QuotaProbe.xcodeproj/project.pbxproj
rg -x '[[:space:]]*objectVersion = 56;' WidgetProbe/QuotaProbe.xcodeproj/project.pbxproj
xcodebuild -project WidgetProbe/QuotaProbe.xcodeproj -alltargets -configuration Release \
  -sdk iphoneos -showBuildSettings -json > build/widgetprobe/build-settings.json
python3 scripts/check_widget_probe.py --build-settings build/widgetprobe/build-settings.json
xcodebuild \
  -project WidgetProbe/QuotaProbe.xcodeproj \
  -scheme QuotaProbe \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/build/widgetprobe" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' build
APP=build/widgetprobe/Build/Products/Release-iphoneos/QuotaProbe.app
EXT="$APP/PlugIns/QuotaProbeWidget.appex"
test -d "$APP" && test -d "$EXT"
# Inside out: never --deep sign and never ldid sign.
codesign --force --sign - --entitlements build/widgetprobe/QuotaProbeWidget.entitlements "$EXT"
codesign --force --sign - --entitlements build/widgetprobe/QuotaProbe.entitlements "$APP"
python3 scripts/verify_widget_probe.py "$APP"
mkdir -p dist-widgetprobe
STAGE=$(mktemp -d "$PWD/build/widgetprobe/package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
ditto --norsrc --noextattr "$APP" "$STAGE/Payload/QuotaProbe.app"
IPA="$PWD/dist-widgetprobe/QuotaProbe-0.1.0.ipa"
rm -f "$IPA" "$IPA.sha256"
(cd "$STAGE" && zip -qry "$IPA" Payload)
python3 scripts/verify_widget_probe.py "$IPA"
(
  cd dist-widgetprobe
  shasum -a 256 QuotaProbe-0.1.0.ipa > QuotaProbe-0.1.0.ipa.sha256
  shasum -a 256 -c QuotaProbe-0.1.0.ipa.sha256
)
echo 'Packaged independent dist-widgetprobe/QuotaProbe-0.1.0.ipa and SHA256'
