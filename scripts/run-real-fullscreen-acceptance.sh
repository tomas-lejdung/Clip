#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 || "$1" != "--allow-permission-prompts-and-pointer-control" ]]; then
  cat >&2 <<'EOF'
Usage: scripts/run-real-fullscreen-acceptance.sh --allow-permission-prompts-and-pointer-control

This opt-in lane launches Clip, opens Fullscreen from its status item, records
ClipTestHelper's harmless animated fixture, stops, exercises Preview playback,
and validates the isolated managed MP4. macOS may request Screen Recording
access. XCTest drives the visible pointer and keyboard; leave the Mac idle.
EOF
  exit 64
fi

cat >&2 <<'EOF'
WARNING: fullscreen acceptance is starting. XCTest will drive the visible
macOS pointer and keyboard. Leave the Mac idle until the command finishes.
Only isolated Clip test state and ClipTestHelper's local fixture are used.
EOF

export CLIP_RUN_REAL_FULLSCREEN_ACCEPTANCE=1
mkdir -p "$ROOT/.build"
RESULT_ROOT="$(mktemp -d "$ROOT/.build/real-fullscreen-acceptance.XXXXXX")"
RESULT_BUNDLE="$RESULT_ROOT/RealFullscreenAcceptance.xcresult"
SUMMARY_JSON="$RESULT_ROOT/summary.json"

CLIP_TEST_CONFIGURATION=Release \
  CLIP_XCRESULT_PATH="$RESULT_BUNDLE" \
  "$ROOT/scripts/test.sh" --real-fullscreen-ui

xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" > "$SUMMARY_JSON"

passed="$(plutil -extract passedTests raw -o - "$SUMMARY_JSON")"
failed="$(plutil -extract failedTests raw -o - "$SUMMARY_JSON")"
skipped="$(plutil -extract skippedTests raw -o - "$SUMMARY_JSON")"
total="$(plutil -extract totalTestCount raw -o - "$SUMMARY_JSON")"

if [[ "$passed" != "1" || "$failed" != "0" || "$skipped" != "0" || "$total" != "1" ]]; then
  echo "Fullscreen capture acceptance did not execute exactly once and pass." >&2
  echo "passed=$passed failed=$failed skipped=$skipped total=$total" >&2
  echo "Result bundle: $RESULT_BUNDLE" >&2
  exit 1
fi

echo "Fullscreen capture and Preview flow verified: 1 passed, 0 failed, 0 skipped."
echo "Result bundle (includes capture description and Preview screenshot): $RESULT_BUNDLE"
