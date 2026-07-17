#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-$ROOT/.build/Clip.dmg}"
MOUNT_ROOT="$ROOT/.build/dmg-mount"
DESIGNATED_REQUIREMENT_SIDECAR="$DMG.designated-requirement"

source "$ROOT/scripts/signing-config.sh"

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

cleanup() {
  hdiutil detach "$MOUNT_ROOT" -quiet || true
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
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

INFO_XML="$(plutil -convert xml1 -o - "$INFO")"
if grep -Fq '$(' <<<"$INFO_XML"; then
  echo "Packaged Info.plist contains an unresolved Xcode build setting" >&2
  exit 1
fi

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
for KEY in \
  com.apple.security.app-sandbox \
  com.apple.security.device.audio-input \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope; do
  VALUE=""
  if ! VALUE="$(
    /usr/libexec/PlistBuddy -c "Print :$KEY" /dev/stdin \
      <<<"$ENTITLEMENTS" 2>/dev/null
  )" || [[ "$VALUE" != "true" ]]; then
    fail "required entitlement '$KEY' is missing or false"
  fi
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

[[ "$IDENTIFIER" == "com.tomaslejdung.clip" ]] || fail "unexpected bundle identifier"
[[ "$NAME" == "Clip" ]] || fail "unexpected bundle name"
[[ "$DISPLAY_NAME" == "Clip" ]] || fail "unexpected display name"
[[ "$BUNDLE_EXECUTABLE" == "Clip" ]] || fail "unexpected bundle executable"
[[ "$PACKAGE_TYPE" == "APPL" ]] || fail "unexpected bundle package type"
[[ "$VERSION" == "1.0.0" ]] || fail "unexpected marketing version"
[[ "$BUILD" == "1" ]] || fail "unexpected build number"
[[ "$MINIMUM_SYSTEM" == "15.0" ]] || fail "unexpected minimum macOS version"
[[ "$MENU_BAR_ONLY" == "true" ]] || fail "Clip is not configured as a menu-bar app"
[[ "$COPYRIGHT" == "Copyright © 2026 Tomas Lejdung. All rights reserved." ]] \
  || fail "unexpected copyright owner"
[[ -n "$MICROPHONE_USAGE" ]] || fail "microphone usage description is missing"
[[ -n "$SYSTEM_AUDIO_USAGE" ]] || fail "system-audio usage description is missing"
[[ -n "$SCREEN_CAPTURE_USAGE" ]] || fail "screen-capture usage description is missing"

echo "Verified $DMG"
echo "Signing identity: $CLIP_CODE_SIGN_IDENTITY"
if [[ -n "${LEAF_AUTHORITY:-}" ]]; then
  echo "Leaf signer: $LEAF_AUTHORITY"
fi
echo "Designated requirement: $DESIGNATED_REQUIREMENT"
