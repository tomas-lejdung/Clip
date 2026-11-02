#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: sign-recording-encoder.sh /path/to/Clip.app [identity]}"
source "$ROOT/scripts/signing-config.sh"
IDENTITY="${2:-$CLIP_CODE_SIGN_IDENTITY}"
HELPER="$APP/Contents/Helpers/ffmpeg"
[[ -x "$HELPER" ]] || { echo 'Recording encoder is missing' >&2; exit 1; }
codesign --force --sign "$IDENTITY" --identifier org.ffmpeg.ffmpeg \
  --options runtime --timestamp=none --generate-entitlement-der \
  --entitlements "$ROOT/ClipRecordingEncoder.entitlements" "$HELPER"
codesign --verify --strict "$HELPER"
"$ROOT/scripts/verify-recording-encoder.sh" "$APP"
