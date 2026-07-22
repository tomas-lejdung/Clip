#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_FEED_URL="https://tomas-lejdung.github.io/Clip/appcast.xml"
RELEASE_DOWNLOAD_ROOT="https://github.com/tomas-lejdung/Clip/releases/download"

source "$ROOT/scripts/webrtc-config.sh"

fail() {
  echo "Appcast validation failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: scripts/validate-appcast.sh APPCAST DMG VERSION BUILD

Validates the single-release Sparkle appcast and the Clip.app embedded in its
DMG. VERSION is CFBundleShortVersionString (for example 1.0.1); BUILD is the
strictly increasing CFBundleVersion (for example 2).
EOF
  exit 64
}

[[ $# -eq 4 ]] || usage

APPCAST="$1"
DMG="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD="$4"
MOUNT_ROOT="$ROOT/.build/appcast-validation-mount"

[[ -f "$APPCAST" ]] || fail "appcast does not exist: $APPCAST"
[[ -f "$DMG" ]] || fail "DMG does not exist: $DMG"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "VERSION must use numeric X.Y.Z form"
[[ "$EXPECTED_BUILD" =~ ^[1-9][0-9]*$ ]] \
  || fail "BUILD must be a positive integer"

xmllint --noout "$APPCAST" 2>/dev/null \
  || fail "appcast is not well-formed XML"

xml_value() {
  local expression="$1"
  xmllint --xpath "string($expression)" "$APPCAST" 2>/dev/null
}

xml_count() {
  local expression="$1"
  xmllint --xpath "count($expression)" "$APPCAST" 2>/dev/null
}

[[ "$(xml_count '/rss/channel')" == "1" ]] \
  || fail "appcast must contain exactly one RSS channel"
[[ "$(xml_count '/rss/channel/item')" == "1" ]] \
  || fail "appcast must contain exactly one current release item"
[[ "$(xml_count '/rss/channel/item/enclosure')" == "1" ]] \
  || fail "current release must contain exactly one enclosure"

ENCLOSURE='/rss/channel/item/enclosure'
ITEM='/rss/channel/item'
TOP_LEVEL_BUILD_COUNT="$(xml_count "$ITEM/*[local-name()='version']")"
ATTRIBUTE_BUILD_COUNT="$(xml_count "$ENCLOSURE/@*[local-name()='version']")"
TOP_LEVEL_VERSION_COUNT="$(xml_count "$ITEM/*[local-name()='shortVersionString']")"
ATTRIBUTE_VERSION_COUNT="$(xml_count "$ENCLOSURE/@*[local-name()='shortVersionString']")"

[[ "$((TOP_LEVEL_BUILD_COUNT + ATTRIBUTE_BUILD_COUNT))" == "1" ]] \
  || fail "appcast must express the build exactly once"
[[ "$((TOP_LEVEL_VERSION_COUNT + ATTRIBUTE_VERSION_COUNT))" == "1" ]] \
  || fail "appcast must express the marketing version exactly once"

if [[ "$TOP_LEVEL_BUILD_COUNT" == "1" ]]; then
  APPCAST_BUILD="$(xml_value "$ITEM/*[local-name()='version']")"
else
  APPCAST_BUILD="$(xml_value "$ENCLOSURE/@*[local-name()='version']")"
fi
if [[ "$TOP_LEVEL_VERSION_COUNT" == "1" ]]; then
  APPCAST_VERSION="$(xml_value "$ITEM/*[local-name()='shortVersionString']")"
else
  APPCAST_VERSION="$(xml_value "$ENCLOSURE/@*[local-name()='shortVersionString']")"
fi
APPCAST_URL="$(xml_value "$ENCLOSURE/@url")"
APPCAST_LENGTH="$(xml_value "$ENCLOSURE/@length")"
APPCAST_SIGNATURE="$(xml_value "$ENCLOSURE/@*[local-name()='edSignature']")"
EXPECTED_ASSET_NAME="Clip-$EXPECTED_VERSION.dmg"
EXPECTED_ASSET_URL="$RELEASE_DOWNLOAD_ROOT/v$EXPECTED_VERSION/$EXPECTED_ASSET_NAME"
ACTUAL_DMG_LENGTH="$(stat -f '%z' "$DMG")"

[[ "$APPCAST_BUILD" == "$EXPECTED_BUILD" ]] \
  || fail "appcast build '$APPCAST_BUILD' does not match '$EXPECTED_BUILD'"
[[ "$APPCAST_VERSION" == "$EXPECTED_VERSION" ]] \
  || fail "appcast version '$APPCAST_VERSION' does not match '$EXPECTED_VERSION'"
[[ "$APPCAST_URL" == "$EXPECTED_ASSET_URL" ]] \
  || fail "enclosure URL must be immutable and equal '$EXPECTED_ASSET_URL'"
[[ "$(basename "$DMG")" == "$EXPECTED_ASSET_NAME" ]] \
  || fail "DMG filename must be '$EXPECTED_ASSET_NAME'"
[[ "$APPCAST_LENGTH" == "$ACTUAL_DMG_LENGTH" ]] \
  || fail "enclosure length '$APPCAST_LENGTH' does not match DMG length '$ACTUAL_DMG_LENGTH'"

[[ "$APPCAST_SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
  || fail "enclosure is missing a canonical 64-byte EdDSA signature"

rm -rf "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT"
ENTITLEMENT_DIAGNOSTICS="$(mktemp "$ROOT/.build/appcast-entitlement-diagnostics.XXXXXX")"

cleanup() {
  hdiutil detach "$MOUNT_ROOT" -quiet >/dev/null 2>&1 || true
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
  rm -f "$ENTITLEMENT_DIAGNOSTICS"
}
trap cleanup EXIT

hdiutil verify "$DMG" >/dev/null \
  || fail "DMG checksum verification failed"
hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_ROOT" \
  "$DMG" >/dev/null \
  || fail "DMG could not be mounted"

APP="$MOUNT_ROOT/Clip.app"
INFO="$APP/Contents/Info.plist"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
WEBRTC_FRAMEWORK="$APP/Contents/Frameworks/WebRTC.framework"
WEBRTC_EXECUTABLE="$WEBRTC_FRAMEWORK/Versions/A/WebRTC"
THIRD_PARTY_NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
WEBRTC_THIRD_PARTY_NOTICES="$APP/Contents/Resources/WebRTCThirdPartyNotices.txt"

[[ -d "$APP" ]] || fail "DMG does not contain Clip.app"
[[ -f "$INFO" ]] || fail "packaged Clip.app has no Info.plist"
[[ -d "$SPARKLE_FRAMEWORK" ]] || fail "packaged Clip.app does not embed Sparkle.framework"
[[ -d "$WEBRTC_FRAMEWORK" ]] || fail "packaged Clip.app does not embed WebRTC.framework"
[[ -f "$WEBRTC_EXECUTABLE" ]] || fail "packaged WebRTC runtime is missing"
[[ -f "$THIRD_PARTY_NOTICES" ]] || fail "packaged third-party notices are missing"
[[ -f "$WEBRTC_THIRD_PARTY_NOTICES" ]] \
  || fail "packaged official WebRTC third-party notices are missing"
codesign --verify --strict "$WEBRTC_FRAMEWORK" >/dev/null 2>&1 \
  || fail "packaged WebRTC.framework has an invalid code signature"
[[ "$(lipo -archs "$WEBRTC_EXECUTABLE")" == "arm64" ]] \
  || fail "packaged WebRTC runtime must contain exactly the arm64 architecture"
WEBRTC_NORMALIZED_ARM64_SHA256="$(
  clip_webrtc_normalized_payload_sha256 "$WEBRTC_EXECUTABLE" arm64
)" || fail "could not normalize the packaged WebRTC arm64 payload"
[[ "$WEBRTC_NORMALIZED_ARM64_SHA256" == \
  "$CLIP_WEBRTC_NORMALIZED_ARM64_SHA256" ]] \
  || fail "packaged WebRTC runtime differs from the reviewed arm64 payload"
grep -Fq "Source: $CLIP_WEBRTC_UPSTREAM_REPOSITORY_URL, version $CLIP_WEBRTC_VERSION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected upstream source or version"
grep -Fq "Source commit: $CLIP_WEBRTC_UPSTREAM_REVISION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected upstream revision"
grep -Fq "Clip binary artifact: $CLIP_WEBRTC_ARTIFACT_URL" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected Clip binary artifact"
grep -Fq "Clip patch SHA-256: $CLIP_WEBRTC_PATCH_SHA256" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected Clip patch hash"
[[ "$(shasum -a 256 "$WEBRTC_THIRD_PARTY_NOTICES" | awk '{print $1}')" == \
  "$CLIP_WEBRTC_LICENSE_SHA256" ]] \
  || fail "official WebRTC third-party notices differ from the reviewed file"
for MARKER in '# webrtc' '# libaom' '# libvpx' '# opus'; do
  grep -Fq "$MARKER" "$WEBRTC_THIRD_PARTY_NOTICES" \
    || fail "official WebRTC third-party notices are missing: $MARKER"
done
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  || fail "packaged Clip.app has an invalid code signature"

plist_value() {
  plutil -extract "$1" raw -o - "$INFO" 2>/dev/null
}

PACKAGED_VERSION="$(plist_value CFBundleShortVersionString)"
PACKAGED_BUILD="$(plist_value CFBundleVersion)"
PACKAGED_FEED_URL="$(plist_value SUFeedURL)"
PACKAGED_PUBLIC_KEY="$(plist_value SUPublicEDKey)"
INSTALLER_SERVICE_ENABLED="$(plist_value SUEnableInstallerLauncherService)"

[[ "$PACKAGED_VERSION" == "$EXPECTED_VERSION" ]] \
  || fail "packaged app version '$PACKAGED_VERSION' does not match '$EXPECTED_VERSION'"
[[ "$PACKAGED_BUILD" == "$EXPECTED_BUILD" ]] \
  || fail "packaged app build '$PACKAGED_BUILD' does not match '$EXPECTED_BUILD'"
[[ "$PACKAGED_FEED_URL" == "$EXPECTED_FEED_URL" ]] \
  || fail "packaged app feed URL must equal '$EXPECTED_FEED_URL'"
[[ "$INSTALLER_SERVICE_ENABLED" == "true" ]] \
  || fail "sandboxed Sparkle installer service is not enabled"
[[ "$PACKAGED_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "packaged app has no canonical 32-byte EdDSA public key"

SIGNATURE_VERIFIER="$ROOT/scripts/verify-sparkle-signature.swift"
[[ -f "$SIGNATURE_VERIFIER" ]] \
  || fail "public-key signature verifier is missing"
mkdir -p "$ROOT/.build/ModuleCache"
if ! xcrun swift \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$SIGNATURE_VERIFIER" \
    "$DMG" \
    "$PACKAGED_PUBLIC_KEY" \
    "$APPCAST_SIGNATURE" >/dev/null; then
  fail "enclosure signature does not verify with Clip's embedded public key"
fi

if ! ENTITLEMENTS="$(
  codesign -d --entitlements - --xml "$APP" 2>"$ENTITLEMENT_DIAGNOSTICS"
)"; then
  fail "packaged app entitlements could not be read"
fi
if grep -Fq 'invalid entitlements blob' "$ENTITLEMENT_DIAGNOSTICS"; then
  fail "codesign reports an invalid packaged entitlement blob"
fi
NETWORK_CLIENT="$(
  plutil -extract 'com\.apple\.security\.network\.client' raw -o - - \
    <<<"$ENTITLEMENTS" 2>/dev/null || true
)"
[[ "$NETWORK_CLIENT" == "true" ]] \
  || fail "packaged app lacks the outgoing-network sandbox entitlement"
NETWORK_SERVER="$(
  plutil -extract 'com\.apple\.security\.network\.server' raw -o - - \
    <<<"$ENTITLEMENTS" 2>/dev/null || true
)"
[[ "$NETWORK_SERVER" == "true" ]] \
  || fail "packaged app lacks the incoming-network sandbox entitlement"
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.get-task-allow' \
    /dev/stdin <<<"$ENTITLEMENTS" >/dev/null 2>&1; then
  fail "packaged app contains com.apple.security.get-task-allow"
fi
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.cs.disable-library-validation' \
    /dev/stdin <<<"$ENTITLEMENTS" >/dev/null 2>&1; then
  fail "published updates must retain Hardened Runtime library validation"
fi

for SERVICE in \
  "com.tomaslejdung.clip-spks" \
  "com.tomaslejdung.clip-spki"; do
  grep -Fq "<string>$SERVICE</string>" <<<"$ENTITLEMENTS" \
    || fail "packaged app lacks Sparkle Mach lookup entitlement '$SERVICE'"
done

echo "Validated Sparkle appcast and packaged update: $EXPECTED_VERSION ($EXPECTED_BUILD)"
