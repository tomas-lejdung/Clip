#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
SOURCE_PACKAGES="${CLIP_SOURCE_PACKAGES_PATH:-$ROOT/.build/SourcePackages}"
PACKAGE_CACHE="${CLIP_PACKAGE_CACHE_PATH:-}"

source "$ROOT/scripts/signing-config.sh"
source "$ROOT/scripts/version-config.sh"
clip_warn_if_ad_hoc_signing

XCODE_CODE_SIGN_IDENTITY="$(clip_xcode_signing_identity)" || {
  echo "Could not resolve Xcode's signing identity for '$CLIP_CODE_SIGN_IDENTITY'" >&2
  exit 1
}

XCODE_SIGNING_ARGUMENTS=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="$XCODE_CODE_SIGN_IDENTITY"
)
if ! clip_signing_is_ad_hoc; then
  DEVELOPMENT_TEAM="$(clip_resolved_development_team)" || {
    echo "Could not resolve a unique development team for signing identity '$CLIP_CODE_SIGN_IDENTITY'" >&2
    exit 1
  }
  XCODE_SIGNING_ARGUMENTS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Manual
  )
fi

case "$CONFIGURATION" in
  Debug|Release) ;;
  *)
    echo "Usage: $0 [Debug|Release]" >&2
    exit 64
    ;;
esac

PACKAGE_ARGUMENTS=(
  -onlyUsePackageVersionsFromResolvedFile
)
if [[ "${CLIP_DISABLE_PACKAGE_REPOSITORY_CACHE:-0}" == "1" ]]; then
  PACKAGE_ARGUMENTS+=(
    -disablePackageRepositoryCache
  )
fi
if [[ -n "$PACKAGE_CACHE" ]]; then
  PACKAGE_ARGUMENTS+=(
    -packageCachePath "$PACKAGE_CACHE"
  )
fi

xcodebuild \
  -project "$ROOT/Clip.xcodeproj" \
  -scheme Clip \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  "${PACKAGE_ARGUMENTS[@]}" \
  MARKETING_VERSION="$CLIP_MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$CLIP_BUILD_VERSION" \
  "${XCODE_SIGNING_ARGUMENTS[@]}" \
  clean build

# Xcode preserves independently signed binary-package frameworks. Under
# Hardened Runtime that can leave their Team ID different from Clip's and dyld
# aborts before application startup. Re-sign the Release bundle inside-out.
# DMG packaging deliberately defers this until after it verifies the raw
# dependency payload copied by Xcode.
if [[ "$CONFIGURATION" == "Release" &&
      "${CLIP_DEFER_RELEASE_BUNDLE_SIGNING:-0}" != "1" ]]; then
  APP="$DERIVED_DATA/Build/Products/Release/Clip.app"
  [[ -d "$APP" ]] || {
    echo "Expected app bundle was not produced: $APP" >&2
    exit 1
  }
  "$ROOT/scripts/sign-app-bundle.sh" "$APP"
fi
