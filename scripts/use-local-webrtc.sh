#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$ROOT/Packages/ClipLiveShareWebRTC/Vendor/WebRTC.xcframework"
SOURCE="${1:-}"

fail() {
  echo "Local WebRTC install failed: $*" >&2
  exit 1
}

[[ -n "$SOURCE" ]] || fail "pass the path to WebRTC.xcframework"
[[ -d "$SOURCE" ]] || fail "framework does not exist: $SOURCE"
[[ -f "$SOURCE/Info.plist" ]] || fail "XCFramework Info.plist is missing"

MACOS_FRAMEWORK="$(
  find "$SOURCE" -path '*/WebRTC.framework/Versions/A/WebRTC' -type f \
    | while IFS= read -r executable; do
        if lipo -archs "$executable" 2>/dev/null | grep -Eq '(^| )arm64( |$)'; then
          printf '%s\n' "$executable"
          break
        fi
      done
)"
[[ -n "$MACOS_FRAMEWORK" ]] \
  || fail "no macOS arm64 WebRTC framework was found"

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
/usr/bin/ditto "$SOURCE" "$DESTINATION"

EXECUTABLE_SHA256="$(shasum -a 256 "$MACOS_FRAMEWORK" | awk '{print $1}')"
cat <<EOF
Installed local WebRTC validation artifact:
  source: $SOURCE
  destination: $DESTINATION
  source executable SHA-256: $EXECUTABLE_SHA256

SwiftPM will now prefer this ignored binary. Remove the destination directory
to return to the pinned release artifact.
EOF
