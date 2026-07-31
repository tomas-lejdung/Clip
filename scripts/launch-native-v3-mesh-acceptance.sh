#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACKNOWLEDGEMENT="--allow-native-v3-mesh-multi-instance"
EXPECTED_BUNDLE_IDENTIFIER="com.tomaslejdung.clip"
EXPECTED_TEAM_IDENTIFIER="FJ2BS65H3F"
EXPECTED_CERTIFICATE_SHA1="BA37BFFD2BD1C29A995682647428847DBC6A83B3"
EXPECTED_DESIGNATED_REQUIREMENT='designated => identifier "com.tomaslejdung.clip" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Tomas Lejdung (YSLX67M6A4)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
VALIDATOR_PACKAGE="$ROOT/Tools/ClipNativeV3AcceptanceValidator"
VALIDATOR_BUILD="$ROOT/.build/ClipNativeV3AcceptanceValidator"
VALIDATOR="$VALIDATOR_BUILD/debug/ClipNativeV3AcceptanceValidator"

usage() {
  cat >&2 <<EOF
Usage:
  $0 $ACKNOWLEDGEMENT /absolute/path/Clip.app \
    [--participants 3|4] [--require-system-audio]

This is an interactive, signed native-v3 acceptance lane. It launches and
supervises three participants by default, or four with --participants 4.
Custom app flags and participant identifiers are refused. By default the
validator requires zero audio tracks; --require-system-audio requires exactly
one local system-audio track from every participant.
EOF
}

if [[ "${1:-}" != "$ACKNOWLEDGEMENT" ]]; then
  usage
  exit 2
