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

WEBRTC_PACKAGE_MANIFEST="$ROOT/Packages/ClipLiveShareWebRTC/Package.swift"
LOCAL_WEBRTC_OVERRIDE="$ROOT/Packages/ClipLiveShareWebRTC/Vendor/WebRTC.xcframework"
WEBRTC_PATCH="$ROOT/Packages/ClipLiveShareWebRTC/WebRTCPatches/0001-clip-rec709-color-signaling.patch"
WEBRTC_LICENSE_SOURCE="$ROOT/Clip/Resources/WebRTCThirdPartyNotices.txt"
if [[ -e "$LOCAL_WEBRTC_OVERRIDE" ]]; then
  echo "Release packaging refuses the local WebRTC Vendor override: $LOCAL_WEBRTC_OVERRIDE" >&2
  exit 1
fi
[[ "$(rg -F -c "$CLIP_WEBRTC_ARTIFACT_URL" "$WEBRTC_PACKAGE_MANIFEST" || true)" == "1" ]] \
  || { echo "WebRTC package does not contain the reviewed direct artifact URL exactly once." >&2; exit 1; }
[[ "$(rg -F -c "$CLIP_WEBRTC_ARTIFACT_CHECKSUM" "$WEBRTC_PACKAGE_MANIFEST" || true)" == "1" ]] \
  || { echo "WebRTC package does not contain the reviewed direct artifact checksum exactly once." >&2; exit 1; }
[[ "$CLIP_WEBRTC_ARTIFACT_URL" == \
  "$CLIP_WEBRTC_ARTIFACT_REPOSITORY_URL/releases/download/$CLIP_WEBRTC_ARTIFACT_TAG/$CLIP_WEBRTC_ARTIFACT_NAME" ]] \
  || { echo "Reviewed WebRTC artifact URL is inconsistent with its repository, tag, or name." >&2; exit 1; }
[[ -f "$WEBRTC_PATCH" ]] \
  || { echo "Reviewed WebRTC source patch is missing." >&2; exit 1; }
[[ "$(shasum -a 256 "$WEBRTC_PATCH" | awk '{print $1}')" == \
  "$CLIP_WEBRTC_PATCH_SHA256" ]] \
  || { echo "WebRTC source patch differs from the reviewed hash." >&2; exit 1; }
[[ -f "$WEBRTC_LICENSE_SOURCE" ]] \
  || { echo "Official WebRTC third-party notices are missing." >&2; exit 1; }
[[ "$(shasum -a 256 "$WEBRTC_LICENSE_SOURCE" | awk '{print $1}')" == \
  "$CLIP_WEBRTC_LICENSE_SHA256" ]] \
  || { echo "Official WebRTC third-party notices differ from the reviewed hash." >&2; exit 1; }
for MARKER in '# webrtc' '# libaom' '# libvpx' '# opus'; do
  grep -Fq "$MARKER" "$WEBRTC_LICENSE_SOURCE" \
    || { echo "Official WebRTC third-party notices are missing: $MARKER" >&2; exit 1; }
done

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

[[ -d "$RELEASE_SOURCE_PACKAGES/artifacts" ]] \
  || { echo "Fresh Swift package resolution produced no binary artifacts." >&2; exit 1; }
WEBRTC_ARTIFACTS=()
while IFS= read -r ARTIFACT; do
  WEBRTC_ARTIFACTS+=("$ARTIFACT")
done < <(
  find -L "$RELEASE_SOURCE_PACKAGES/artifacts" \
    -type d -name 'WebRTC.xcframework' -prune | sort
)
[[ "${#WEBRTC_ARTIFACTS[@]}" == "1" ]] \
  || { echo "Fresh resolution must contain exactly one WebRTC.xcframework (found ${#WEBRTC_ARTIFACTS[@]})." >&2; exit 1; }
WEBRTC_ARTIFACT="${WEBRTC_ARTIFACTS[0]}"
WEBRTC_ARTIFACT_FRAMEWORKS=()
while IFS= read -r FRAMEWORK; do
  WEBRTC_ARTIFACT_FRAMEWORKS+=("$FRAMEWORK")
