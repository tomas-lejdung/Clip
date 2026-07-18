#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Clip.xcodeproj/project.pbxproj"
PACKAGE_RESOLUTION="$ROOT/Clip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CATALOG="$ROOT/Clip/Resources/Localizable.xcstrings"

source "$ROOT/scripts/sparkle-config.sh"

fail() {
  echo "Project audit failed: $*" >&2
  exit 1
}

test -f "$PROJECT" || fail "missing $PROJECT"
test -f "$PACKAGE_RESOLUTION" || fail "missing shared Swift package resolution"
plutil -lint "$ROOT/Clip/Resources/Info.plist" >/dev/null
plutil -lint "$ROOT/Clip/Resources/Clip.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "system-audio privacy usage description is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "microphone privacy usage description is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "screen-capture privacy usage description is missing"
[[ "$(plutil -extract SUFeedURL raw -o - "$ROOT/Clip/Resources/Info.plist")" == \
  "https://tomas-lejdung.github.io/Clip/appcast.xml" ]] \
  || fail "Sparkle feed URL is missing or unexpected"
[[ "$(plutil -extract SUEnableAutomaticChecks raw -o - "$ROOT/Clip/Resources/Info.plist")" == "true" ]] \
  || fail "automatic update checks are not enabled"
[[ "$(plutil -extract SUEnableInstallerLauncherService raw -o - "$ROOT/Clip/Resources/Info.plist")" == "true" ]] \
  || fail "Sparkle's sandbox installer service is not enabled"
SPARKLE_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$ROOT/Clip/Resources/Info.plist")"
[[ "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "Sparkle EdDSA public key is missing or malformed"
[[ "$(plutil -extract 'com\.apple\.security\.network\.client' raw -o - "$ROOT/Clip/Resources/Clip.entitlements")" == "true" ]] \
  || fail "outgoing network entitlement is required for updates"
MACH_LOOKUP_ENTITLEMENTS="$(
  plutil -extract 'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name' \
    xml1 -o - "$ROOT/Clip/Resources/Clip.entitlements"
)"
grep -Fq '<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>' \
  <<<"$MACH_LOOKUP_ENTITLEMENTS" \
  || fail "Sparkle installer-status Mach lookup entitlement is missing"
grep -Fq '<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>' \
  <<<"$MACH_LOOKUP_ENTITLEMENTS" \
  || fail "Sparkle installer-connection Mach lookup entitlement is missing"
for json in \
  "$ROOT/Clip/Resources/Assets.xcassets/Contents.json" \
  "$ROOT/Clip/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" \
  "$ROOT/Clip/Resources/Assets.xcassets/MenuBarIcon.imageset/Contents.json"; do
  plutil -convert xml1 -o /dev/null "$json" || fail "invalid JSON: $json"
done
[[ "$(plutil -extract sourceLanguage raw -o - "$CATALOG")" == "en" ]] \
  || fail "English String Catalog must use English as its source language"
[[ -n "$(plutil -extract strings raw -o - "$CATALOG")" ]] \
  || fail "English String Catalog must contain extracted source keys"
xcrun xcstringstool print "$CATALOG" >/dev/null \
  || fail "English String Catalog is invalid"

audit_source_tree() {
  local source_root="$1"
  local expected_count=0

  while IFS= read -r source; do
    local name
    local reference_count
    local source_phase_mentions
    name="$(basename "$source")"
    reference_count="$(rg -F -c "path = $name;" "$PROJECT" || true)"
    source_phase_mentions="$(rg -F -c "$name in Sources" "$PROJECT" || true)"
    [[ "$reference_count" == "1" ]] \
      || fail "$source must have exactly one PBXFileReference (found $reference_count)"
    [[ "$source_phase_mentions" -ge 2 ]] \
      || fail "$source is not present in a Sources build phase"
    expected_count=$((expected_count + 1))
  done < <(rg --files "$source_root" -g '*.swift' | sort)

  [[ "$expected_count" -gt 0 ]] || fail "no Swift sources found below $source_root"
}

audit_source_tree "$ROOT/Clip"
audit_source_tree "$ROOT/ClipTests"
audit_source_tree "$ROOT/ClipUITests"
audit_source_tree "$ROOT/ClipTestHelper"

[[ "$(rg -F -c 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' "$PROJECT")" == "2" ]] \
  || fail "AppIcon must be configured for Debug and Release"
rg -F -q 'relativePath = Packages/ClipCore;' "$PROJECT" \
  || fail "ClipCore local package reference is missing"
rg -F -q 'relativePath = Packages/ClipMedia;' "$PROJECT" \
  || fail "ClipMedia local package reference is missing"
rg -F -q "repositoryURL = \"$CLIP_SPARKLE_REPOSITORY_URL\";" "$PROJECT" \
  || fail "Sparkle package reference is missing"
rg -F -q "version = $CLIP_SPARKLE_VERSION;" "$PROJECT" \
  || fail "Sparkle must remain pinned to the reviewed release"
rg -F -q "\"revision\" : \"$CLIP_SPARKLE_REVISION\"" \
  "$PACKAGE_RESOLUTION" \
  || fail "Sparkle resolution must remain pinned to the reviewed 2.9.4 revision"
rg -F -q "\"version\" : \"$CLIP_SPARKLE_VERSION\"" "$PACKAGE_RESOLUTION" \
  || fail "Sparkle shared package resolution must remain at 2.9.4"
rg -F -q 'productName = Sparkle;' "$PROJECT" \
  || fail "Sparkle product dependency is missing"
if rg -q -- '--deep' "$ROOT/scripts/package-dmg.sh"; then
  fail "release packaging must never deep-sign Sparkle's sandbox helpers"
fi

echo "Project source, package, plist, entitlement, asset, and localization audit passed."
