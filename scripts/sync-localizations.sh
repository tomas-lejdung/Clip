#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CATALOG="$ROOT/Clip/Resources/Localizable.xcstrings"
MODULE_CACHE="$ROOT/.build/LocalizationModuleCache"
CORE_MODULES="$ROOT/Packages/ClipCore/.build/arm64-apple-macosx/debug/Modules"
MEDIA_MODULES="$ROOT/Packages/ClipMedia/.build/arm64-apple-macosx/debug/Modules"
LIVE_SHARE_BUILD="$ROOT/Packages/ClipLiveShareWebRTC/.build/arm64-apple-macosx/debug"
LIVE_SHARE_MODULES="$LIVE_SHARE_BUILD/Modules"
LIVE_SHARE_AUDIO_BRIDGE_MODULE_MAP="$LIVE_SHARE_BUILD/ClipLiveShareWebRTCAudioBridge.build/module.modulemap"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clip-localization.XXXXXX")"
STRINGS_DATA="$WORK/stringsdata"
SOURCES=()

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$MODULE_CACHE" "$STRINGS_DATA"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

swift build --package-path "$ROOT/Packages/ClipCore" >/dev/null
swift build --package-path "$ROOT/Packages/ClipMedia" >/dev/null
swift build --package-path "$ROOT/Packages/ClipLiveShareWebRTC" >/dev/null

WEBRTC_SEARCH_ROOT="$ROOT/Packages/ClipLiveShareWebRTC/.build/artifacts"
if [[ -d "$ROOT/Packages/ClipLiveShareWebRTC/Vendor/WebRTC.xcframework" ]]; then
  WEBRTC_SEARCH_ROOT="$ROOT/Packages/ClipLiveShareWebRTC/Vendor/WebRTC.xcframework"
fi
WEBRTC_FRAMEWORK_CANDIDATES=()
while IFS= read -r FRAMEWORK; do
  WEBRTC_FRAMEWORK_CANDIDATES+=("$FRAMEWORK")
done < <(
  find -L "$WEBRTC_SEARCH_ROOT" \
    -type d -name 'WebRTC.framework' -prune | sort
)
[[ "${#WEBRTC_FRAMEWORK_CANDIDATES[@]}" == "1" ]] || {
  echo "Localization extraction requires exactly one resolved WebRTC.framework (found ${#WEBRTC_FRAMEWORK_CANDIDATES[@]})." >&2
  exit 1
}
WEBRTC_FRAMEWORKS="$(dirname "${WEBRTC_FRAMEWORK_CANDIDATES[0]}")"

while IFS= read -r -d '' source; do
  SOURCES+=("$source")
done < <(find "$ROOT/Clip" -type f -name '*.swift' -print0)

xcrun swiftc \
  -emit-module \
  -parse-as-library \
  -module-name ClipLocalizationExtraction \
  -emit-module-path "$WORK/ClipLocalizationExtraction.swiftmodule" \
  -emit-localized-strings \
  -emit-localized-strings-path "$STRINGS_DATA" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$CORE_MODULES" \
  -I "$MEDIA_MODULES" \
  -I "$LIVE_SHARE_MODULES" \
  -Xcc "-fmodule-map-file=$LIVE_SHARE_AUDIO_BRIDGE_MODULE_MAP" \
  -F "$WEBRTC_FRAMEWORKS" \
  "${SOURCES[@]}"

xcrun xcstringstool sync \
  "$CATALOG" \
  --stringsdata "$STRINGS_DATA"/*.stringsdata

[[ "$(plutil -extract sourceLanguage raw -o - "$CATALOG")" == "en" ]]
STRING_KEYS="$(plutil -extract strings raw -o - "$CATALOG")"
[[ -n "$STRING_KEYS" ]]
xcrun xcstringstool print "$CATALOG" >/dev/null

STRING_COUNT="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$STRING_KEYS")"
echo "Synchronized $STRING_COUNT English localization keys."
