#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CLIP_CURSOR_CAPTURE_REGRESSION_APP:-/Applications/Clip.app}"
OUTPUT=""
TIMEOUT_SECONDS=45

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run-unattended-cursor-capture-regression.sh --allow-controlled-pointer-movement [--app PATH] [--output DIR]

This opt-in lane directly runs a stable-signed Clip executable and briefly
moves the system pointer through Clip's own synthetic capture fixture. It
compares raw ScreenCaptureKit frames using best and nominal independent-window
resolution, restores the original pointer position, and emits a JSON report.

Screen Recording access must already be granted. Quit every other Clip
instance before running this lane. The lane never requests permission, types,
uses Accessibility/Automation, or controls another application.

Artifacts are retained in Clip's sandbox when --output is omitted. With
--output, the validated artifact directory is copied to DIR without
overwriting existing contents, then the sandbox copy is removed.
EOF
  exit 64
}

[[ "${1:-}" == "--allow-controlled-pointer-movement" ]] || usage
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || usage
      APP="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      OUTPUT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

case "$APP" in
  /*) ;;
  *) APP="$PWD/$APP" ;;
esac

if [[ -n "$OUTPUT" ]]; then
  case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
  esac
  while [[ "$OUTPUT" != "/" && "$OUTPUT" == */ ]]; do
    OUTPUT="${OUTPUT%/}"
  done
  [[ -n "$OUTPUT" && "$OUTPUT" != "/" ]] || usage
  if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    if [[ ! -d "$OUTPUT" || -L "$OUTPUT" ]] ||
       [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      echo "Refusing to overwrite artifact output: $OUTPUT" >&2
      exit 73
    fi
  fi
fi

source "$ROOT/scripts/signing-config.sh"
if clip_signing_is_ad_hoc; then
  echo "Set CLIP_CODE_SIGN_IDENTITY to Clip's stable 40-character certificate SHA-1." >&2
  exit 64
fi

[[ -d "$APP" ]] || { echo "Clip app not found: $APP" >&2; exit 66; }
EXECUTABLE="$APP/Contents/MacOS/Clip"
[[ -x "$EXECUTABLE" ]] || {
  echo "Clip executable is missing: $EXECUTABLE" >&2
  exit 66
}

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

EXPECTED_ARTIFACT_FILES=(
  "candidate-nominal--cursor-inside-moving.png"
  "candidate-nominal--cursor-inside-static.png"
  "candidate-nominal--cursor-outside-baseline.png"
  "candidate-nominal--cursor-outside-moving.png"
  "candidate-nominal--cursor-outside-recovery.png"
  "current-best--cursor-inside-moving.png"
  "current-best--cursor-inside-static.png"
  "current-best--cursor-outside-baseline.png"
  "current-best--cursor-outside-moving.png"
  "current-best--cursor-outside-recovery.png"
  "report.json"
)

remove_known_artifact_directory() {
  local directory="$1"
  local file_name

  [[ -n "$directory" && -d "$directory" && ! -L "$directory" ]] || return 0
  for file_name in "${EXPECTED_ARTIFACT_FILES[@]}"; do
    rm -f "$directory/$file_name"
  done
  rmdir "$directory" 2>/dev/null || true
}

validate_artifact_directory() {
  local directory="$1"
  local file_name
  local entry_count

  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  if [[ -n "$(find "$directory" -mindepth 1 ! -type f -print -quit)" ]]; then
    return 1
  fi
  entry_count="$(
    find "$directory" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]'
  )"
  [[ "$entry_count" == "${#EXPECTED_ARTIFACT_FILES[@]}" ]] || return 1
  for file_name in "${EXPECTED_ARTIFACT_FILES[@]}"; do
    [[ -f "$directory/$file_name" && ! -L "$directory/$file_name" ]] ||
      return 1
    [[ -s "$directory/$file_name" ]] || return 1
  done
}

mkdir -p "$ROOT/.build"
REPORT="$(mktemp "$ROOT/.build/unattended-cursor-regression-report.XXXXXX")"
ERRORS="$(mktemp "$ROOT/.build/unattended-cursor-regression-errors.XXXXXX")"
TIMED_OUT="$(mktemp "$ROOT/.build/unattended-cursor-regression-timeout.XXXXXX")"
rm -f "$TIMED_OUT"
REGRESSION_PID=""
WATCHDOG_PID=""
KEEP_DIAGNOSTICS=0
COPY_PARTIAL=""

