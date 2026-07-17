#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 PATH_TO_MP4" >&2
  exit 64
fi

INPUT="$1"
if [[ ! -f "$INPUT" ]]; then
  echo "MP4 does not exist or is not a regular file: $INPUT" >&2
  exit 66
fi

case "${INPUT##*.}" in
  mp4|MP4) ;;
  *)
    echo "Expected an .mp4 file: $INPUT" >&2
    exit 65
    ;;
esac

HELPER="${CLIP_TEST_HELPER_PATH:-}"
if [[ -z "$HELPER" ]]; then
  HELPER="$($ROOT/scripts/build-test-helper.sh)"
fi

if [[ ! -x "$HELPER" ]]; then
  echo "ClipTestHelper is not executable: $HELPER" >&2
  exit 69
fi

# First validate the original file through AVFoundation, the same native media
# stack Clip uses to preview and export recordings.
"$HELPER" --validate-mp4 "$INPUT"

# Then ask Apple's avconvert to parse and remux the file. A pass-through remux
# catches malformed ISO media containers without introducing a third-party
# codec or changing the source recording.
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-mp4-validation.XXXXXX")"
REMUXED="$WORK_DIRECTORY/remuxed.mp4"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

xcrun avconvert \
  --source "$INPUT" \
  --output "$REMUXED" \
  --preset PresetPassthrough \
  --replace \
  --disableMetadataFilter

FILE_DESCRIPTION="$(file "$REMUXED")"
if ! grep -Eq "ISO Media|MPEG-4|MP4" <<<"$FILE_DESCRIPTION"; then
  echo "Apple's remux did not produce an ISO MP4 container: $FILE_DESCRIPTION" >&2
  exit 65
fi

"$HELPER" --validate-mp4 "$REMUXED"
echo "Validated local MP4 with AVFoundation and Apple avconvert: $INPUT"
