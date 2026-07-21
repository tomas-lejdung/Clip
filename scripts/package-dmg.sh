#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Clip.app"
PACKAGE_ROOT="$ROOT/.build/package"
STAGING="$PACKAGE_ROOT/staging"
OUTPUT="${CLIP_DMG_PATH:-$ROOT/.build/Clip.dmg}"
DESIGNATED_REQUIREMENT_SIDECAR="$OUTPUT.designated-requirement"
PROVENANCE_SIDECAR="$OUTPUT.provenance"
RELEASE_DEPENDENCY_ROOT=""
RELEASE_SOURCE_PACKAGES=""
RELEASE_PACKAGE_CACHE=""

source "$ROOT/scripts/signing-config.sh"
source "$ROOT/scripts/version-config.sh"
source "$ROOT/scripts/sparkle-config.sh"
source "$ROOT/scripts/webrtc-config.sh"
clip_warn_if_ad_hoc_signing

if [[ "${CLIP_MANUAL_BUILD:-0}" == "1" ]]; then
  echo "CLIP_MANUAL_BUILD cannot package updater-enabled releases; use the Xcode build." >&2
  exit 64
fi

if [[ "$CLIP_MARKETING_VERSION" != "$CLIP_PROJECT_MARKETING_VERSION" ||
      "$CLIP_BUILD_VERSION" != "$CLIP_PROJECT_BUILD_VERSION" ]]; then
  echo "Release packaging requires the version committed in Clip.xcodeproj; environment version overrides are not allowed." >&2
  exit 64
fi

mkdir -p "$ROOT/.build"
RELEASE_DEPENDENCY_ROOT="$(mktemp -d "$ROOT/.build/ReleaseDependencies.XXXXXX")"
RELEASE_SOURCE_PACKAGES="$RELEASE_DEPENDENCY_ROOT/SourcePackages"
RELEASE_PACKAGE_CACHE="$RELEASE_DEPENDENCY_ROOT/PackageCache"
mkdir -p "$RELEASE_SOURCE_PACKAGES" "$RELEASE_PACKAGE_CACHE"

cleanup_release_dependencies() {
  if [[ -n "$RELEASE_DEPENDENCY_ROOT" &&
        "$RELEASE_DEPENDENCY_ROOT" == "$ROOT/.build/ReleaseDependencies."* ]]; then
    rm -rf "$RELEASE_DEPENDENCY_ROOT"
  fi
}
trap cleanup_release_dependencies EXIT

GIT_COMMIT_BEFORE="$(git -C "$ROOT" rev-parse HEAD)"
GIT_TREE_BEFORE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
GIT_STATUS_BEFORE="$(
  git -C "$ROOT" status --porcelain --untracked-files=normal
)"

CLIP_SUPPRESS_AD_HOC_SIGNING_WARNING=1 \
  CLIP_DEFER_RELEASE_BUNDLE_SIGNING=1 \
  CLIP_SOURCE_PACKAGES_PATH="$RELEASE_SOURCE_PACKAGES" \
  CLIP_PACKAGE_CACHE_PATH="$RELEASE_PACKAGE_CACHE" \
  CLIP_DISABLE_PACKAGE_REPOSITORY_CACHE=1 \
  "$ROOT/scripts/build.sh" Release

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

SPARKLE_CHECKOUT="$RELEASE_SOURCE_PACKAGES/checkouts/Sparkle"
SPARKLE_ARTIFACT="$RELEASE_SOURCE_PACKAGES/artifacts/sparkle/Sparkle/Sparkle.xcframework"
SPARKLE_PACKAGE_MANIFEST="$SPARKLE_CHECKOUT/Package.swift"
[[ -d "$SPARKLE_CHECKOUT/.git" ]] \
  || { echo "Fresh Sparkle source checkout is missing." >&2; exit 1; }
[[ -d "$SPARKLE_ARTIFACT" ]] \
  || { echo "Fresh Sparkle binary artifact is missing." >&2; exit 1; }
SPARKLE_CHECKOUT_REVISION="$(git -C "$SPARKLE_CHECKOUT" rev-parse HEAD)"
[[ "$SPARKLE_CHECKOUT_REVISION" == "$CLIP_SPARKLE_REVISION" ]] \
  || { echo "Fresh Sparkle checkout has an unexpected revision." >&2; exit 1; }
[[ -z "$(git -C "$SPARKLE_CHECKOUT" status --porcelain --untracked-files=all)" ]] \
  || { echo "Fresh Sparkle checkout is modified." >&2; exit 1; }