cleanup() {
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [[ -n "$REGRESSION_PID" ]] &&
     kill -0 "$REGRESSION_PID" 2>/dev/null; then
    kill -TERM "$REGRESSION_PID" 2>/dev/null || true
    wait "$REGRESSION_PID" 2>/dev/null || true
  fi
  rm -f "$TIMED_OUT"
  if [[ "$KEEP_DIAGNOSTICS" != "1" ]]; then
    rm -f "$REPORT" "$ERRORS"
  fi
  if [[ -n "$COPY_PARTIAL" ]]; then
    remove_known_artifact_directory "$COPY_PARTIAL"
  fi
}
trap cleanup EXIT INT TERM

cat >&2 <<'EOF'
Starting controlled cursor capture. Clip will briefly move the system pointer
over its synthetic fixture, then restore the original position. Do not move
the pointer or start another Clip instance until this lane finishes.
EOF

CLIP_RUN_UNATTENDED_CURSOR_CAPTURE_REGRESSION=1 "$EXECUTABLE" \
  --unattended-cursor-capture-regression \
  --acknowledge-controlled-pointer-movement \
  --cursor-regression-preserve-artifacts \
  >"$REPORT" 2>"$ERRORS" &
REGRESSION_PID="$!"
(
  sleep "$TIMEOUT_SECONDS"
  if kill -0 "$REGRESSION_PID" 2>/dev/null; then
    touch "$TIMED_OUT"
    kill -TERM "$REGRESSION_PID" 2>/dev/null || true
    sleep 5
    kill -KILL "$REGRESSION_PID" 2>/dev/null || true
  fi
) &
WATCHDOG_PID="$!"

PROCESS_STATUS=0
wait "$REGRESSION_PID" || PROCESS_STATUS="$?"
REGRESSION_PID=""
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=""

