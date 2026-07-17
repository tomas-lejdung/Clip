#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CLIP_CAPTURE_SMOKE_APP:-/Applications/Clip.app}"
DURATION="4"
FPS="30"
REQUIRE_QUALITY_TARGETS="0"
PRESERVE_OUTPUT=""

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run-unattended-capture-smoke.sh --allow-controlled-self-capture [--duration 3...600] [--fps 30|60] [--require-quality-targets] [--preserve-output PATH]

This opt-in lane runs the stable-signed Clip executable without XCTest UI
automation. It never moves the pointer, types, uses Accessibility/Automation,
or controls another app. Clip records only its own synthetic window and quiet
synthetic tone, pauses/resumes once, validates H.264/AAC pixels, cadence,
timestamps, and signal, generates a decoded Preview frame, exercises an
isolated file-URL Copy, decodes the copy, then deletes all artifacts. Screen Recording access must
already be granted; the lane never requests or resets permission.

The explicit --preserve-output option copies the successfully validated source
MP4 to PATH for manual review, then removes the app-owned temporary artifacts.
It refuses to overwrite an existing destination.
EOF
  exit 64
}

[[ "${1:-}" == "--allow-controlled-self-capture" ]] || usage
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      [[ $# -ge 2 ]] || usage
      DURATION="$2"
      shift 2
      ;;
    --fps)
      [[ $# -ge 2 ]] || usage
      FPS="$2"
      shift 2
      ;;
    --require-quality-targets)
      REQUIRE_QUALITY_TARGETS="1"
      shift
      ;;
    --preserve-output)
      [[ $# -ge 2 ]] || usage
      PRESERVE_OUTPUT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage
TIMEOUT_SECONDS="$(awk -v duration="$DURATION" '
  BEGIN {
    if (duration < 3 || duration > 600) exit 1
    print int(duration + 30.999)
  }
')" || usage
[[ "$FPS" == "30" || "$FPS" == "60" ]] || usage
if [[ -n "$PRESERVE_OUTPUT" ]]; then
  case "$PRESERVE_OUTPUT" in
    /*) ;;
    *) PRESERVE_OUTPUT="$PWD/$PRESERVE_OUTPUT" ;;
  esac
  [[ ! -e "$PRESERVE_OUTPUT" ]] || {
    echo "Refusing to overwrite preserved output: $PRESERVE_OUTPUT" >&2
    exit 73
  }
fi

source "$ROOT/scripts/signing-config.sh"
if clip_signing_is_ad_hoc; then
  echo "Set CLIP_CODE_SIGN_IDENTITY to Clip's stable 40-character certificate SHA-1." >&2
  exit 64
fi

[[ -d "$APP" ]] || { echo "Clip app not found: $APP" >&2; exit 66; }
EXECUTABLE="$APP/Contents/MacOS/Clip"
[[ -x "$EXECUTABLE" ]] || { echo "Clip executable is missing: $EXECUTABLE" >&2; exit 66; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "com.tomaslejdung.clip" ]] || {
  echo "Refusing app with unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 65
}
codesign --verify --deep --strict --verbose=2 "$APP"
EXPECTED_SIGNER="$(clip_resolved_signing_identity_hash)" || {
  echo "Could not resolve CLIP_CODE_SIGN_IDENTITY." >&2
  exit 65
}
ACTUAL_SIGNER="$(clip_embedded_leaf_certificate_sha1 "$APP")" || {
  echo "Could not read Clip's embedded signing certificate." >&2
  exit 65
}
[[ "$ACTUAL_SIGNER" == "$EXPECTED_SIGNER" ]] || {
  echo "Clip signer $ACTUAL_SIGNER does not match requested identity $EXPECTED_SIGNER." >&2
  exit 65
}

mkdir -p "$ROOT/.build"
REPORT="$(mktemp "$ROOT/.build/unattended-capture-smoke-report.XXXXXX")"
ERRORS="$(mktemp "$ROOT/.build/unattended-capture-smoke-errors.XXXXXX")"
TIMED_OUT="$(mktemp "$ROOT/.build/unattended-capture-smoke-timeout.XXXXXX")"
rm -f "$TIMED_OUT"
SMOKE_PID=""
WATCHDOG_PID=""
KEEP_DIAGNOSTICS=0
PRESERVED_WORK_DIRECTORY=""
PRESERVE_PARTIAL=""
cleanup_preserved_work_directory() {
  if [[ -z "$PRESERVED_WORK_DIRECTORY" || ! -d "$PRESERVED_WORK_DIRECTORY" ]]; then
    return 0
  fi
  # Never recursively delete a report-supplied path. The guarded app creates
  # exactly these three artifacts; unexpected contents make rmdir fail closed.
  rm -f \
    "$PRESERVED_WORK_DIRECTORY/synthetic-capture.mp4" \
    "$PRESERVED_WORK_DIRECTORY/preview-copy.mp4" \
    "$PRESERVED_WORK_DIRECTORY/preview-frame.png"
  rmdir "$PRESERVED_WORK_DIRECTORY" 2>/dev/null || true
  rmdir "$(dirname "$PRESERVED_WORK_DIRECTORY")" 2>/dev/null || true
  return 0
}
cleanup() {
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [[ -n "$SMOKE_PID" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  rm -f "$TIMED_OUT"
  if [[ "$KEEP_DIAGNOSTICS" != "1" ]]; then
    rm -f "$REPORT" "$ERRORS"
  fi
  cleanup_preserved_work_directory
  if [[ -n "$PRESERVE_PARTIAL" ]]; then
    rm -f "$PRESERVE_PARTIAL"
  fi
}
trap cleanup EXIT INT TERM

cat >&2 <<'EOF'
Starting controlled self-capture. A synthetic Clip window may be visible, but
the pointer and keyboard will not be controlled. Do not start another Clip
recording until this lane finishes.
EOF

if [[ -n "$PRESERVE_OUTPUT" ]]; then
  CLIP_RUN_UNATTENDED_CAPTURE_SMOKE=1 "$EXECUTABLE" \
      --unattended-real-capture-smoke \
      --acknowledge-controlled-self-capture \
      "--capture-smoke-duration=$DURATION" \
      "--capture-smoke-frame-rate=$FPS" \
      --capture-smoke-preserve-output \
      >"$REPORT" 2>"$ERRORS" &
else
  CLIP_RUN_UNATTENDED_CAPTURE_SMOKE=1 "$EXECUTABLE" \
      --unattended-real-capture-smoke \
      --acknowledge-controlled-self-capture \
      "--capture-smoke-duration=$DURATION" \
      "--capture-smoke-frame-rate=$FPS" \
      >"$REPORT" 2>"$ERRORS" &
fi
SMOKE_PID="$!"
(
  sleep "$TIMEOUT_SECONDS"
  if kill -0 "$SMOKE_PID" 2>/dev/null; then
    touch "$TIMED_OUT"
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    sleep 5
    kill -KILL "$SMOKE_PID" 2>/dev/null || true
  fi
) &
WATCHDOG_PID="$!"

PROCESS_STATUS=0
wait "$SMOKE_PID" || PROCESS_STATUS="$?"
SMOKE_PID=""
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""

if [[ -f "$TIMED_OUT" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$ERRORS" >&2
  echo "Controlled capture exceeded ${TIMEOUT_SECONDS}s and was terminated." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 124
fi
if [[ "$PROCESS_STATUS" -ne 0 ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$ERRORS" >&2
  echo "The controlled Clip process exited unsuccessfully." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi

# `plutil -lint` accepts only plist syntax on current macOS even though
# `plutil -extract` and `-convert` correctly understand JSON. Decode the report
# through the JSON-capable path before extracting its fields.
if ! plutil -convert json -o /dev/null "$REPORT"; then
  KEEP_DIAGNOSTICS=1
  cat "$ERRORS" >&2
  echo "Clip did not return a valid JSON smoke report." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi
STATUS="$(plutil -extract status raw -o - "$REPORT")"
if [[ "$STATUS" != "passed" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  cat "$ERRORS" >&2
  echo "Controlled ScreenCaptureKit smoke failed before media validation." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi
DELETED="$(plutil -extract outputWasDeleted raw -o - "$REPORT")"
PREAUTHORIZED="$(plutil -extract screenPermissionWasPreauthorized raw -o - "$REPORT")"
PREVIEW_GENERATED="$(plutil -extract previewFrameWasGenerated raw -o - "$REPORT")"
COPY_IDENTICAL="$(plutil -extract copyWasByteIdentical raw -o - "$REPORT")"
COPY_RESOLVED="$(plutil -extract copyPasteboardResolvedFileURL raw -o - "$REPORT")"
COPY_EVALUATED="$(plutil -extract copiedFileWasDecodedAndEvaluated raw -o - "$REPORT")"
PROFILE="$(plutil -extract metrics.h264ProfileIDC raw -o - "$REPORT")"
REC709="$(plutil -extract metrics.hasRec709ColorDescription raw -o - "$REPORT")"
TWO_FRAME_GAP="$(plutil -extract metrics.metTwoFrameVideoGapTarget raw -o - "$REPORT")"
EDGE_RETENTION="$(plutil -extract metrics.maximumFineDetailEdgeRetention raw -o - "$REPORT")"
if [[ "$STATUS" != "passed" || "$PREAUTHORIZED" != "true" ]] ||
   [[ "$PREVIEW_GENERATED" != "true" || "$COPY_IDENTICAL" != "true" ]] ||
   [[ "$COPY_RESOLVED" != "true" || "$COPY_EVALUATED" != "true" ]] ||
   [[ "$PROFILE" != "100" || "$REC709" != "true" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  cat "$ERRORS" >&2
  echo "Controlled ScreenCaptureKit smoke failed." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi
if [[ -z "$PRESERVE_OUTPUT" && "$DELETED" != "true" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  echo "The default controlled smoke did not delete its synthetic artifacts." >&2
  echo "Report: $REPORT" >&2
  exit 1
fi
if [[ -n "$PRESERVE_OUTPUT" ]]; then
  if [[ "$DELETED" != "false" ]]; then
    KEEP_DIAGNOSTICS=1
    cat "$REPORT" >&2
    echo "The controlled smoke did not preserve the requested source MP4." >&2
    echo "Report: $REPORT" >&2
    exit 1
  fi
  REPORTED_PRESERVED_SOURCE="$(plutil -extract preservedOutputPath raw -o - "$REPORT")"
  RESOLVED_WORK_DIRECTORY="$(cd -P "$(dirname "$REPORTED_PRESERVED_SOURCE")" && pwd -P)"
  RESOLVED_SMOKE_ROOT="$(dirname "$RESOLVED_WORK_DIRECTORY")"
  RESOLVED_TMP_ROOT="$(cd -P "$HOME/Library/Containers/$BUNDLE_ID/Data/tmp" && pwd -P)"
  EXPECTED_SMOKE_ROOT="$RESOLVED_TMP_ROOT/Clip-Controlled-Capture-Smoke"
  PRESERVED_RUN_ID="$(basename "$RESOLVED_WORK_DIRECTORY")"
  if [[ ! -f "$REPORTED_PRESERVED_SOURCE" || -L "$REPORTED_PRESERVED_SOURCE" ]] ||
     [[ "$(basename "$REPORTED_PRESERVED_SOURCE")" != "synthetic-capture.mp4" ]] ||
     [[ "$RESOLVED_SMOKE_ROOT" != "$EXPECTED_SMOKE_ROOT" ]] ||
     [[ ! "$PRESERVED_RUN_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    KEEP_DIAGNOSTICS=1
    cat "$REPORT" >&2
    echo "Clip returned an unsafe preserved-output path; refusing to copy or remove it." >&2
    echo "Report: $REPORT" >&2
    exit 1
  fi
  PRESERVED_WORK_DIRECTORY="$RESOLVED_WORK_DIRECTORY"
  PRESERVED_SMOKE_ROOT="$RESOLVED_SMOKE_ROOT"
  PRESERVED_SOURCE="$PRESERVED_WORK_DIRECTORY/synthetic-capture.mp4"
fi
if [[ "$REQUIRE_QUALITY_TARGETS" == "1" ]] && {
     [[ "$TWO_FRAME_GAP" != "true" ]] ||
     ! awk -v retention="$EDGE_RETENTION" 'BEGIN { exit !(retention >= 0.95) }';
   }; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  cat "$ERRORS" >&2
  echo "Controlled capture missed the strict two-frame-gap or 95% fine-edge target." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi

if [[ -n "$PRESERVE_OUTPUT" ]]; then
  mkdir -p "$(dirname "$PRESERVE_OUTPUT")"
  [[ ! -e "$PRESERVE_OUTPUT" ]] || {
    echo "Refusing to overwrite preserved output: $PRESERVE_OUTPUT" >&2
    exit 73
  }
  PRESERVE_PARTIAL="$PRESERVE_OUTPUT.clip-partial.$$"
  rm -f "$PRESERVE_PARTIAL"
  cp "$PRESERVED_SOURCE" "$PRESERVE_PARTIAL"
  if ! cmp -s "$PRESERVED_SOURCE" "$PRESERVE_PARTIAL"; then
    rm -f "$PRESERVE_PARTIAL"
    echo "The preserved MP4 copy was not byte-identical." >&2
    exit 1
  fi
  mv -n "$PRESERVE_PARTIAL" "$PRESERVE_OUTPUT"
  if [[ -e "$PRESERVE_PARTIAL" ]]; then
    echo "Refusing to overwrite preserved output: $PRESERVE_OUTPUT" >&2
    exit 73
  fi
  PRESERVE_PARTIAL=""
  cleanup_preserved_work_directory
  PRESERVED_WORK_DIRECTORY=""
fi

cat "$REPORT"
if [[ -n "$PRESERVE_OUTPUT" ]]; then
  echo "Controlled ScreenCaptureKit record/Preview/Copy/decode smoke passed."
  echo "Manual-review MP4: $PRESERVE_OUTPUT"
else
  echo "Controlled ScreenCaptureKit record/Preview/Copy/decode smoke passed; synthetic artifacts were deleted."
fi
