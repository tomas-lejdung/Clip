#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "Appcast generation failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/generate-appcast.sh \
    --repository OWNER/REPOSITORY \
    --tag vX.Y.Z \
    --dmg PATH \
    --output PATH \
    [--release-notes PATH] \
    [--generate-appcast PATH] \
    (--keychain-account ACCOUNT | --ed-key-file PATH)

Creates one signed Sparkle appcast item whose enclosure points to the immutable
GitHub Release asset for TAG. The command only writes OUTPUT; it never uploads,
publishes, generates a key, or changes the source DMG.

The Sparkle tool may also be supplied through
CLIP_SPARKLE_GENERATE_APPCAST; its sibling sign_update is used automatically,
or may be supplied through CLIP_SPARKLE_SIGN_UPDATE. A signing source may be
supplied through either CLIP_SPARKLE_KEY_ACCOUNT or CLIP_SPARKLE_ED_KEY_FILE.
EOF
  exit 64
}

REPOSITORY=""
TAG=""
DMG=""
OUTPUT=""
RELEASE_NOTES=""
GENERATE_APPCAST="${CLIP_SPARKLE_GENERATE_APPCAST:-}"
KEYCHAIN_ACCOUNT="${CLIP_SPARKLE_KEY_ACCOUNT:-}"
ED_KEY_FILE="${CLIP_SPARKLE_ED_KEY_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      [[ $# -ge 2 ]] || usage
      REPOSITORY="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || usage
      TAG="$2"
      shift 2
      ;;
    --dmg)
      [[ $# -ge 2 ]] || usage
      DMG="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      OUTPUT="$2"
      shift 2
      ;;
    --release-notes)
      [[ $# -ge 2 ]] || usage
      RELEASE_NOTES="$2"
      shift 2
      ;;
    --generate-appcast)
      [[ $# -ge 2 ]] || usage
      GENERATE_APPCAST="$2"
      shift 2
      ;;
    --keychain-account)
      [[ $# -ge 2 ]] || usage
      KEYCHAIN_ACCOUNT="$2"
      shift 2
      ;;
    --ed-key-file)
      [[ $# -ge 2 ]] || usage
      ED_KEY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$REPOSITORY" ]] || usage
[[ -n "$TAG" ]] || usage
[[ -n "$DMG" ]] || usage
[[ -n "$OUTPUT" ]] || usage

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "repository must use OWNER/REPOSITORY form"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "tag must use stable vX.Y.Z form"
[[ -f "$DMG" ]] || fail "DMG does not exist: $DMG"
[[ ! -e "$OUTPUT" ]] \
  || fail "output already exists; refusing to overwrite it: $OUTPUT"
[[ -z "$KEYCHAIN_ACCOUNT" || -z "$ED_KEY_FILE" ]] \
  || fail "choose either a Keychain account or an EdDSA key file, not both"
[[ -n "$KEYCHAIN_ACCOUNT" || -n "$ED_KEY_FILE" ]] \
  || fail "an explicit --keychain-account or --ed-key-file is required"

if [[ -n "$RELEASE_NOTES" ]]; then
  [[ -f "$RELEASE_NOTES" ]] \
    || fail "release notes do not exist: $RELEASE_NOTES"
  case "$RELEASE_NOTES" in
    *.md|*.html|*.txt) ;;
    *) fail "release notes must end in .md, .html, or .txt" ;;
  esac
fi

absolute_existing_file() {
  /bin/realpath "$1"
}

if [[ -n "$ED_KEY_FILE" ]]; then
  [[ -f "$ED_KEY_FILE" && -r "$ED_KEY_FILE" ]] \
    || fail "EdDSA key file is not a readable regular file: $ED_KEY_FILE"
  ED_KEY_FILE="$(absolute_existing_file "$ED_KEY_FILE")"
  case "$ED_KEY_FILE" in
    "$ROOT"/*)
      fail "the private EdDSA key must not be stored inside the repository"
      ;;
  esac

  KEY_MODE="$(stat -f '%Lp' "$ED_KEY_FILE")"
  case "$KEY_MODE" in
    *00) ;;
    *)
      fail "EdDSA key file must not grant group or other permissions (mode is $KEY_MODE)"
      ;;
  esac
fi

if [[ -n "$GENERATE_APPCAST" ]]; then
  [[ -x "$GENERATE_APPCAST" ]] \
    || fail "generate_appcast is not executable: $GENERATE_APPCAST"
  GENERATE_APPCAST="$(absolute_existing_file "$GENERATE_APPCAST")"
else
  if [[ -x "$ROOT/.build/SparkleDistribution/bin/generate_appcast" ]]; then
    GENERATE_APPCAST="$ROOT/.build/SparkleDistribution/bin/generate_appcast"
  fi

  while IFS= read -r CANDIDATE; do
    [[ -z "$GENERATE_APPCAST" ]] || break
    if [[ -x "$CANDIDATE" ]]; then
      GENERATE_APPCAST="$CANDIDATE"
      break
    fi
  done < <(
    find "$ROOT/.build" \
      -type f \
      -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
      -print 2>/dev/null | sort
  )

  if [[ -z "$GENERATE_APPCAST" ]] && \
     command -v generate_appcast >/dev/null 2>&1; then
    GENERATE_APPCAST="$(command -v generate_appcast)"
  fi
fi

[[ -n "$GENERATE_APPCAST" && -x "$GENERATE_APPCAST" ]] || fail \
  "Sparkle's generate_appcast tool was not found; build Clip once, or pass --generate-appcast PATH"

SIGN_UPDATE="${CLIP_SPARKLE_SIGN_UPDATE:-$(dirname "$GENERATE_APPCAST")/sign_update}"
[[ -x "$SIGN_UPDATE" ]] || fail \
  "Sparkle's sign_update tool was not found beside generate_appcast; set CLIP_SPARKLE_SIGN_UPDATE"
SIGN_UPDATE="$(absolute_existing_file "$SIGN_UPDATE")"

VERSION="${TAG#v}"
ASSET_NAME="Clip-$VERSION.dmg"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$TAG/"
EXPECTED_DOWNLOAD_URL="$DOWNLOAD_PREFIX$ASSET_NAME"
OUTPUT_DIRECTORY="$(dirname "$OUTPUT")"

mkdir -p "$OUTPUT_DIRECTORY"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/clip-appcast.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT

ditto "$DMG" "$WORK_DIRECTORY/$ASSET_NAME"

if [[ -n "$RELEASE_NOTES" ]]; then
  NOTES_EXTENSION="${RELEASE_NOTES##*.}"
  ditto "$RELEASE_NOTES" "$WORK_DIRECTORY/Clip-$VERSION.$NOTES_EXTENSION"
fi

APPCAST_ARGUMENTS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --maximum-versions 1
  --maximum-deltas 0
  -o "$WORK_DIRECTORY/appcast.xml"
)

if [[ -n "$RELEASE_NOTES" ]]; then
  APPCAST_ARGUMENTS+=(--embed-release-notes)
fi

if [[ -n "$ED_KEY_FILE" ]]; then
  APPCAST_ARGUMENTS+=(--ed-key-file "$ED_KEY_FILE")
else
  APPCAST_ARGUMENTS+=(--account "$KEYCHAIN_ACCOUNT")
fi

"$GENERATE_APPCAST" \
  "${APPCAST_ARGUMENTS[@]}" \
  "$WORK_DIRECTORY"

GENERATED_APPCAST="$WORK_DIRECTORY/appcast.xml"
[[ -f "$GENERATED_APPCAST" ]] \
  || fail "generate_appcast did not create appcast.xml"
xmllint --noout "$GENERATED_APPCAST" 2>/dev/null \
  || fail "generate_appcast produced malformed XML"

ITEM_COUNT="$(
  xmllint --xpath 'count(/rss/channel/item)' "$GENERATED_APPCAST" 2>/dev/null
)"
ENCLOSURE_COUNT="$(
  xmllint --xpath 'count(/rss/channel/item/enclosure)' "$GENERATED_APPCAST" 2>/dev/null
)"
[[ "$ITEM_COUNT" == "1" ]] \
  || fail "generated appcast must contain exactly one item, found $ITEM_COUNT"
[[ "$ENCLOSURE_COUNT" == "1" ]] \
  || fail "generated appcast must contain exactly one enclosure, found $ENCLOSURE_COUNT"

GENERATED_URL="$(
  xmllint \
    --xpath 'string(/rss/channel/item/enclosure/@url)' \
    "$GENERATED_APPCAST" 2>/dev/null
)"
GENERATED_SIGNATURE="$(
  xmllint \
    --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' \
    "$GENERATED_APPCAST" 2>/dev/null
)"
GENERATED_LENGTH="$(
  xmllint \
    --xpath 'string(/rss/channel/item/enclosure/@length)' \
    "$GENERATED_APPCAST" 2>/dev/null
)"
EXPECTED_LENGTH="$(stat -f '%z' "$DMG")"

[[ "$GENERATED_URL" == "$EXPECTED_DOWNLOAD_URL" ]] \
  || fail "generated enclosure URL is not the immutable tag-specific asset URL"
[[ "$GENERATED_LENGTH" == "$EXPECTED_LENGTH" ]] \
  || fail "generated enclosure length does not match the DMG"
[[ "$GENERATED_SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
  || fail "generated enclosure has no canonical 64-byte EdDSA signature"

VERIFY_ARGUMENTS=(--verify)
if [[ -n "$ED_KEY_FILE" ]]; then
  VERIFY_ARGUMENTS+=(--ed-key-file "$ED_KEY_FILE")
else
  VERIFY_ARGUMENTS+=(--account "$KEYCHAIN_ACCOUNT")
fi
"$SIGN_UPDATE" \
  "${VERIFY_ARGUMENTS[@]}" \
  "$WORK_DIRECTORY/$ASSET_NAME" \
  "$GENERATED_SIGNATURE" >/dev/null \
  || fail "Sparkle could not cryptographically verify the generated EdDSA signature"

if find "$WORK_DIRECTORY" -maxdepth 1 -type f -name '*.delta' -print -quit \
    | grep -q .; then
  fail "single-item release appcast unexpectedly generated a delta"
fi

TEMP_OUTPUT="$(mktemp "$OUTPUT_DIRECTORY/.appcast.XXXXXX")"
ditto "$GENERATED_APPCAST" "$TEMP_OUTPUT"
mv "$TEMP_OUTPUT" "$OUTPUT"

echo "Generated signed appcast: $OUTPUT"
echo "Enclosure: $EXPECTED_DOWNLOAD_URL"
echo "Sparkle tool: $GENERATE_APPCAST"