done < <(
  find -L "$WEBRTC_ARTIFACT" \
    -type d -name 'WebRTC.framework' -prune | sort
)
[[ "${#WEBRTC_ARTIFACT_FRAMEWORKS[@]}" == "1" ]] \
  || { echo "Reviewed XCFramework must contain exactly one macOS WebRTC.framework (found ${#WEBRTC_ARTIFACT_FRAMEWORKS[@]})." >&2; exit 1; }
WEBRTC_ARTIFACT_FRAMEWORK="${WEBRTC_ARTIFACT_FRAMEWORKS[0]}"
WEBRTC_ARTIFACT_EXECUTABLE="$WEBRTC_ARTIFACT_FRAMEWORK/Versions/A/WebRTC"
if [[ ! -f "$WEBRTC_ARTIFACT_EXECUTABLE" ]]; then
  WEBRTC_ARTIFACT_EXECUTABLE="$WEBRTC_ARTIFACT_FRAMEWORK/WebRTC"
fi
[[ -f "$WEBRTC_ARTIFACT_EXECUTABLE" ]] \
  || { echo "Fresh WebRTC artifact has no macOS executable." >&2; exit 1; }
WEBRTC_ARTIFACT_EXECUTABLE_SHA256="$(
  shasum -a 256 "$WEBRTC_ARTIFACT_EXECUTABLE" | awk '{print $1}'
)"
[[ "$WEBRTC_ARTIFACT_EXECUTABLE_SHA256" == \
   "$CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256" ]] \
  || { echo "Fresh WebRTC macOS executable has an unexpected payload hash." >&2; exit 1; }
WEBRTC_SOURCE_ARCHITECTURES="$(lipo -archs "$WEBRTC_ARTIFACT_EXECUTABLE")"
[[ "$WEBRTC_SOURCE_ARCHITECTURES" == "arm64" ]] \
  || { echo "Fresh WebRTC artifact must contain exactly the arm64 architecture." >&2; exit 1; }
WEBRTC_SOURCE_NORMALIZED_ARM64_SHA256="$(
  clip_webrtc_normalized_payload_sha256 \
    "$WEBRTC_ARTIFACT_EXECUTABLE" \
    arm64
)" || { echo "Could not normalize the reviewed WebRTC arm64 payload." >&2; exit 1; }
[[ "$WEBRTC_SOURCE_NORMALIZED_ARM64_SHA256" == \
   "$CLIP_WEBRTC_NORMALIZED_ARM64_SHA256" ]] \
  || { echo "Fresh WebRTC artifact has an unexpected normalized arm64 payload." >&2; exit 1; }
UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE="$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
[[ -f "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE" ]] \
  || { echo "Xcode did not embed the WebRTC macOS executable." >&2; exit 1; }
WEBRTC_EMBEDDED_ARCHITECTURES="$(lipo -archs "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE")"
[[ "$WEBRTC_EMBEDDED_ARCHITECTURES" == "arm64" ]] \
  || { echo "Xcode must embed exactly the arm64 WebRTC architecture." >&2; exit 1; }
WEBRTC_EMBEDDED_NORMALIZED_ARM64_SHA256="$(
  clip_webrtc_normalized_payload_sha256 \
    "$UNSIGNED_EMBEDDED_WEBRTC_EXECUTABLE" \
    arm64
)" || { echo "Could not normalize the embedded WebRTC arm64 payload." >&2; exit 1; }
[[ "$WEBRTC_EMBEDDED_NORMALIZED_ARM64_SHA256" == \
   "$CLIP_WEBRTC_NORMALIZED_ARM64_SHA256" ]] \
  || { echo "Xcode embedded a modified WebRTC arm64 code payload." >&2; exit 1; }

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
WEBRTC_THIRD_PARTY_NOTICES="$APP/Contents/Resources/WebRTCThirdPartyNotices.txt"
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
[[ -f "$WEBRTC_THIRD_PARTY_NOTICES" ]] \
  || { echo "Packaged official WebRTC third-party notices are missing." >&2; exit 1; }
[[ "$(lipo -archs "$WEBRTC_EXECUTABLE")" == "arm64" ]] \
  || { echo "Packaged WebRTC runtime must contain exactly the arm64 architecture." >&2; exit 1; }
