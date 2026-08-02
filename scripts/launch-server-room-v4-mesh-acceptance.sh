#!/bin/bash

set -euo pipefail
umask 077

ACKNOWLEDGEMENT="--allow-server-room-v4-mesh-multi-instance"
EXPECTED_BUNDLE_IDENTIFIER="com.tomaslejdung.clip"
EXPECTED_TEAM_IDENTIFIER="FJ2BS65H3F"
EXPECTED_CERTIFICATE_SHA1="BA37BFFD2BD1C29A995682647428847DBC6A83B3"

usage() {
  cat >&2 <<EOF
Usage:
  $0 $ACKNOWLEDGEMENT /absolute/path/Clip.app \
    [--participants 3|4] [--server-root https://rooms.example] \
    [--menu-bar-popovers]

Launches three isolated signed Clip participants by default, or four when
requested. The optional menu-bar mode retains isolated participant identities
but uses Clip's real status-item popovers instead of addressable test windows.
This launcher does not create rooms, copy invites, approve members, publish
media, or validate reports; use Clip's production UI for the real flow.
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
SERVER_ROOT=""
MENU_BAR_POPOVERS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --participants)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      PARTICIPANT_COUNT="$2"
      shift 2
      ;;
    --server-root)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SERVER_ROOT="$2"
      shift 2
      ;;
    --menu-bar-popovers)
      MENU_BAR_POPOVERS=1
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
if [[ -n "$SERVER_ROOT" ]]; then
  case "$SERVER_ROOT" in
    https://*|http://localhost:*|http://127.0.0.1:*) ;;
    *)
      echo "The acceptance server root must use HTTPS or local HTTP." >&2
      exit 2
      ;;
  esac
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
TEAM_IDENTIFIER=$(
  printf '%s\n' "$SIGNING_DETAILS" \
    | awk -F= '/^TeamIdentifier=/{print $2; exit}'
)
if [[ "$TEAM_IDENTIFIER" != "$EXPECTED_TEAM_IDENTIFIER" ]]; then
  echo "The acceptance app is not signed by Team $EXPECTED_TEAM_IDENTIFIER." >&2
  exit 1
fi
if printf '%s\n' "$SIGNING_DETAILS" | grep -q '^Signature=adhoc$'; then
  echo "Ad-hoc builds cannot preserve Clip's Screen Recording identity." >&2
  exit 1
fi

CERTIFICATE_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-signature.XXXXXX")"
CERTIFICATE_PREFIX="$CERTIFICATE_DIRECTORY/certificate"
trap 'rm -r -- "$CERTIFICATE_DIRECTORY"' EXIT
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
if [[ "$CERTIFICATE_SHA1" != "$EXPECTED_CERTIFICATE_SHA1" ]]; then
  echo "Clip.app was not signed by the stable acceptance certificate." >&2
  exit 1
fi
rm -r -- "$CERTIFICATE_DIRECTORY"
trap - EXIT

if pgrep -x Clip >/dev/null 2>&1; then
  echo "Quit every existing Clip process before starting mesh acceptance." >&2
  exit 1
fi

RUN_IDENTIFIER="mesh-$(uuidgen | tr '[:upper:]' '[:lower:]')"
RUN_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-mesh-acceptance.XXXXXX")"
LOGS_DIRECTORY="$RUN_DIRECTORY/logs"
mkdir -m 700 "$LOGS_DIRECTORY"

LABELS=("participant-a" "participant-b" "participant-c")
if [[ "$PARTICIPANT_COUNT" == "4" ]]; then
  LABELS+=("participant-d")
fi

for label in "${LABELS[@]}"; do
  launch_arguments=(
    --ui-testing
    --mesh-acceptance
    --acknowledge-mesh-acceptance
    "--mesh-acceptance-run=$RUN_IDENTIFIER"
    "--mesh-acceptance-participant=$label"
  )
  if [[ -n "$SERVER_ROOT" ]]; then
    launch_arguments+=("--mesh-acceptance-server-root=$SERVER_ROOT")
  fi
  if [[ "$MENU_BAR_POPOVERS" == "1" ]]; then
    launch_arguments+=(--mesh-acceptance-menu-bar-popover)
  fi
  /usr/bin/open -n "$APP_PATH" \
    --stdout "$LOGS_DIRECTORY/$label.log" \
    --stderr "$LOGS_DIRECTORY/$label.log" \
    --args "${launch_arguments[@]}"
done

sleep 2
for label in "${LABELS[@]}"; do
  if ! pgrep -f -- "--mesh-acceptance-participant=$label" >/dev/null 2>&1; then
    echo "$label exited during launch." >&2
    echo "Log: $LOGS_DIRECTORY/$label.log" >&2
    exit 1
  fi
done

if [[ "$MENU_BAR_POPOVERS" == "1" ]]; then
  PRESENTATION_LABEL="menu-bar popovers"
else
  PRESENTATION_LABEL="addressable participant windows"
fi

cat <<EOF
Launched $PARTICIPANT_COUNT isolated server-room-v4 Clip participants.

Presentation:
  $PRESENTATION_LABEL

Run identifier:
  $RUN_IDENTIFIER

Logs:
  $LOGS_DIRECTORY

Manual flow:
  1. Create one room in participant-a and copy its invite exactly once.
  2. Join every other participant with that same byte-for-byte invite.
  3. Confirm 1, 3, or 6 pair connections for 2, 3, or 4 participants.
  4. Publish at least one source from every participant and confirm every other
     participant receives it.
  5. Confirm an ordinary participant can leave without changing retained pairs.
  6. Confirm creator departure ends the room for every remaining participant.

Only an explicit New Invite action may change the copied invite. The launcher
does not print invite, Access Word, identity, SDP/ICE, source, or media data.
EOF
