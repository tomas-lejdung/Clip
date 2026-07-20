#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-$ROOT/.build/Clip.dmg}"
MOUNT_ROOT="$ROOT/.build/dmg-mount"
DESIGNATED_REQUIREMENT_SIDECAR="$DMG.designated-requirement"

source "$ROOT/scripts/signing-config.sh"
source "$ROOT/scripts/version-config.sh"
source "$ROOT/scripts/sparkle-config.sh"
source "$ROOT/scripts/webrtc-config.sh"

fail() {
  echo "DMG verification failed: $*" >&2
  exit 1
}

if [[ ! -f "$DMG" ]]; then
  echo "DMG does not exist: $DMG" >&2
  exit 66
fi

hdiutil verify "$DMG" >/dev/null

rm -rf "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT"
ENTITLEMENT_DIAGNOSTICS="$(mktemp "$ROOT/.build/dmg-entitlement-diagnostics.XXXXXX")"

cleanup() {
  hdiutil detach "$MOUNT_ROOT" -quiet || true
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
  rm -f "$ENTITLEMENT_DIAGNOSTICS"
}
trap cleanup EXIT

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_ROOT" \
  "$DMG"

test -d "$MOUNT_ROOT/Clip.app" || fail "Clip.app is missing"
test -L "$MOUNT_ROOT/Applications" || fail "Applications shortcut is missing"
[[ "$(readlink "$MOUNT_ROOT/Applications")" == "/Applications" ]] \
  || fail "Applications shortcut does not target /Applications"
APP="$MOUNT_ROOT/Clip.app"
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/Clip"

codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$INFO"
test -x "$EXECUTABLE" || fail "Clip executable is missing or not executable"
file "$EXECUTABLE" | grep -q "Mach-O 64-bit executable arm64" \
  || fail "Clip executable is not an arm64 Mach-O"
test -f "$APP/Contents/Resources/Assets.car" || fail "compiled asset catalog is missing"
test -f "$APP/Contents/Resources/AppIcon.icns" || fail "compiled app icon is missing"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
test -d "$SPARKLE_FRAMEWORK" || fail "Sparkle.framework is missing"
SPARKLE_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - \
    "$SPARKLE_FRAMEWORK/Versions/Current/Resources/Info.plist"
)"
[[ "$SPARKLE_VERSION" == "$CLIP_SPARKLE_VERSION" ]] \
  || fail "unexpected embedded Sparkle version '$SPARKLE_VERSION'"
for COMPONENT in \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/Current/Updater.app" \
  "$SPARKLE_FRAMEWORK"; do
  codesign --verify --strict "$COMPONENT" \
    || fail "embedded Sparkle component has an invalid signature: $COMPONENT"
done
WEBRTC_FRAMEWORK="$APP/Contents/Frameworks/WebRTC.framework"
WEBRTC_EXECUTABLE="$WEBRTC_FRAMEWORK/Versions/A/WebRTC"
test -d "$WEBRTC_FRAMEWORK" || fail "WebRTC.framework is missing"
test -f "$WEBRTC_EXECUTABLE" || fail "WebRTC executable is missing"
codesign --verify --strict "$WEBRTC_FRAMEWORK" \
  || fail "embedded WebRTC.framework has an invalid signature"
file "$WEBRTC_EXECUTABLE" | grep -q 'arm64' \
  || fail "embedded WebRTC runtime has no arm64 slice"
WEBRTC_IDENTIFIER="$(
  plutil -extract CFBundleIdentifier raw -o - \
    "$WEBRTC_FRAMEWORK/Versions/A/Resources/Info.plist"
)"
[[ "$WEBRTC_IDENTIFIER" == "org.webrtc.WebRTC" ]] \
  || fail "embedded WebRTC framework has an unexpected bundle identifier"

THIRD_PARTY_NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
test -f "$THIRD_PARTY_NOTICES" || fail "third-party notices are missing"
grep -Fq "Source: $CLIP_SPARKLE_REPOSITORY_URL, version $CLIP_SPARKLE_VERSION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged Sparkle notice has an unexpected source or version"
grep -Fq "Source revision: $CLIP_SPARKLE_REVISION" "$THIRD_PARTY_NOTICES" \
  || fail "packaged Sparkle notice has an unexpected revision"
grep -Fq 'EXTERNAL LICENSES' "$THIRD_PARTY_NOTICES" \
  || fail "packaged Sparkle external licenses are missing"
