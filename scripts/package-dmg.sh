#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Clip.app"
PACKAGE_ROOT="$ROOT/.build/package"
STAGING="$PACKAGE_ROOT/staging"
OUTPUT="${CLIP_DMG_PATH:-$ROOT/.build/Clip.dmg}"
DESIGNATED_REQUIREMENT_SIDECAR="$OUTPUT.designated-requirement"

source "$ROOT/scripts/signing-config.sh"
clip_warn_if_ad_hoc_signing

if [[ "${CLIP_MANUAL_BUILD:-0}" == "1" ]]; then
  CLIP_SUPPRESS_AD_HOC_SIGNING_WARNING=1 \
    "$ROOT/scripts/build-manual-app.sh"
  APP="$ROOT/.build/Manual/Clip.app"
else
  CLIP_SUPPRESS_AD_HOC_SIGNING_WARNING=1 \
    "$ROOT/scripts/build.sh" Release
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

# Reapply the configured signature without stripping the production
# sandbox entitlements or Hardened Runtime from the assembled bundle.
codesign \
  --force \
  --deep \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT/Clip/Resources/Clip.entitlements" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

DESIGNATED_REQUIREMENT="$(clip_designated_requirement "$APP")"
if [[ -z "$DESIGNATED_REQUIREMENT" ]]; then
  echo "Could not read Clip.app's designated requirement" >&2
  exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Clip.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$DESIGNATED_REQUIREMENT_SIDECAR"
hdiutil create \
  -volname "Clip" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$OUTPUT"

printf '%s\n' "$DESIGNATED_REQUIREMENT" > "$DESIGNATED_REQUIREMENT_SIDECAR"

echo "$OUTPUT"
echo "Designated requirement: $DESIGNATED_REQUIREMENT" >&2
echo "Recorded requirement: $DESIGNATED_REQUIREMENT_SIDECAR" >&2
