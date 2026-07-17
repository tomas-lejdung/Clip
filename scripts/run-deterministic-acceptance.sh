#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$($ROOT/scripts/build-test-helper.sh)"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-acceptance.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

json_raw_field() {
  local json="$1"
  local key="$2"

  /usr/bin/plutil -extract "$key" raw -o - - <<<"$json"
}

# This is the default acceptance lane. It intentionally never starts Clip,
# ScreenCaptureKit, AVCaptureDevice, CGEvent, AppleScript, or another app, so it
# cannot trigger a macOS privacy prompt.
"$HELPER" --status
"$HELPER" --self-test --work-directory "$WORK_DIRECTORY"

file "$WORK_DIRECTORY/fixture.png" | grep -q "PNG image data, 960 x 540"
CLIP_TEST_HELPER_PATH="$HELPER" \
  "$ROOT/scripts/validate-mp4.sh" "$WORK_DIRECTORY/fixture.mp4"

# Exercise the filesystem contract used by rename, Save As, Copy, and promised
# file drags. The renamed file includes spaces, remains independent of its
# source, and must still be a readable MP4 with identical bytes.
RENAMED_MP4="$WORK_DIRECTORY/acceptance renamed clip.mp4"
test -f "$RENAMED_MP4"
cmp -s "$WORK_DIRECTORY/fixture.mp4" "$RENAMED_MP4"
RENAMED_RESULT="$("$HELPER" --validate-mp4 "$RENAMED_MP4")"
RENAMED_VALID="$(json_raw_field "$RENAMED_RESULT" valid)"
RENAMED_VIDEO_TRACKS="$(json_raw_field "$RENAMED_RESULT" videoTrackCount)"
RENAMED_SIZE="$(json_raw_field "$RENAMED_RESULT" fileSizeBytes)"
RENAMED_WIDTH="$(json_raw_field "$RENAMED_RESULT" width)"
RENAMED_HEIGHT="$(json_raw_field "$RENAMED_RESULT" height)"
RENAMED_CODEC="$(json_raw_field "$RENAMED_RESULT" videoCodec)"
RENAMED_PROFILE="$(json_raw_field "$RENAMED_RESULT" h264ProfileIDC)"
RENAMED_REC709="$(json_raw_field "$RENAMED_RESULT" hasRec709ColorDescription)"
RENAMED_SAMPLES="$(json_raw_field "$RENAMED_RESULT" videoSampleCount)"
RENAMED_MAXIMUM_GAP="$(json_raw_field "$RENAMED_RESULT" maximumVideoTimestampGapSeconds)"
if [[ "$RENAMED_VALID" != "true" ]] ||
   [[ "$RENAMED_CODEC" != "avc1" || "$RENAMED_PROFILE" != "100" ]] ||
   [[ "$RENAMED_REC709" != "true" ]] ||
   (( RENAMED_VIDEO_TRACKS != 1 || RENAMED_SIZE <= 0 )) ||
   (( RENAMED_WIDTH != 640 || RENAMED_HEIGHT != 360 || RENAMED_SAMPLES != 60 )) ||
   ! awk -v gap="$RENAMED_MAXIMUM_GAP" \
     'BEGIN { exit !(gap >= 0 && gap <= ((2 / 30) + 0.001)) }'; then
  echo "The renamed acceptance fixture failed codec/profile/color/geometry/timestamp validation." >&2
  exit 65
fi

# Exercise the OS-level trim/remux contract without starting Clip or requesting
# capture access. ClipMedia separately tests its native reader/writer pipeline;
# this acceptance check verifies the resulting trimmed MP4 is accepted by the
# same local receiver used for Copy and drag validation.
TRIMMED_MP4="$WORK_DIRECTORY/acceptance-trimmed.mp4"
xcrun avconvert \
  --source "$WORK_DIRECTORY/fixture.mp4" \
  --preset PresetPassthrough \
  --output "$TRIMMED_MP4" \
  --start 0.4 \
  --duration 1.0 \
  --replace >/dev/null
TRIMMED_RESULT="$("$HELPER" --validate-mp4 "$TRIMMED_MP4")"
TRIMMED_VALID="$(json_raw_field "$TRIMMED_RESULT" valid)"
TRIMMED_VIDEO_TRACKS="$(json_raw_field "$TRIMMED_RESULT" videoTrackCount)"
TRIMMED_DURATION="$(json_raw_field "$TRIMMED_RESULT" durationSeconds)"
TRIMMED_PROFILE="$(json_raw_field "$TRIMMED_RESULT" h264ProfileIDC)"
TRIMMED_REC709="$(json_raw_field "$TRIMMED_RESULT" hasRec709ColorDescription)"
TRIMMED_MAXIMUM_GAP="$(json_raw_field "$TRIMMED_RESULT" maximumVideoTimestampGapSeconds)"
if [[ "$TRIMMED_VALID" != "true" ]] || (( TRIMMED_VIDEO_TRACKS < 1 )) ||
   [[ "$TRIMMED_PROFILE" != "100" || "$TRIMMED_REC709" != "true" ]] ||
   ! awk -v gap="$TRIMMED_MAXIMUM_GAP" \
     'BEGIN { exit !(gap >= 0 && gap <= ((2 / 30) + 0.001)) }' ||
   ! awk -v duration="$TRIMMED_DURATION" \
     'BEGIN { exit !(duration >= 0.8 && duration <= 1.2) }'; then
  echo "The trimmed acceptance fixture is outside the expected media bounds." >&2
  exit 65
fi

if "$HELPER" --validate-mp4 "$WORK_DIRECTORY/invalid.mp4" >/dev/null 2>&1; then
  echo "The helper unexpectedly accepted an invalid MP4 payload." >&2
  exit 65
else
  status=$?
  if [[ $status -ne 65 ]]; then
    echo "The invalid MP4 check failed with unexpected status $status." >&2
    exit "$status"
  fi
fi

echo "Deterministic acceptance passed without requesting macOS privacy permission."
