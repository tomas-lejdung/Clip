#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Clip.xcodeproj/project.pbxproj"
PACKAGE_RESOLUTION="$ROOT/Clip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
WEBRTC_PACKAGE_RESOLUTION="$ROOT/Packages/ClipLiveShareWebRTC/Package.resolved"
CATALOG="$ROOT/Clip/Resources/Localizable.xcstrings"

source "$ROOT/scripts/sparkle-config.sh"
source "$ROOT/scripts/webrtc-config.sh"

fail() {
  echo "Project audit failed: $*" >&2
  exit 1
}

test -f "$PROJECT" || fail "missing $PROJECT"
test -f "$PACKAGE_RESOLUTION" || fail "missing shared Swift package resolution"
[[ "$CLIP_WEBRTC_ARTIFACT_CHECKSUM" =~ ^[0-9a-f]{64}$ ]] \
  || fail "reviewed WebRTC artifact checksum is malformed"
[[ "$CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "reviewed WebRTC macOS payload hash is malformed"
test -f "$WEBRTC_PACKAGE_RESOLUTION" \
  || fail "missing ClipLiveShareWebRTC Swift package resolution"
[[ "$(plutil -extract version raw -o - "$PACKAGE_RESOLUTION")" == "3" ]] \
  || fail "shared Swift package resolution is invalid or unsupported"
[[ "$(plutil -extract version raw -o - "$WEBRTC_PACKAGE_RESOLUTION")" == "3" ]] \
  || fail "ClipLiveShareWebRTC Swift package resolution is invalid or unsupported"
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
[[ "$(plutil -extract 'com\.apple\.security\.network\.server' raw -o - "$ROOT/Clip/Resources/Clip.entitlements")" == "true" ]] \
  || fail "incoming UDP entitlement is required for WebRTC ICE"
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

audit_resolved_pin() {
  local resolution="$1"
  local index="$2"
  local expected_identity="$3"
  local expected_location="$4"
  local expected_revision="$5"
  local expected_version="$6"
  local prefix="pins.$index"

  [[ "$(plutil -extract "$prefix.identity" raw -o - "$resolution")" == \
    "$expected_identity" ]] \
    || fail "$resolution pin $index has an unexpected identity"
  [[ "$(plutil -extract "$prefix.kind" raw -o - "$resolution")" == \
    "remoteSourceControl" ]] \
    || fail "$resolution pin $index is not remote source control"
  [[ "$(plutil -extract "$prefix.location" raw -o - "$resolution")" == \
    "$expected_location" ]] \
    || fail "$resolution pin $index has an unexpected repository"
  [[ "$(plutil -extract "$prefix.state.revision" raw -o - "$resolution")" == \
    "$expected_revision" ]] \
    || fail "$resolution pin $index has an unexpected revision"
  [[ "$(plutil -extract "$prefix.state.version" raw -o - "$resolution")" == \
    "$expected_version" ]] \
    || fail "$resolution pin $index has an unexpected version"
}

[[ "$(plutil -extract pins raw -o - "$PACKAGE_RESOLUTION")" == "2" ]] \
  || fail "shared Swift package resolution must contain only Sparkle and WebRTC"
audit_resolved_pin \
  "$PACKAGE_RESOLUTION" 0 sparkle "$CLIP_SPARKLE_REPOSITORY_URL" \
  "$CLIP_SPARKLE_REVISION" "$CLIP_SPARKLE_VERSION"
audit_resolved_pin \
  "$PACKAGE_RESOLUTION" 1 webrtc "$CLIP_WEBRTC_REPOSITORY_URL.git" \
  "$CLIP_WEBRTC_WRAPPER_REVISION" "$CLIP_WEBRTC_VERSION"
[[ "$(plutil -extract pins raw -o - "$WEBRTC_PACKAGE_RESOLUTION")" == "1" ]] \
  || fail "ClipLiveShareWebRTC resolution must contain only WebRTC"
audit_resolved_pin \
  "$WEBRTC_PACKAGE_RESOLUTION" 0 webrtc "$CLIP_WEBRTC_REPOSITORY_URL.git" \
  "$CLIP_WEBRTC_WRAPPER_REVISION" "$CLIP_WEBRTC_VERSION"

[[ "$(rg -F -c 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' "$PROJECT")" == "2" ]] \
  || fail "AppIcon must be configured for Debug and Release"
rg -F -q 'relativePath = Packages/ClipCore;' "$PROJECT" \
  || fail "ClipCore local package reference is missing"
rg -F -q 'relativePath = Packages/ClipMedia;' "$PROJECT" \
  || fail "ClipMedia local package reference is missing"
rg -F -q 'relativePath = Packages/ClipCapture;' "$PROJECT" \
  || fail "ClipCapture local package reference is missing"
rg -F -q 'relativePath = Packages/ClipLiveShare;' "$PROJECT" \
  || fail "ClipLiveShare local package reference is missing"
rg -F -q 'relativePath = Packages/ClipLiveShareWebRTC;' "$PROJECT" \
  || fail "ClipLiveShareWebRTC local package reference is missing"
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
rg -F -q 'productName = ClipCapture;' "$PROJECT" \
  || fail "ClipCapture product dependency is missing"
rg -F -q 'productName = ClipLiveShare;' "$PROJECT" \
  || fail "ClipLiveShare product dependency is missing"
rg -F -q 'productName = ClipLiveShareWebRTC;' "$PROJECT" \
  || fail "ClipLiveShareWebRTC product dependency is missing"
rg -F -q "\"revision\" : \"$CLIP_WEBRTC_WRAPPER_REVISION\"" \
  "$PACKAGE_RESOLUTION" \
  || fail "WebRTC wrapper resolution is not the reviewed revision"
rg -F -q "\"version\" : \"$CLIP_WEBRTC_VERSION\"" "$PACKAGE_RESOLUTION" \
  || fail "WebRTC shared package resolution is not the reviewed version"
rg -F -q "exact: \"$CLIP_WEBRTC_VERSION\"" \
  "$ROOT/Packages/ClipLiveShareWebRTC/Package.swift" \
  || fail "WebRTC dependency must remain exact"
[[ -f "$ROOT/Clip/Resources/ThirdPartyNotices.txt" ]] \
  || fail "third-party notices are missing"
NOTICES="$ROOT/Clip/Resources/ThirdPartyNotices.txt"
grep -Fq "Source: $CLIP_SPARKLE_REPOSITORY_URL, version $CLIP_SPARKLE_VERSION" \
  "$NOTICES" \
  || fail "Sparkle third-party notice has an unexpected source or version"
grep -Fq "Source revision: $CLIP_SPARKLE_REVISION" "$NOTICES" \
  || fail "Sparkle third-party notice has an unexpected revision"
grep -Fq 'EXTERNAL LICENSES' "$NOTICES" \
  || fail "Sparkle external licenses are missing from third-party notices"
for MARKER in \
  'bspatch.c and bsdiff.c, from bsdiff 4.3' \
  'sais.c and sais.h, from sais-lite' \
  'Portable C implementation of Ed25519' \
  'SUSignatureVerifier.m:'; do
  grep -Fq "$MARKER" "$NOTICES" \
    || fail "Sparkle external license section is missing: $MARKER"
done
grep -Fq "Source: $CLIP_WEBRTC_REPOSITORY_URL, version $CLIP_WEBRTC_VERSION" \
  "$NOTICES" \
  || fail "WebRTC wrapper notice has an unexpected source or version"
grep -Fq "Source revision: $CLIP_WEBRTC_WRAPPER_REVISION" "$NOTICES" \
  || fail "WebRTC wrapper notice has an unexpected revision"
grep -Fq "Source commit: $CLIP_WEBRTC_UPSTREAM_REVISION" "$NOTICES" \
  || fail "Google WebRTC notice has an unexpected upstream revision"
if rg -q -- '--deep' "$ROOT/scripts/package-dmg.sh"; then
  fail "release packaging must never deep-sign Sparkle's sandbox helpers"
fi

echo "Project source, package, plist, entitlement, asset, and localization audit passed."
