#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1
APP=build/Build/Products/Release-iphoneos/QuotaWatch.app
EXT="$APP/PlugIns/QuotaWatchWidget.appex"
NAME=$(python3 -c 'import sys; sys.path.insert(0,"scripts"); from check_project import NAME, VERSION; print(NAME + "-" + VERSION)')
test -d "$APP"
test -d "$EXT"
# Sign nested code first; signing the containing app without --deep preserves this signature.
codesign --force --sign - --entitlements QuotaWatchWidget/QuotaWatchWidget.entitlements "$EXT"
# Use Apple's native ad-hoc signer so CodeResources and codesign verification agree.
# This needs no developer certificate; ldid remains a read-only entitlement inspector.
codesign --force --sign - --entitlements QuotaWatch/QuotaWatch.entitlements "$APP"
python3 scripts/verify_bundle.py "$APP"
rm -rf dist/Payload dist/verify
mkdir -p dist/Payload
# ditto preserves executable modes and bundle structure; no extended attributes.
ditto --norsrc --noextattr "$APP" dist/Payload/QuotaWatch.app
rm -f "dist/$NAME.ipa" "dist/$NAME.ipa.sha256"
(
  cd dist
  zip -qry "$NAME.ipa" Payload
  unzip -t "$NAME.ipa"
  mkdir verify
  unzip -q "$NAME.ipa" -d verify
)
python3 scripts/verify_bundle.py dist/verify/Payload/QuotaWatch.app
(
  cd dist
  shasum -a 256 "$NAME.ipa" > "$NAME.ipa.sha256"
  shasum -a 256 -c "$NAME.ipa.sha256"
)
rm -rf dist/Payload dist/verify
printf 'Packaged dist/%s.ipa and matching SHA256\n' "$NAME"