for MARKER in \
  'bspatch.c and bsdiff.c, from bsdiff 4.3' \
  'sais.c and sais.h, from sais-lite' \
  'Portable C implementation of Ed25519' \
  'SUSignatureVerifier.m:'; do
  grep -Fq "$MARKER" "$THIRD_PARTY_NOTICES" \
    || fail "packaged Sparkle external license section is missing: $MARKER"
done
grep -Fq "Source: $CLIP_WEBRTC_REPOSITORY_URL, version $CLIP_WEBRTC_VERSION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected source or version"
grep -Fq "Source revision: $CLIP_WEBRTC_WRAPPER_REVISION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected wrapper revision"
grep -Fq "Source commit: $CLIP_WEBRTC_UPSTREAM_REVISION" \
  "$THIRD_PARTY_NOTICES" \
  || fail "packaged WebRTC notice has an unexpected upstream revision"

INFO_XML="$(plutil -convert xml1 -o - "$INFO")"
if grep -Fq '$(' <<<"$INFO_XML"; then
  echo "Packaged Info.plist contains an unresolved Xcode build setting" >&2
  exit 1
fi

if ! ENTITLEMENTS="$(
  codesign -d --entitlements - --xml "$APP" 2>"$ENTITLEMENT_DIAGNOSTICS"
)"; then
  fail "could not read packaged app entitlements"
fi
if grep -Fq 'invalid entitlements blob' "$ENTITLEMENT_DIAGNOSTICS"; then
  fail "codesign reports an invalid packaged entitlement blob"
fi
for KEY in \
  com.apple.security.app-sandbox \
  com.apple.security.device.audio-input \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.network.client \
  com.apple.security.network.server; do
  VALUE=""
  if ! VALUE="$(
    /usr/libexec/PlistBuddy -c "Print :$KEY" /dev/stdin \
      <<<"$ENTITLEMENTS" 2>/dev/null
  )" || [[ "$VALUE" != "true" ]]; then
    fail "required entitlement '$KEY' is missing or false"
  fi
done
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.get-task-allow' \
    /dev/stdin <<<"$ENTITLEMENTS" >/dev/null 2>&1; then
  fail "distributed app contains com.apple.security.get-task-allow"
fi
if grep -Fq '$(' <<<"$ENTITLEMENTS"; then
  fail "packaged entitlements contain an unresolved build setting"
fi
for SERVICE in \
  com.tomaslejdung.clip-spks \
  com.tomaslejdung.clip-spki; do
  grep -Fq "<string>$SERVICE</string>" <<<"$ENTITLEMENTS" \
    || fail "required Sparkle Mach lookup entitlement '$SERVICE' is missing"
done

SIGNATURE_INFO="$(codesign -dvvv "$APP" 2>&1)"
grep -q "flags=.*runtime" <<<"$SIGNATURE_INFO" || fail "Hardened Runtime is missing"

DESIGNATED_REQUIREMENT="$(clip_designated_requirement "$APP")"
[[ -n "$DESIGNATED_REQUIREMENT" ]] || fail "designated requirement is missing"

if clip_signing_is_ad_hoc; then
  grep -q "Signature=adhoc" <<<"$SIGNATURE_INFO" || fail "signature is not ad-hoc"
  grep -q "TeamIdentifier=not set" <<<"$SIGNATURE_INFO" || fail "unexpected Team ID"
  [[ "$DESIGNATED_REQUIREMENT" == "designated => cdhash "* ]] \
    || fail "ad-hoc signature does not have a build-specific cdhash requirement"