SPARKLE_CHECKOUT_ORIGIN="$(git -C "$SPARKLE_CHECKOUT" remote get-url origin)"
SPARKLE_RESOLUTION_ORIGIN="$SPARKLE_CHECKOUT_ORIGIN"
if [[ "$SPARKLE_CHECKOUT_ORIGIN" != "$CLIP_SPARKLE_REPOSITORY_URL" &&
      "$SPARKLE_CHECKOUT_ORIGIN" != "$CLIP_SPARKLE_REPOSITORY_URL.git" ]]; then
  [[ -d "$SPARKLE_CHECKOUT_ORIGIN" ]] \
    || { echo "Fresh Sparkle checkout has an unexpected repository origin." >&2; exit 1; }
  SPARKLE_RESOLUTION_ORIGIN="$(git -C "$SPARKLE_CHECKOUT_ORIGIN" remote get-url origin)"
fi
[[ "$SPARKLE_RESOLUTION_ORIGIN" == "$CLIP_SPARKLE_REPOSITORY_URL" ||
   "$SPARKLE_RESOLUTION_ORIGIN" == "$CLIP_SPARKLE_REPOSITORY_URL.git" ]] \
  || { echo "Fresh Sparkle resolution did not originate from the reviewed repository." >&2; exit 1; }
grep -Fq "let version = \"$CLIP_SPARKLE_VERSION\"" "$SPARKLE_PACKAGE_MANIFEST" \
  || { echo "Sparkle package manifest has an unexpected version." >&2; exit 1; }
grep -Fq "let tag = \"$CLIP_SPARKLE_VERSION\"" "$SPARKLE_PACKAGE_MANIFEST" \
  || { echo "Sparkle package manifest has an unexpected release tag." >&2; exit 1; }
grep -Fq "let checksum = \"$CLIP_SPARKLE_ARTIFACT_CHECKSUM\"" "$SPARKLE_PACKAGE_MANIFEST" \
  || { echo "Sparkle package manifest has an unexpected artifact checksum." >&2; exit 1; }
grep -Fq 'let url = "https://github.com/sparkle-project/Sparkle/releases/download/\(tag)/Sparkle-for-Swift-Package-Manager.zip"' \
  "$SPARKLE_PACKAGE_MANIFEST" \
  || { echo "Sparkle package manifest has an unexpected artifact URL." >&2; exit 1; }

WEBRTC_CHECKOUT="$RELEASE_SOURCE_PACKAGES/checkouts/WebRTC"
WEBRTC_ARTIFACT="$RELEASE_SOURCE_PACKAGES/artifacts/webrtc/WebRTC/WebRTC.xcframework"
WEBRTC_PACKAGE_MANIFEST="$WEBRTC_CHECKOUT/Package.swift"
WEBRTC_ARTIFACT_EXECUTABLE="$WEBRTC_ARTIFACT/macos-x86_64_arm64/WebRTC.framework/Versions/A/WebRTC"
[[ -d "$WEBRTC_CHECKOUT/.git" ]] \
  || { echo "Fresh WebRTC source checkout is missing." >&2; exit 1; }
[[ -d "$WEBRTC_ARTIFACT" ]] \
  || { echo "Fresh WebRTC binary artifact is missing." >&2; exit 1; }
WEBRTC_CHECKOUT_REVISION="$(git -C "$WEBRTC_CHECKOUT" rev-parse HEAD)"
[[ "$WEBRTC_CHECKOUT_REVISION" == "$CLIP_WEBRTC_WRAPPER_REVISION" ]] \
  || { echo "Fresh WebRTC checkout has an unexpected revision." >&2; exit 1; }
[[ -z "$(git -C "$WEBRTC_CHECKOUT" status --porcelain --untracked-files=all)" ]] \
  || { echo "Fresh WebRTC checkout is modified." >&2; exit 1; }
WEBRTC_CHECKOUT_ORIGIN="$(git -C "$WEBRTC_CHECKOUT" remote get-url origin)"
WEBRTC_RESOLUTION_ORIGIN="$WEBRTC_CHECKOUT_ORIGIN"
if [[ "$WEBRTC_CHECKOUT_ORIGIN" != "$CLIP_WEBRTC_REPOSITORY_URL" &&
      "$WEBRTC_CHECKOUT_ORIGIN" != "$CLIP_WEBRTC_REPOSITORY_URL.git" ]]; then
  [[ -d "$WEBRTC_CHECKOUT_ORIGIN" ]] \
    || { echo "Fresh WebRTC checkout has an unexpected repository origin." >&2; exit 1; }
  WEBRTC_RESOLUTION_ORIGIN="$(git -C "$WEBRTC_CHECKOUT_ORIGIN" remote get-url origin)"
