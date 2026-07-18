#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANUAL_BUILD="$ROOT/.build/Manual"
APP="$MANUAL_BUILD/Clip.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
PARTIAL_INFO="$MANUAL_BUILD/asset-info.plist"

source "$ROOT/scripts/signing-config.sh"
source "$ROOT/scripts/version-config.sh"
clip_warn_if_ad_hoc_signing

"$ROOT/scripts/typecheck.sh"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES"
ditto "$MANUAL_BUILD/Clip" "$CONTENTS/MacOS/Clip"
ditto "$ROOT/Clip/Resources/Info.plist" "$CONTENTS/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Clip" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tomaslejdung.clip" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Clip" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CLIP_MARKETING_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CLIP_BUILD_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$CONTENTS/Info.plist"

xcrun actool "$ROOT/Clip/Resources/Assets.xcassets" \
  --compile "$RESOURCES" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --target-device mac \
  --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL_INFO" >/dev/null

/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$CONTENTS/Info.plist"

xcrun xcstringstool compile "$ROOT/Clip/Resources/Localizable.xcstrings" \
  --output-directory "$RESOURCES"

codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT/Clip/Resources/Clip.entitlements" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$CONTENTS/Info.plist"

INFO_XML="$(plutil -convert xml1 -o - "$CONTENTS/Info.plist")"
if grep -Fq '$(' <<<"$INFO_XML"; then
  echo "Manual app Info.plist contains an unresolved Xcode build setting" >&2
  exit 1
fi

echo "$APP"
