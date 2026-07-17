#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Clip.xcodeproj/project.pbxproj"
CATALOG="$ROOT/Clip/Resources/Localizable.xcstrings"

fail() {
  echo "Project audit failed: $*" >&2
  exit 1
}

test -f "$PROJECT" || fail "missing $PROJECT"
plutil -lint "$ROOT/Clip/Resources/Info.plist" >/dev/null
plutil -lint "$ROOT/Clip/Resources/Clip.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "system-audio privacy usage description is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "microphone privacy usage description is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$ROOT/Clip/Resources/Info.plist")" != "" ]] \
  || fail "screen-capture privacy usage description is missing"
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

echo "Project source, package, plist, entitlement, asset, and localization audit passed."
