#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: verify-recording-encoder.sh /path/to/Clip.app [provenance]}"
PROVENANCE="${2:-}"
source "$ROOT/scripts/recording-encoder-config.sh"
fail() { echo "Recording encoder verification failed: $*" >&2; exit 1; }
HELPER="$APP/Contents/Helpers/ffmpeg"
SOURCES="$APP/Contents/Resources/RecordingEncoderSources"
MANIFEST="$SOURCES/manifest.txt"
[[ -x "$HELPER" && -f "$MANIFEST" ]] || fail 'helper or source manifest is missing'
[[ "$(lipo -archs "$HELPER")" == arm64 ]] || fail 'helper must contain only arm64'
codesign --verify --strict "$HELPER" || fail 'invalid helper signature'
SIGNATURE="$(codesign -dvv "$HELPER" 2>&1)"
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || fail 'helper lacks Hardened Runtime'
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$HELPER" 2>/dev/null)"
for KEY in com.apple.security.app-sandbox com.apple.security.inherit; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$KEY" /dev/stdin <<< "$ENTITLEMENTS")" == true ]] \
    || fail "missing $KEY"
done
if grep -q 'get-task-allow\|disable-library-validation' <<< "$ENTITLEMENTS"; then
  fail 'helper has unexpected development entitlements'
fi
otool -L "$HELPER" | awk 'NR > 1 { print $1 }' | while read -r dep; do
  case "$dep" in /usr/lib/*|/System/Library/*) ;; *) fail "external runtime dependency: $dep" ;; esac
done
value() {
  local key="$1" file="$2" count
  count="$(awk -F= -v key="$key" '$1 == key { count++ } END { print count+0 }' "$file")"
  [[ "$count" == 1 ]] || fail "ambiguous manifest key: $key"
  awk -F= -v key="$key" '$1 == key { print substr($0,length(key)+2) }' "$file"
}
[[ "$(shasum -a 256 "$SOURCES/ffmpeg-8.0.tar.xz" | awk '{print $1}')" == "$CLIP_FFMPEG_SOURCE_SHA256" ]] || fail 'FFmpeg source archive differs'
[[ "$(shasum -a 256 "$SOURCES/x264-b35605a.tar.bz2" | awk '{print $1}')" == "$CLIP_X264_SOURCE_SHA256" ]] || fail 'x264 source archive differs'
for required in COPYING.GPLv2 x264-COPYING build-recording-encoder.sh recording-encoder-config.sh config.log build-version.txt README.txt; do
  [[ -s "$SOURCES/$required" ]] || fail "missing corresponding-source file: $required"
done
[[ "$(value ffmpeg_source_sha256 "$MANIFEST")" == "$CLIP_FFMPEG_SOURCE_SHA256" ]] || fail 'unexpected FFmpeg provenance'
[[ "$(value x264_source_sha256 "$MANIFEST")" == "$CLIP_X264_SOURCE_SHA256" ]] || fail 'unexpected x264 provenance'
[[ "$(value build_script_sha256 "$MANIFEST")" == "$(shasum -a 256 "$SOURCES/build-recording-encoder.sh" | awk '{print $1}')" ]] || fail 'build script hash differs'
[[ "$(value build_config_sha256 "$MANIFEST")" == "$(shasum -a 256 "$SOURCES/recording-encoder-config.sh" | awk '{print $1}')" ]] || fail 'build configuration hash differs'
PAYLOAD="$(clip_recording_encoder_payload_sha256 "$HELPER")" || fail 'cannot normalize helper payload'
[[ "$PAYLOAD" == "$(value normalized_payload_sha256 "$MANIFEST")" ]] || fail 'helper differs from the source build payload'
grep -Fq 'FFmpeg 8.0' "$APP/Contents/Resources/RecordingEncoderNotices.txt" || fail 'missing FFmpeg notice'
grep -Fq 'x264 r3222' "$APP/Contents/Resources/RecordingEncoderNotices.txt" || fail 'missing x264 notice'
if [[ -n "$PROVENANCE" ]]; then
  [[ -f "$PROVENANCE" ]] || fail 'release provenance is missing'
  [[ "$(value recording_encoder_normalized_sha256 "$PROVENANCE")" == "$PAYLOAD" ]] || fail 'packaged helper differs from release provenance'
  [[ "$(value recording_encoder_sha256 "$PROVENANCE")" == "$(shasum -a 256 "$HELPER" | awk '{print $1}')" ]] || fail 'signed helper hash differs from release provenance'
  [[ "$(value recording_encoder_manifest_sha256 "$PROVENANCE")" == "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')" ]] || fail 'encoder manifest differs from release provenance'
fi
echo "Verified standalone recording encoder: $PAYLOAD"