else
  if grep -q "Signature=adhoc" <<<"$SIGNATURE_INFO"; then
    fail "requested stable identity '$CLIP_CODE_SIGN_IDENTITY' produced an ad-hoc signature"
  fi

  LEAF_AUTHORITY="$(awk -F= '/^Authority=/{sub(/^Authority=/, ""); print; exit}' <<<"$SIGNATURE_INFO")"
  [[ -n "$LEAF_AUTHORITY" ]] || fail "stable signature has no leaf signer"

  if clip_signing_identity_is_sha1; then
    REQUESTED_CERTIFICATE_SHA1="$(clip_normalized_signing_identity_sha1)"
    EMBEDDED_CERTIFICATE_SHA1="$(clip_embedded_leaf_certificate_sha1 "$APP")" \
      || fail "could not extract the embedded leaf signing certificate"
    [[ "$EMBEDDED_CERTIFICATE_SHA1" == "$REQUESTED_CERTIFICATE_SHA1" ]] \
      || fail "embedded leaf certificate '$EMBEDDED_CERTIFICATE_SHA1' does not match requested identity '$REQUESTED_CERTIFICATE_SHA1'"
  else
    [[ "$LEAF_AUTHORITY" == "$CLIP_CODE_SIGN_IDENTITY" ]] \
      || fail "leaf signer '$LEAF_AUTHORITY' does not match requested identity '$CLIP_CODE_SIGN_IDENTITY'"
  fi

  [[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] \
    || fail "requested stable identity produced a build-specific cdhash requirement"
fi

[[ -f "$DESIGNATED_REQUIREMENT_SIDECAR" ]] \
  || fail "designated-requirement sidecar is missing"
RECORDED_DESIGNATED_REQUIREMENT="$(<"$DESIGNATED_REQUIREMENT_SIDECAR")"
[[ -n "$RECORDED_DESIGNATED_REQUIREMENT" ]] \
  || fail "recorded designated requirement is empty"
[[ "$DESIGNATED_REQUIREMENT" == "$RECORDED_DESIGNATED_REQUIREMENT" ]] \
  || fail "packaged designated requirement differs from the recorded signing requirement"

IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO")"
NAME="$(plutil -extract CFBundleName raw -o - "$INFO")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$INFO")"
BUNDLE_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$INFO")"
PACKAGE_TYPE="$(plutil -extract CFBundlePackageType raw -o - "$INFO")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
MINIMUM_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO")"
MENU_BAR_ONLY="$(plutil -extract LSUIElement raw -o - "$INFO")"
COPYRIGHT="$(plutil -extract NSHumanReadableCopyright raw -o - "$INFO")"
MICROPHONE_USAGE="$(plutil -extract NSMicrophoneUsageDescription raw -o - "$INFO")"
SYSTEM_AUDIO_USAGE="$(plutil -extract NSAudioCaptureUsageDescription raw -o - "$INFO")"
SCREEN_CAPTURE_USAGE="$(plutil -extract NSScreenCaptureUsageDescription raw -o - "$INFO")"
AUTOMATIC_UPDATE_CHECKS="$(plutil -extract SUEnableAutomaticChecks raw -o - "$INFO")"
INSTALLER_SERVICE="$(plutil -extract SUEnableInstallerLauncherService raw -o - "$INFO")"
UPDATE_FEED="$(plutil -extract SUFeedURL raw -o - "$INFO")"
UPDATE_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO")"

[[ "$IDENTIFIER" == "com.tomaslejdung.clip" ]] || fail "unexpected bundle identifier"
[[ "$NAME" == "Clip" ]] || fail "unexpected bundle name"
[[ "$DISPLAY_NAME" == "Clip" ]] || fail "unexpected display name"
[[ "$BUNDLE_EXECUTABLE" == "Clip" ]] || fail "unexpected bundle executable"
[[ "$PACKAGE_TYPE" == "APPL" ]] || fail "unexpected bundle package type"
[[ "$VERSION" == "$CLIP_MARKETING_VERSION" ]] \
  || fail "marketing version '$VERSION' does not match '$CLIP_MARKETING_VERSION'"
[[ "$BUILD" == "$CLIP_BUILD_VERSION" ]] \
  || fail "build number '$BUILD' does not match '$CLIP_BUILD_VERSION'"
[[ "$MINIMUM_SYSTEM" == "15.0" ]] || fail "unexpected minimum macOS version"
[[ "$MENU_BAR_ONLY" == "true" ]] || fail "Clip is not configured as a menu-bar app"
[[ "$COPYRIGHT" == "Copyright © 2026 Tomas Lejdung. All rights reserved." ]] \
  || fail "unexpected copyright owner"
[[ -n "$MICROPHONE_USAGE" ]] || fail "microphone usage description is missing"
[[ -n "$SYSTEM_AUDIO_USAGE" ]] || fail "system-audio usage description is missing"
[[ -n "$SCREEN_CAPTURE_USAGE" ]] || fail "screen-capture usage description is missing"
[[ "$AUTOMATIC_UPDATE_CHECKS" == "true" ]] \
  || fail "automatic update checks are not enabled"
[[ "$INSTALLER_SERVICE" == "true" ]] \
  || fail "Sparkle installer service is not enabled"
[[ "$UPDATE_FEED" == "https://tomas-lejdung.github.io/Clip/appcast.xml" ]] \
  || fail "unexpected Sparkle feed URL"
[[ "$UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "Sparkle public key is missing or malformed"

echo "Verified $DMG"
echo "Signing identity: $CLIP_CODE_SIGN_IDENTITY"
if [[ -n "${LEAF_AUTHORITY:-}" ]]; then
  echo "Leaf signer: $LEAF_AUTHORITY"
fi
echo "Designated requirement: $DESIGNATED_REQUIREMENT"
