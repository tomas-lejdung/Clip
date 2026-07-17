#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 || "$1" != "--allow-permission-prompts-and-pointer-control" ]]; then
  cat >&2 <<'EOF'
Usage: scripts/run-real-audio-acceptance.sh --allow-permission-prompts-and-pointer-control

This opt-in lane launches the real Clip app three times and separately verifies
Microphone-only, System-Audio-only, and combined ScreenCaptureKit recordings.
It may show macOS Screen Recording or Microphone permission prompts.

WARNING: XCTest UI automation drives the real macOS pointer and keyboard while
this script runs. Do not use the Mac until the lane finishes.

Only ClipTestHelper's synthetic windows and low-volume synthetic tone are used.
Promised MP4 files and Clip's isolated test state are removed after validation.
Normal scripts/test.sh and explicitly acknowledged
scripts/test.sh --ui --allow-pointer-control runs never include these tests.
EOF
  exit 64
fi

cat >&2 <<'EOF'
WARNING: real-audio acceptance is starting. XCTest will drive the real macOS
pointer and keyboard. Leave the Mac idle until the command finishes.
EOF

export CLIP_RUN_REAL_AUDIO_ACCEPTANCE=1
mkdir -p "$ROOT/.build"
RESULT_ROOT="$(mktemp -d "$ROOT/.build/real-audio-acceptance.XXXXXX")"
RESULT_BUNDLE="$RESULT_ROOT/RealAudioAcceptance.xcresult"
SUMMARY_JSON="$RESULT_ROOT/summary.json"

CLIP_TEST_CONFIGURATION=Release \
  CLIP_XCRESULT_PATH="$RESULT_BUNDLE" \
  "$ROOT/scripts/test.sh" --real-audio-ui

xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" > "$SUMMARY_JSON"

passed="$(plutil -extract passedTests raw -o - "$SUMMARY_JSON")"
failed="$(plutil -extract failedTests raw -o - "$SUMMARY_JSON")"
skipped="$(plutil -extract skippedTests raw -o - "$SUMMARY_JSON")"
total="$(plutil -extract totalTestCount raw -o - "$SUMMARY_JSON")"

if [[ "$passed" != "3" || "$failed" != "0" || "$skipped" != "0" || "$total" != "3" ]]; then
  echo "Real audio acceptance did not execute all three source-specific tests and pass." >&2
  echo "passed=$passed failed=$failed skipped=$skipped total=$total" >&2
  echo "Result bundle: $RESULT_BUNDLE" >&2
  exit 1
fi

echo "Real audio acceptance verified: 3 passed, 0 failed, 0 skipped."
echo "Result bundle: $RESULT_BUNDLE"