fi
[[ "$WEBRTC_RESOLUTION_ORIGIN" == "$CLIP_WEBRTC_REPOSITORY_URL" ||
   "$WEBRTC_RESOLUTION_ORIGIN" == "$CLIP_WEBRTC_REPOSITORY_URL.git" ]] \
  || { echo "Fresh WebRTC resolution did not originate from the reviewed repository." >&2; exit 1; }
grep -Fq "releases/download/$CLIP_WEBRTC_VERSION/WebRTC-M150.xcframework.zip" \
  "$WEBRTC_PACKAGE_MANIFEST" \
  || { echo "WebRTC package manifest has an unexpected artifact URL." >&2; exit 1; }
grep -Fq "checksum: \"$CLIP_WEBRTC_ARTIFACT_CHECKSUM\"" \
  "$WEBRTC_PACKAGE_MANIFEST" \
  || { echo "WebRTC package manifest has an unexpected checksum." >&2; exit 1; }
[[ -f "$WEBRTC_ARTIFACT_EXECUTABLE" ]] \
  || { echo "Fresh WebRTC artifact has no macOS executable." >&2; exit 1; }
WEBRTC_ARTIFACT_EXECUTABLE_SHA256="$(
  shasum -a 256 "$WEBRTC_ARTIFACT_EXECUTABLE" | awk '{print $1}'
)"
[[ "$WEBRTC_ARTIFACT_EXECUTABLE_SHA256" == \
   "$CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256" ]] \
  || { echo "Fresh WebRTC macOS executable has an unexpected payload hash." >&2; exit 1; }
UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE="$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
[[ -f "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE" ]] \
  || { echo "Xcode did not embed the WebRTC macOS executable." >&2; exit 1; }
WEBRTC_SOURCE_ARCHITECTURES="$(lipo -archs "$WEBRTC_ARTIFACT_EXECUTABLE")"
WEBRTC_EMBEDDED_ARCHITECTURES="$(lipo -archs "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE")"
[[ "$WEBRTC_EMBEDDED_ARCHITECTURES" == "$WEBRTC_SOURCE_ARCHITECTURES" ]] \
  || { echo "Xcode embedded unexpected WebRTC architecture slices." >&2; exit 1; }
for ARCHITECTURE in $WEBRTC_SOURCE_ARCHITECTURES; do
  SOURCE_PAYLOAD_SHA256="$(
    clip_webrtc_normalized_payload_sha256 \
      "$WEBRTC_ARTIFACT_EXECUTABLE" \
      "$ARCHITECTURE"
  )" || { echo "Could not normalize the reviewed WebRTC $ARCHITECTURE payload." >&2; exit 1; }
  EMBEDDED_PAYLOAD_SHA256="$(
    clip_webrtc_normalized_payload_sha256 \
      "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE" \
      "$ARCHITECTURE"
  )" || { echo "Could not normalize the embedded WebRTC $ARCHITECTURE payload." >&2; exit 1; }
  [[ "$EMBEDDED_PAYLOAD_SHA256" == "$SOURCE_PAYLOAD_SHA256" ]] \
    || { echo "Xcode embedded a modified WebRTC $ARCHITECTURE code payload." >&2; exit 1; }
done

# Re-sign Sparkle's helpers, framework, and host from the inside out. Sparkle
# explicitly forbids deep signing for this sandboxed integration.
"$ROOT/scripts/sign-app-bundle.sh" "$APP"

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
rm -f "$OUTPUT" "$DESIGNATED_REQUIREMENT_SIDECAR" "$PROVENANCE_SIDECAR"
hdiutil create \
  -volname "Clip" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$OUTPUT"

printf '%s\n' "$DESIGNATED_REQUIREMENT" > "$DESIGNATED_REQUIREMENT_SIDECAR"

GIT_COMMIT_AFTER="$(git -C "$ROOT" rev-parse HEAD)"
GIT_TREE_AFTER="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
GIT_STATUS_AFTER="$(
  git -C "$ROOT" status --porcelain --untracked-files=normal
)"
SOURCE_CLEAN=false
if [[ -z "$GIT_STATUS_BEFORE" && -z "$GIT_STATUS_AFTER" &&
      "$GIT_COMMIT_BEFORE" == "$GIT_COMMIT_AFTER" &&
      "$GIT_TREE_BEFORE" == "$GIT_TREE_AFTER" ]]; then
  SOURCE_CLEAN=true
