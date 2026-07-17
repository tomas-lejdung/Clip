#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"

source "$ROOT/scripts/signing-config.sh"
clip_warn_if_ad_hoc_signing

XCODE_SIGNING_ARGUMENTS=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="$CLIP_CODE_SIGN_IDENTITY"
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

exec xcodebuild \
  -project "$ROOT/Clip.xcodeproj" \
  -scheme Clip \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  "${XCODE_SIGNING_ARGUMENTS[@]}" \
  clean build