APP_EXECUTABLE_SHA256="$(shasum -a 256 "$APP_EXECUTABLE" | awk '{print $1}')"
WEBRTC_EXECUTABLE_SHA256="$(shasum -a 256 "$WEBRTC_EXECUTABLE" | awk '{print $1}')"
WEBRTC_EXECUTABLE_NORMALIZED_ARM64_SHA256="$(
  clip_webrtc_normalized_payload_sha256 "$WEBRTC_EXECUTABLE" arm64
)" || { echo "Could not normalize the packaged WebRTC arm64 payload." >&2; exit 1; }
[[ "$WEBRTC_EXECUTABLE_NORMALIZED_ARM64_SHA256" == \
  "$CLIP_WEBRTC_NORMALIZED_ARM64_SHA256" ]] \
  || { echo "Packaged WebRTC runtime differs from the reviewed arm64 payload." >&2; exit 1; }
THIRD_PARTY_NOTICES_SHA256="$(shasum -a 256 "$THIRD_PARTY_NOTICES" | awk '{print $1}')"
WEBRTC_THIRD_PARTY_NOTICES_SHA256="$(
  shasum -a 256 "$WEBRTC_THIRD_PARTY_NOTICES" | awk '{print $1}'
)"
[[ "$WEBRTC_THIRD_PARTY_NOTICES_SHA256" == "$CLIP_WEBRTC_LICENSE_SHA256" ]] \
  || { echo "Packaged official WebRTC third-party notices differ from the reviewed file." >&2; exit 1; }
for MARKER in '# webrtc' '# libaom' '# libvpx' '# opus'; do
  grep -Fq "$MARKER" "$WEBRTC_THIRD_PARTY_NOTICES" \
    || { echo "Packaged official WebRTC third-party notices are missing: $MARKER" >&2; exit 1; }
done
DMG_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
PROVENANCE_TEMP="$(mktemp "$(dirname "$OUTPUT")/.clip-provenance.XXXXXX")"
cat >"$PROVENANCE_TEMP" <<EOF
schema=4
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
webrtc_artifact_repository=$CLIP_WEBRTC_ARTIFACT_REPOSITORY_URL
webrtc_artifact_tag=$CLIP_WEBRTC_ARTIFACT_TAG
webrtc_artifact_name=$CLIP_WEBRTC_ARTIFACT_NAME
webrtc_artifact_url=$CLIP_WEBRTC_ARTIFACT_URL
webrtc_upstream_repository=$CLIP_WEBRTC_UPSTREAM_REPOSITORY_URL
webrtc_upstream_revision=$CLIP_WEBRTC_UPSTREAM_REVISION
webrtc_patch_sha256=$CLIP_WEBRTC_PATCH_SHA256
webrtc_artifact_checksum=$CLIP_WEBRTC_ARTIFACT_CHECKSUM
webrtc_artifact_executable_sha256=$WEBRTC_ARTIFACT_EXECUTABLE_SHA256
webrtc_normalized_arm64_sha256=$WEBRTC_SOURCE_NORMALIZED_ARM64_SHA256
webrtc_executable_sha256=$WEBRTC_EXECUTABLE_SHA256
webrtc_executable_normalized_arm64_sha256=$WEBRTC_EXECUTABLE_NORMALIZED_ARM64_SHA256
third_party_notices_sha256=$THIRD_PARTY_NOTICES_SHA256
webrtc_third_party_notices_sha256=$WEBRTC_THIRD_PARTY_NOTICES_SHA256
swift_package_resolution=fresh
app_executable_sha256=$APP_EXECUTABLE_SHA256
dmg_sha256=$DMG_SHA256
EOF
mv "$PROVENANCE_TEMP" "$PROVENANCE_SIDECAR"

echo "$OUTPUT"
echo "Designated requirement: $DESIGNATED_REQUIREMENT" >&2
echo "Recorded requirement: $DESIGNATED_REQUIREMENT_SIDECAR" >&2
echo "Recorded provenance: $PROVENANCE_SIDECAR (source_clean=$SOURCE_CLEAN)" >&2
