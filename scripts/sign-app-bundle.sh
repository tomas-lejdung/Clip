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
[[ -d "$SPARKLE_FRAMEWORK" ]] \
  || fail "Sparkle.framework is missing from the production app"

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
codesign \
  --force \
  --sign "$CLIP_CODE_SIGN_IDENTITY" \
  --options runtime \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$RESOLVED_ENTITLEMENTS" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

SIGNED_ENTITLEMENTS="$(
  codesign -d --entitlements - --xml "$APP" 2>"$ENTITLEMENT_DIAGNOSTICS"
)" || fail "could not read Clip's final signed entitlements"
if grep -Fq 'invalid entitlements blob' "$ENTITLEMENT_DIAGNOSTICS"; then
  fail "codesign reports an invalid entitlement blob"
fi
plutil -lint /dev/stdin <<<"$SIGNED_ENTITLEMENTS" >/dev/null \
  || fail "Clip's final signed entitlements are malformed"
if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.get-task-allow' \
    /dev/stdin <<<"$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
  fail "distributed Clip.app must not contain com.apple.security.get-task-allow"
fi
