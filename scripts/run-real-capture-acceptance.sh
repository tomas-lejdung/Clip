#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 || "$1" != "--allow-permission-prompts-and-pointer-control" ]]; then
  cat >&2 <<'EOF'
Usage: scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control

This opt-in lane launches Clip and performs a real ScreenCaptureKit recording
of ClipTestHelper. macOS may request Screen & System Audio Recording access.
XCTest drives the visible macOS pointer and keyboard while trimming and
dragging the exported file. Do not use the Mac until the command finishes.
Run scripts/run-deterministic-acceptance.sh for the normal permission-free lane.
EOF
  exit 64
fi

cat >&2 <<'EOF'
WARNING: real capture acceptance is starting. XCTest will drive the visible
macOS pointer and keyboard. Leave the Mac idle until the command finishes.
EOF

export CLIP_RUN_REAL_CAPTURE_ACCEPTANCE=1
mkdir -p "$ROOT/.build"
RESULT_ROOT="$(mktemp -d "$ROOT/.build/real-capture-acceptance.XXXXXX")"
RESULT_BUNDLE="$RESULT_ROOT/RealCaptureAcceptance.xcresult"
SUMMARY_JSON="$RESULT_ROOT/summary.json"

CLIP_TEST_CONFIGURATION=Release \
  CLIP_XCRESULT_PATH="$RESULT_BUNDLE" \
  "$ROOT/scripts/test.sh" --real-ui

xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" > "$SUMMARY_JSON"

passed="$(plutil -extract passedTests raw -o - "$SUMMARY_JSON")"
failed="$(plutil -extract failedTests raw -o - "$SUMMARY_JSON")"
skipped="$(plutil -extract skippedTests raw -o - "$SUMMARY_JSON")"
total="$(plutil -extract totalTestCount raw -o - "$SUMMARY_JSON")"

if [[ "$passed" != "1" || "$failed" != "0" || "$skipped" != "0" || "$total" != "1" ]]; then
  echo "Real capture acceptance did not execute exactly once and pass." >&2
  echo "passed=$passed failed=$failed skipped=$skipped total=$total" >&2
  echo "Result bundle: $RESULT_BUNDLE" >&2
  exit 1
fi

echo "Real capture acceptance verified: 1 passed, 0 failed, 0 skipped."
echo "Result bundle: $RESULT_BUNDLE"