if [[ -f "$TIMED_OUT" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$ERRORS" >&2
  echo "Controlled cursor capture exceeded ${TIMEOUT_SECONDS}s and was terminated." >&2
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
# `plutil -extract` and `-convert` understand JSON.
if ! plutil -convert json -o /dev/null "$REPORT"; then
  KEEP_DIAGNOSTICS=1
  cat "$ERRORS" >&2
  echo "Clip did not return a valid JSON cursor-regression report." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi
KEEP_DIAGNOSTICS=1

PROTOCOL_VERSION="$(plutil -extract protocolVersion raw -o - "$REPORT")"
STATUS="$(plutil -extract status raw -o - "$REPORT")"
PREAUTHORIZED="$(
  plutil -extract screenPermissionWasPreauthorized raw -o - "$REPORT"
)"
if [[ "$PROTOCOL_VERSION" != "1" || "$STATUS" != "passed" ]] ||
   [[ "$PREAUTHORIZED" != "true" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  cat "$ERRORS" >&2
  echo "Controlled cursor capture did not pass." >&2
  echo "Report: $REPORT" >&2
  echo "Errors: $ERRORS" >&2
  exit 1
fi

CURSOR_RESTORE_DISTANCE="$(
  plutil -extract cursorRestoreDistance raw -o - "$REPORT"
)"
if ! awk -v distance="$CURSOR_RESTORE_DISTANCE" \
    'BEGIN { exit !(distance >= 0 && distance <= 1.5) }'; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  echo "Clip did not restore the pointer within 1.5 Quartz points." >&2
  echo "Report: $REPORT" >&2
  exit 1
fi

REPORTED_ARTIFACT_DIRECTORY="$(
  plutil -extract artifactDirectoryPath raw -o - "$REPORT"
)"
case "$REPORTED_ARTIFACT_DIRECTORY" in
  /*) ;;
  *)
    KEEP_DIAGNOSTICS=1
    cat "$REPORT" >&2
    echo "Clip returned a non-absolute artifact path; refusing to copy it." >&2
    echo "Report: $REPORT" >&2
    exit 1
    ;;
esac
if [[ ! -d "$REPORTED_ARTIFACT_DIRECTORY" ||
      -L "$REPORTED_ARTIFACT_DIRECTORY" ]]; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  echo "Clip's reported artifact directory is missing or unsafe." >&2
  echo "Report: $REPORT" >&2
  exit 1
fi

RESOLVED_ARTIFACT_DIRECTORY="$(
  cd -P "$REPORTED_ARTIFACT_DIRECTORY" && pwd -P
)"
RESOLVED_ARTIFACT_ROOT="$(dirname "$RESOLVED_ARTIFACT_DIRECTORY")"
RESOLVED_TMP_ROOT="$(
  cd -P "$HOME/Library/Containers/$BUNDLE_ID/Data/tmp" && pwd -P
)"
EXPECTED_ARTIFACT_ROOT="$RESOLVED_TMP_ROOT/Clip-Cursor-Capture-Regression"
ARTIFACT_RUN_ID="$(basename "$RESOLVED_ARTIFACT_DIRECTORY")"
if [[ "$RESOLVED_ARTIFACT_ROOT" != "$EXPECTED_ARTIFACT_ROOT" ]] ||
   [[ ! "$ARTIFACT_RUN_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
   ! validate_artifact_directory "$RESOLVED_ARTIFACT_DIRECTORY" ||
   ! cmp -s "$REPORT" "$RESOLVED_ARTIFACT_DIRECTORY/report.json"; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  echo "Clip returned an unsafe or incomplete artifact directory; refusing to copy or remove it." >&2
  echo "Report: $REPORT" >&2
  exit 1
fi

for index in "${!EXPECTED_ARTIFACT_FILES[@]}"; do
  REPORTED_FILE_NAME="$(
    plutil -extract "artifactFileNames.$index" raw -o - "$REPORT"
  )"
  if [[ "$REPORTED_FILE_NAME" != "${EXPECTED_ARTIFACT_FILES[$index]}" ]]; then
    KEEP_DIAGNOSTICS=1
    cat "$REPORT" >&2
    echo "Clip's artifact manifest did not match the guarded file set." >&2
    echo "Report: $REPORT" >&2
    exit 1
  fi
done
if plutil -extract "artifactFileNames.${#EXPECTED_ARTIFACT_FILES[@]}" \
    raw -o - "$REPORT" >/dev/null 2>&1; then
  KEEP_DIAGNOSTICS=1
  cat "$REPORT" >&2
  echo "Clip's artifact manifest contained unexpected entries." >&2
  echo "Report: $REPORT" >&2
  exit 1
fi

if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    if [[ ! -d "$OUTPUT" || -L "$OUTPUT" ]] ||
       [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      echo "Refusing to overwrite artifact output: $OUTPUT" >&2
      exit 73
    fi
  fi

  COPY_PARTIAL="$OUTPUT.clip-partial.$$"
  if [[ -e "$COPY_PARTIAL" || -L "$COPY_PARTIAL" ]]; then
    echo "Refusing existing partial artifact output: $COPY_PARTIAL" >&2
    exit 73
  fi
  /usr/bin/ditto "$RESOLVED_ARTIFACT_DIRECTORY" "$COPY_PARTIAL"
  if ! validate_artifact_directory "$COPY_PARTIAL" ||
     ! diff -qr "$RESOLVED_ARTIFACT_DIRECTORY" "$COPY_PARTIAL" >/dev/null; then
    echo "The copied cursor-regression artifacts did not match the source." >&2
    exit 1
  fi

  if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    if [[ ! -d "$OUTPUT" || -L "$OUTPUT" ]] ||
       [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      echo "Refusing to overwrite artifact output: $OUTPUT" >&2
      exit 73
    fi
    rmdir "$OUTPUT"
  fi
  mv -n "$COPY_PARTIAL" "$OUTPUT"
  if [[ -e "$COPY_PARTIAL" || ! -d "$OUTPUT" ]] ||
     ! validate_artifact_directory "$OUTPUT" ||
     ! diff -qr "$RESOLVED_ARTIFACT_DIRECTORY" "$OUTPUT" >/dev/null; then
    echo "Refusing to overwrite artifact output: $OUTPUT" >&2
    exit 73
  fi
  COPY_PARTIAL=""
  remove_known_artifact_directory "$RESOLVED_ARTIFACT_DIRECTORY"
  rmdir "$RESOLVED_ARTIFACT_ROOT" 2>/dev/null || true
fi

cat "$REPORT"
if [[ -n "$OUTPUT" ]]; then
  echo "Controlled cursor capture regression passed."
  echo "Artifacts: $OUTPUT"
else
  echo "Controlled cursor capture regression passed; artifacts remain in Clip's sandbox."
  echo "Artifacts: $RESOLVED_ARTIFACT_DIRECTORY"
fi
KEEP_DIAGNOSTICS=0
