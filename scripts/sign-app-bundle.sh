#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"

source "$ROOT/scripts/signing-config.sh"

fail() {
  echo "App signing failed: $*" >&2
  exit 1
}

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: scripts/sign-app-bundle.sh /path/to/Clip.app" >&2
  exit 64
fi

SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
WEBRTC_FRAMEWORK="$APP/Contents/Frameworks/WebRTC.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] \
  || fail "Sparkle.framework is missing from the production app"
[[ -d "$WEBRTC_FRAMEWORK" ]] \
  || fail "WebRTC.framework is missing from the Live Share build"

# Build a release entitlement plist from the checked-in source instead of
# preserving Xcode's development signature. Apple Development builds inject
# com.apple.security.get-task-allow even in Release; that debugging capability
# must not be carried into a distributed DMG.
RESOLVED_ENTITLEMENTS="$(mktemp "$ROOT/.build/clip-entitlements.XXXXXX")"
ENTITLEMENT_DIAGNOSTICS="$(mktemp "$ROOT/.build/clip-entitlement-diagnostics.XXXXXX")"
cleanup() {
  rm -f "$RESOLVED_ENTITLEMENTS" "$ENTITLEMENT_DIAGNOSTICS"
}
trap cleanup EXIT

ditto "$ROOT/Clip/Resources/Clip.entitlements" "$RESOLVED_ENTITLEMENTS"
BUNDLE_IDENTIFIER="$(
  plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist"
)"
[[ -n "$BUNDLE_IDENTIFIER" ]] || fail "Clip's bundle identifier is missing"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 $BUNDLE_IDENTIFIER-spks" \
  "$RESOLVED_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:1 $BUNDLE_IDENTIFIER-spki" \
  "$RESOLVED_ENTITLEMENTS"
# Hardened Runtime library validation requires the host and every dynamic
# framework to share a certificate-backed Team ID. Ad-hoc signatures have no
# Team ID, so even an inside-out re-sign makes dyld reject WebRTC and Sparkle
# before Clip reaches main. Keep Hardened Runtime enabled, but grant this
# local/CI-only exception when no certificate is configured. Stable-signed
# release builds retain full library validation.
clip_resolve_library_validation_entitlement "$RESOLVED_ENTITLEMENTS"
plutil -lint "$RESOLVED_ENTITLEMENTS" >/dev/null \
  || fail "Clip's resolved entitlements are invalid"
if grep -Fq '$(' "$RESOLVED_ENTITLEMENTS"; then
  fail "Clip's release entitlements contain an unresolved build setting"
fi

FRAMEWORK_VERSION="$SPARKLE_FRAMEWORK/Versions/Current"
[[ -d "$FRAMEWORK_VERSION" ]] \
  || fail "Sparkle.framework has no current framework version"

INSTALLER="$FRAMEWORK_VERSION/XPCServices/Installer.xpc"
DOWNLOADER="$FRAMEWORK_VERSION/XPCServices/Downloader.xpc"
AUTOUPDATE="$FRAMEWORK_VERSION/Autoupdate"
UPDATER="$FRAMEWORK_VERSION/Updater.app"

for COMPONENT in "$INSTALLER" "$DOWNLOADER" "$AUTOUPDATE" "$UPDATER"; do
  [[ -e "$COMPONENT" ]] || fail "Sparkle component is missing: $COMPONENT"
done

# Sparkle's sandboxed updater contains independently signed nested code. Sign
# it from the inside out exactly as Sparkle documents. In particular, never use
# codesign --deep here; it can apply Clip's entitlements to helper processes.
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  "$INSTALLER"
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  --preserve-metadata=entitlements \
  "$DOWNLOADER"
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  "$AUTOUPDATE"
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  "$UPDATER"
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  "$SPARKLE_FRAMEWORK"

# Dynamic Swift package products do not carry Clip's distribution identity.
# Sign every top-level framework or dylib explicitly before signing the host;
# WebRTC is currently the only such package product, but the loop also makes a
# newly added dynamic package impossible to leave covered only by --deep.
for COMPONENT in \
  "$APP/Contents/Frameworks/"*.framework \
  "$APP/Contents/Frameworks/"*.dylib; do
  [[ -e "$COMPONENT" ]] || continue
  [[ "$COMPONENT" == "$SPARKLE_FRAMEWORK" ]] && continue
  codesign \
    --force \
    --sign "$CLIP_CODE_SIGN_IDENTITY" \
    --options runtime \
    --timestamp=none \
    "$COMPONENT"
done
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$RESOLVED_ENTITLEMENTS" \
  "$APP"

for COMPONENT in \
  "$INSTALLER" \
  "$DOWNLOADER" \
  "$AUTOUPDATE" \
  "$UPDATER" \
  "$SPARKLE_FRAMEWORK" \
  "$APP/Contents/Frameworks/"*.framework \
  "$APP/Contents/Frameworks/"*.dylib; do
  [[ -e "$COMPONENT" ]] || continue
  codesign --verify --strict --verbose=2 "$COMPONENT" \
    || fail "nested code has an invalid signature: $COMPONENT"
done
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNED_ENTITLEMENTS="$(
  codesign -d --entitlements - --xml "$APP" 2>"$ENTITLEMENT_DIAGNOSTICS"
)" || fail "could not read Clip's final signed entitlements"
if grep -Fq 'invalid entitlements blob' "$ENTITLEMENT_DIAGNOSTICS"; then
  fail "codesign reports an invalid entitlement blob"
fi
plutil -lint /dev/stdin <<<"$SIGNED_ENTITLEMENTS" >/dev/null \
  || fail "Clip's final signed entitlements are malformed"
for KEY in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.network.server; do
  VALUE=""
  if ! VALUE="$(
    /usr/libexec/PlistBuddy -c "Print :$KEY" /dev/stdin \
      <<<"$SIGNED_ENTITLEMENTS" 2>/dev/null
  )" || [[ "$VALUE" != "true" ]]; then
    fail "Clip's final signature is missing required entitlement '$KEY'"
  fi
done
for SERVICE in "$BUNDLE_IDENTIFIER-spks" "$BUNDLE_IDENTIFIER-spki"; do
  grep -Fq "<string>$SERVICE</string>" <<<"$SIGNED_ENTITLEMENTS" \
    || fail "Clip's final signature is missing Sparkle service '$SERVICE'"
done
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.get-task-allow' \
    /dev/stdin <<<"$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
  fail "distributed Clip.app must not contain com.apple.security.get-task-allow"
fi
LIBRARY_VALIDATION_DISABLED="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.cs.disable-library-validation' \
    /dev/stdin <<<"$SIGNED_ENTITLEMENTS" 2>/dev/null || true
)"
if clip_signing_is_ad_hoc; then
  [[ "$LIBRARY_VALIDATION_DISABLED" == "true" ]] \
    || fail "ad-hoc Clip.app cannot load embedded frameworks with library validation enabled"
elif [[ -n "$LIBRARY_VALIDATION_DISABLED" ]]; then
  fail "stable-signed Clip.app must retain Hardened Runtime library validation"
fi
