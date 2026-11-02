#!/bin/bash
# Pinned source identity shared by building, bundling and release verification.
CLIP_FFMPEG_VERSION=8.0
CLIP_FFMPEG_SOURCE_SHA256=b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e
CLIP_X264_REVISION=b35605a
CLIP_X264_SOURCE_SHA256=f1649f2457c38ea3bffec6dfce0c5ee6c742411e872e33aa22222db659f3f648

# Normalize the code-signing envelope, then hash only the Mach-O payload.
# This establishes that inside-out signing did not substitute encoder code.
# Explicit fields avoid changing the hash with macOS's codesign defaults.
clip_recording_encoder_payload_sha256() {
  local executable="$1" temporary offset result
  temporary="$(mktemp "${TMPDIR:-/tmp}/clip-encoder-payload.XXXXXX")" || return 1
  if ! ditto "$executable" "$temporary" || ! codesign --force --sign - \
      --identifier org.ffmpeg.ffmpeg --pagesize 4096 --digest-algorithm sha256 \
      --options=0 --requirements '=designated => identifier "org.ffmpeg.ffmpeg"' \
      --timestamp=none \
      "$temporary" >/dev/null 2>&1; then
    rm -f "$temporary"; return 1
  fi
  offset="$(otool -l "$temporary" | awk '/LC_CODE_SIGNATURE/ { signature=1; next } signature && $1 == "dataoff" { print $2; exit }')"
  if [[ ! "$offset" =~ ^[1-9][0-9]*$ ]]; then rm -f "$temporary"; return 1; fi
  result="$(head -c "$offset" "$temporary" | shasum -a 256 | awk '{print $1}')"
  rm -f "$temporary"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$result"
}