fi
shift

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || "$APP_PATH" != /* || ! -d "$APP_PATH" ]]; then
  usage
  exit 2
fi
shift

PARTICIPANT_COUNT=3
EXPECTED_LOCAL_AUDIO_TRACKS=0
PARTICIPANTS_FLAG_SEEN=false
SYSTEM_AUDIO_FLAG_SEEN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --participants)
      if [[ "$PARTICIPANTS_FLAG_SEEN" == true || $# -lt 2 ]]; then
        usage
        exit 2
      fi
      PARTICIPANTS_FLAG_SEEN=true
      PARTICIPANT_COUNT="$2"
      shift 2
      ;;
    --require-system-audio)
      if [[ "$SYSTEM_AUDIO_FLAG_SEEN" == true ]]; then
        usage
        exit 2
      fi
      SYSTEM_AUDIO_FLAG_SEEN=true
      EXPECTED_LOCAL_AUDIO_TRACKS=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [[ "$PARTICIPANT_COUNT" != "3" && "$PARTICIPANT_COUNT" != "4" ]]; then
    usage
    exit 2
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/Clip"
if [[ ! -f "$INFO_PLIST" || ! -x "$EXECUTABLE" ]]; then
  echo "Clip.app is missing its Info.plist or executable." >&2
  exit 1
fi

BUNDLE_IDENTIFIER=$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST"
)
if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
  echo "Refusing to launch a bundle other than $EXPECTED_BUNDLE_IDENTIFIER." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
SIGNING_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
TEAM_IDENTIFIER="$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk -F= '/^TeamIdentifier=/{print $2; exit}'
)"
if [[ "$TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
  echo "The acceptance app is not signed by Team $EXPECTED_TEAM_IDENTIFIER." >&2
  exit 1
fi
if printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Signature=adhoc$'; then
  echo "Ad-hoc builds cannot preserve Clip's acceptance permission identity." >&2
  exit 1
fi
DESIGNATED_REQUIREMENT="$(
  codesign -d -r- "$APP_PATH" 2>&1 \
    | awk '
      {
        line = $0
        sub(/^# /, "", line)
        if (!found && line ~ /^designated => /) {
          print line
          found = 1
        }
      }
    '
)"
if [[ "$DESIGNATED_REQUIREMENT" != "$EXPECTED_DESIGNATED_REQUIREMENT" ]]; then
  echo "Clip.app does not have the stable permission-bearing designated requirement." >&2
  exit 1
fi

CERTIFICATE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-signature.XXXXXX")"
chmod 700 "$CERTIFICATE_DIRECTORY"
CERTIFICATE_PREFIX="$CERTIFICATE_DIRECTORY/certificate"
codesign -d --extract-certificates="$CERTIFICATE_PREFIX" "$APP_PATH" \
  >/dev/null 2>&1
CERTIFICATE_SHA1=$(
  openssl x509 \
    -inform DER \
    -in "${CERTIFICATE_PREFIX}0" \
    -noout \
    -fingerprint \
    -sha1 \
    | awk -F= '{gsub(":", "", $2); print toupper($2)}'
)
rm -r -- "$CERTIFICATE_DIRECTORY"
if [[ "$CERTIFICATE_SHA1" != "$EXPECTED_CERTIFICATE_SHA1" ]]; then
  echo "Clip.app was not signed by the stable acceptance certificate." >&2
  exit 1
fi

if pgrep -x Clip >/dev/null 2>&1; then
  echo "Quit every existing Clip process before starting mesh acceptance." >&2
  exit 1
fi

RUN_PARENT="${TMPDIR:-/tmp}/Clip-NativeV3-Mesh-Acceptance"
mkdir -p "$RUN_PARENT"
chmod 700 "$RUN_PARENT"
RUN_DIRECTORY="$(mktemp -d "$RUN_PARENT/run.XXXXXX")"
chmod 700 "$RUN_DIRECTORY"
REPORTS_DIRECTORY="$RUN_DIRECTORY/reports"
LOGS_DIRECTORY="$RUN_DIRECTORY/logs"
CONTROL_DIRECTORY="$RUN_DIRECTORY/control"
mkdir -m 700 "$REPORTS_DIRECTORY" "$LOGS_DIRECTORY" "$CONTROL_DIRECTORY"
RUN_IDENTIFIER="$(uuidgen | tr '[:upper:]' '[:lower:]')"

LABELS=("participant-a" "participant-b" "participant-c")
if [[ "$PARTICIPANT_COUNT" == "4" ]]; then
  LABELS+=("participant-d")
fi
LABEL_LIST="$(IFS=,; echo "${LABELS[*]}")"

swift build \
  --package-path "$VALIDATOR_PACKAGE" \
  --scratch-path "$VALIDATOR_BUILD" \
  >/dev/null
if [[ ! -x "$VALIDATOR" ]]; then
  echo "The native-v3 acceptance validator did not build." >&2
  exit 1
fi

PIDS=()
CLEANUP_COMPLETE=false

request_graceful_termination() {
  : >"$CONTROL_DIRECTORY/terminate.request"
  chmod 600 "$CONTROL_DIRECTORY/terminate.request"
}

processes_are_alive() {
  local pid
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

wait_for_processes() {
  local attempts=0
  while processes_are_alive && [[ $attempts -lt 150 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  ! processes_are_alive
}

cleanup() {
  if [[ "$CLEANUP_COMPLETE" == true || ${#PIDS[@]} -eq 0 ]]; then
    return
  fi
  request_graceful_termination
  if ! wait_for_processes; then
    local pid
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
  fi
}
trap cleanup EXIT INT TERM

for label in "${LABELS[@]}"; do
  "$EXECUTABLE" \
    --ui-testing \
    --native-v3-mesh-acceptance \
    --acknowledge-native-v3-mesh-acceptance \
    "--native-v3-mesh-participant=$label" \
    "--native-v3-mesh-report-run=$RUN_IDENTIFIER" \
    "--native-v3-mesh-report-directory=$RUN_DIRECTORY" \
    >"$LOGS_DIRECTORY/$label.log" 2>&1 &
  PIDS+=("$!")
done

sleep 1
for index in "${!PIDS[@]}"; do
  if ! kill -0 "${PIDS[$index]}" 2>/dev/null; then
    echo "${LABELS[$index]} exited during launch." >&2
    echo "Log: $LOGS_DIRECTORY/${LABELS[$index]}.log" >&2
    exit 1
  fi
done

printf 'runIdentifier=%s\nlabels=%s\n' \
  "$RUN_IDENTIFIER" "$LABEL_LIST" >"$RUN_DIRECTORY/run.info"
chmod 600 "$RUN_DIRECTORY/run.info"

cat <<EOF
Launched $PARTICIPANT_COUNT independently signed native-v3 participants.

Run directory:
  $RUN_DIRECTORY

Manual ready gate:
  1. In participant-a, create one room.
  2. Join every other participant with that exact invite.
  3. Approve admissions if requested.
  4. Publish the desired test windows and system audio from each participant.
     Every participant must publish at least one window.
     Audio expectation for this run: $EXPECTED_LOCAL_AUDIO_TRACKS track(s)
     per participant.
  5. Confirm every participant shows all members and expected remote media.

No invite, access word, owner capability, or private identity is written to
this terminal or the report directory.
EOF

read -r -p "Press Return only after the room is ready on every participant. "

"$VALIDATOR" \
  --stage ready \
  --run-id "$RUN_IDENTIFIER" \
  --labels "$LABEL_LIST" \
  --expected-local-audio-tracks "$EXPECTED_LOCAL_AUDIO_TRACKS" \
  --reports-directory "$REPORTS_DIRECTORY"

echo "Ready reports passed. Requesting clean app teardown..."
request_graceful_termination
if ! wait_for_processes; then
  echo "One or more Clip processes did not terminate cleanly." >&2
  exit 1
fi

"$VALIDATOR" \
  --stage final \
  --run-id "$RUN_IDENTIFIER" \
  --labels "$LABEL_LIST" \
  --expected-local-audio-tracks "$EXPECTED_LOCAL_AUDIO_TRACKS" \
  --reports-directory "$REPORTS_DIRECTORY"

CLEANUP_COMPLETE=true
echo "Native-v3 signed multi-process acceptance passed."
echo "Private evidence remains at: $RUN_DIRECTORY"