fi

APP_INFO="$APP/Contents/Info.plist"
APP_EXECUTABLE="$APP/Contents/MacOS/Clip"
WEBRTC_EXECUTABLE="$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
THIRD_PARTY_NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
SPARKLE_INFO="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Resources/Info.plist"
PACKAGED_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO"
)"
PACKAGED_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_INFO")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP_INFO")"
SPARKLE_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$SPARKLE_INFO"
)"
[[ "$PACKAGED_VERSION" == "$CLIP_MARKETING_VERSION" ]] \
  || { echo "Packaged marketing version differs from the requested build." >&2; exit 1; }
[[ "$PACKAGED_BUILD" == "$CLIP_BUILD_VERSION" ]] \
  || { echo "Packaged build number differs from the requested build." >&2; exit 1; }
[[ "$BUNDLE_IDENTIFIER" == "com.tomaslejdung.clip" ]] \
  || { echo "Packaged bundle identifier is unexpected." >&2; exit 1; }
[[ "$SPARKLE_VERSION" == "$CLIP_SPARKLE_VERSION" ]] \
  || { echo "Packaged Sparkle runtime is not $CLIP_SPARKLE_VERSION." >&2; exit 1; }
[[ -f "$WEBRTC_EXECUTABLE" ]] \
  || { echo "Packaged WebRTC runtime is missing." >&2; exit 1; }
[[ -f "$THIRD_PARTY_NOTICES" ]] \
  || { echo "Packaged third-party notices are missing." >&2; exit 1; }
file "$WEBRTC_EXECUTABLE" | grep -q 'arm64' \
  || { echo "Packaged WebRTC runtime has no arm64 slice." >&2; exit 1; }
APP_EXECUTABLE_SHA256="$(shasum -a 256 "$APP_EXECUTABLE" | awk '{print $1}')"
WEBRTC_EXECUTABLE_SHA256="$(shasum -a 256 "$WEBRTC_EXECUTABLE" | awk '{print $1}')"
THIRD_PARTY_NOTICES_SHA256="$(shasum -a 256 "$THIRD_PARTY_NOTICES" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
PROVENANCE_TEMP="$(mktemp "$(dirname "$OUTPUT")/.clip-provenance.XXXXXX")"
cat >"$PROVENANCE_TEMP" <<EOF
schema=3
git_commit=$GIT_COMMIT_AFTER
git_tree=$GIT_TREE_AFTER
source_clean=$SOURCE_CLEAN
bundle_identifier=$BUNDLE_IDENTIFIER
project_marketing_version=$CLIP_PROJECT_MARKETING_VERSION
project_build_version=$CLIP_PROJECT_BUILD_VERSION
marketing_version=$PACKAGED_VERSION
build_version=$PACKAGED_BUILD
sparkle_version=$SPARKLE_VERSION
sparkle_revision=$SPARKLE_CHECKOUT_REVISION
sparkle_repository=$CLIP_SPARKLE_REPOSITORY_URL
sparkle_artifact_checksum=$CLIP_SPARKLE_ARTIFACT_CHECKSUM
webrtc_version=$CLIP_WEBRTC_VERSION
webrtc_wrapper_revision=$WEBRTC_CHECKOUT_REVISION
webrtc_upstream_revision=$CLIP_WEBRTC_UPSTREAM_REVISION
webrtc_repository=$CLIP_WEBRTC_REPOSITORY_URL
webrtc_artifact_checksum=$CLIP_WEBRTC_ARTIFACT_CHECKSUM
webrtc_artifact_executable_sha256=$WEBRTC_ARTIFACT_EXECUTABLE_SHA256
webrtc_executable_sha256=$WEBRTC_EXECUTABLE_SHA256
third_party_notices_sha256=$THIRD_PARTY_NOTICES_SHA256
swift_package_resolution=fresh
app_executable_sha256=$APP_EXECUTABLE_SHA256
dmg_sha256=$DMG_SHA256
EOF
mv "$PROVENANCE_TEMP" "$PROVENANCE_SIDECAR"

echo "$OUTPUT"
echo "Designated requirement: $DESIGNATED_REQUIREMENT" >&2
echo "Recorded requirement: $DESIGNATED_REQUIREMENT_SIDECAR" >&2
echo "Recorded provenance: $PROVENANCE_SIDECAR (source_clean=$SOURCE_CLEAN)" >&2
