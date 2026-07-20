#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="tomas-lejdung/Clip"
EXPECTED_FEED_URL="https://tomas-lejdung.github.io/Clip/appcast.xml"
CANONICAL_APPCAST="$ROOT/docs/appcast.xml"

fail() {
  echo "GitHub Release preparation failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/prepare-github-release.sh \
    --tag vX.Y.Z \
    --release-notes PATH \
    [--dmg PATH] \
    [--output-directory PATH] \
    [--repository OWNER/REPOSITORY] \
    [--generate-appcast PATH] \
    [--bootstrap] \
    (--keychain-account ACCOUNT | --ed-key-file PATH)

Verifies and stages a signed, versioned Clip DMG, a signed Sparkle appcast,
release notes, checksums, and a provenance manifest. It never creates a GitHub
release, pushes a tag, publishes GitHub Pages, or creates signing keys.

Defaults:
  --dmg .build/Clip.dmg
  --output-directory .build/releases/vX.Y.Z
  --repository tomas-lejdung/Clip

Sparkle tool and key options may instead be set with
CLIP_SPARKLE_GENERATE_APPCAST, CLIP_SPARKLE_KEY_ACCOUNT, or
CLIP_SPARKLE_ED_KEY_FILE.
EOF
  exit 64
}

TAG=""
DMG="$ROOT/.build/Clip.dmg"
OUTPUT_DIRECTORY=""
RELEASE_NOTES=""
GENERATE_APPCAST="${CLIP_SPARKLE_GENERATE_APPCAST:-}"
KEYCHAIN_ACCOUNT="${CLIP_SPARKLE_KEY_ACCOUNT:-}"
ED_KEY_FILE="${CLIP_SPARKLE_ED_KEY_FILE:-}"
BOOTSTRAP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --output-directory)
      [[ $# -ge 2 ]] || usage
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --release-notes)
      [[ $# -ge 2 ]] || usage
      RELEASE_NOTES="$2"
      shift 2
      ;;
    --repository)
      [[ $# -ge 2 ]] || usage
      REPOSITORY="$2"
      shift 2
      ;;
    --generate-appcast)
      [[ $# -ge 2 ]] || usage
      GENERATE_APPCAST="$2"
      shift 2
      ;;
    --bootstrap)
      BOOTSTRAP=1
      shift
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

[[ -n "$TAG" ]] || usage
[[ -n "$RELEASE_NOTES" ]] || usage
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "tag must use stable vX.Y.Z form"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "repository must use OWNER/REPOSITORY form"
[[ "$REPOSITORY" == "tomas-lejdung/Clip" ]] \
  || fail "this Clip build is configured for tomas-lejdung/Clip"
[[ -f "$DMG" ]] || fail "DMG does not exist: $DMG"
PROVENANCE="$DMG.provenance"
[[ -f "$PROVENANCE" ]] \
  || fail "DMG build provenance is missing: $PROVENANCE"
[[ -f "$RELEASE_NOTES" ]] \
  || fail "release notes do not exist: $RELEASE_NOTES"
case "$RELEASE_NOTES" in
  *.md) ;;
  *) fail "GitHub release notes must be a Markdown (.md) file" ;;
esac
[[ -z "$KEYCHAIN_ACCOUNT" || -z "$ED_KEY_FILE" ]] \
  || fail "choose either a Keychain account or an EdDSA key file, not both"
[[ -n "$KEYCHAIN_ACCOUNT" || -n "$ED_KEY_FILE" ]] \
  || fail "an explicit --keychain-account or --ed-key-file is required"
if [[ "$BOOTSTRAP" == "1" ]]; then
  [[ ! -e "$CANONICAL_APPCAST" ]] \
    || fail "bootstrap mode is invalid once the tracked appcast exists"
else
  [[ -f "$CANONICAL_APPCAST" ]] \
    || fail "the tracked docs/appcast.xml is required; use --bootstrap only for the true first updater release"
  git -C "$ROOT" ls-files --error-unmatch docs/appcast.xml >/dev/null 2>&1 \
    || fail "docs/appcast.xml must be tracked in Git"
fi

VERSION="${TAG#v}"
if [[ -z "$OUTPUT_DIRECTORY" ]]; then
  OUTPUT_DIRECTORY="$ROOT/.build/releases/$TAG"
fi
[[ ! -e "$OUTPUT_DIRECTORY" ]] \
  || fail "output directory already exists; refusing to overwrite it: $OUTPUT_DIRECTORY"

source "$ROOT/scripts/signing-config.sh"
source "$ROOT/scripts/version-config.sh"
source "$ROOT/scripts/sparkle-config.sh"
source "$ROOT/scripts/webrtc-config.sh"
if clip_signing_is_ad_hoc; then
  fail "update releases must use a stable signing identity; set CLIP_CODE_SIGN_IDENTITY"
fi

if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  fail "the Git worktree must be clean so the staged artifact has exact provenance"
fi

GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
GIT_TREE="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"

provenance_value() {
  local key="$1"
  local values
  local count
  values="$(
    awk -F= -v key="$key" '
      $1 == key { print substr($0, length($1) + 2) }
    ' "$PROVENANCE"
  )"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] \
    || fail "provenance key '$key' must occur exactly once"
  printf '%s' "$values"
}

PROVENANCE_SCHEMA="$(provenance_value schema)"
PROVENANCE_COMMIT="$(provenance_value git_commit)"
PROVENANCE_TREE="$(provenance_value git_tree)"
PROVENANCE_CLEAN="$(provenance_value source_clean)"
PROVENANCE_BUNDLE_IDENTIFIER="$(provenance_value bundle_identifier)"
PROVENANCE_PROJECT_VERSION="$(provenance_value project_marketing_version)"
PROVENANCE_PROJECT_BUILD="$(provenance_value project_build_version)"
PROVENANCE_VERSION="$(provenance_value marketing_version)"
PROVENANCE_BUILD="$(provenance_value build_version)"
PROVENANCE_SPARKLE_VERSION="$(provenance_value sparkle_version)"
PROVENANCE_SPARKLE_REVISION="$(provenance_value sparkle_revision)"
PROVENANCE_SPARKLE_REPOSITORY="$(provenance_value sparkle_repository)"
PROVENANCE_SPARKLE_CHECKSUM="$(provenance_value sparkle_artifact_checksum)"
PROVENANCE_WEBRTC_VERSION="$(provenance_value webrtc_version)"
PROVENANCE_WEBRTC_WRAPPER_REVISION="$(provenance_value webrtc_wrapper_revision)"
PROVENANCE_WEBRTC_UPSTREAM_REVISION="$(provenance_value webrtc_upstream_revision)"
PROVENANCE_WEBRTC_REPOSITORY="$(provenance_value webrtc_repository)"
PROVENANCE_WEBRTC_CHECKSUM="$(provenance_value webrtc_artifact_checksum)"
PROVENANCE_WEBRTC_ARTIFACT_EXECUTABLE_SHA256="$(
  provenance_value webrtc_artifact_executable_sha256
)"
PROVENANCE_WEBRTC_EXECUTABLE_SHA256="$(provenance_value webrtc_executable_sha256)"
PROVENANCE_THIRD_PARTY_NOTICES_SHA256="$(provenance_value third_party_notices_sha256)"
PROVENANCE_PACKAGE_RESOLUTION="$(provenance_value swift_package_resolution)"
PROVENANCE_EXECUTABLE_SHA256="$(provenance_value app_executable_sha256)"
PROVENANCE_DMG_SHA256="$(provenance_value dmg_sha256)"
ACTUAL_SOURCE_DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

[[ "$PROVENANCE_SCHEMA" == "3" ]] || fail "unsupported DMG provenance schema"
[[ "$PROVENANCE_CLEAN" == "true" ]] \
  || fail "DMG was not built from a clean, unchanged Git worktree"
[[ "$PROVENANCE_COMMIT" == "$GIT_COMMIT" ]] \
  || fail "DMG was built from commit $PROVENANCE_COMMIT, not current HEAD $GIT_COMMIT"
[[ "$PROVENANCE_TREE" == "$GIT_TREE" ]] \
  || fail "DMG source tree does not match current HEAD"
[[ "$PROVENANCE_DMG_SHA256" == "$ACTUAL_SOURCE_DMG_SHA256" ]] \
  || fail "DMG bytes no longer match their build provenance"
[[ "$PROVENANCE_PROJECT_VERSION" == "$CLIP_PROJECT_MARKETING_VERSION" ]] \
  || fail "DMG provenance does not match the marketing version committed in Clip.xcodeproj"
[[ "$PROVENANCE_PROJECT_BUILD" == "$CLIP_PROJECT_BUILD_VERSION" ]] \
  || fail "DMG provenance does not match the build number committed in Clip.xcodeproj"
[[ "$PROVENANCE_VERSION" == "$CLIP_PROJECT_MARKETING_VERSION" ]] \
  || fail "packaged marketing version does not match the committed Xcode version"
[[ "$PROVENANCE_BUILD" == "$CLIP_PROJECT_BUILD_VERSION" ]] \
  || fail "packaged build number does not match the committed Xcode version"
[[ "$PROVENANCE_SPARKLE_REVISION" == "$CLIP_SPARKLE_REVISION" ]] \
  || fail "DMG provenance has an unexpected Sparkle source revision"
[[ "$PROVENANCE_SPARKLE_REPOSITORY" == "$CLIP_SPARKLE_REPOSITORY_URL" ]] \
  || fail "DMG provenance has an unexpected Sparkle source repository"
[[ "$PROVENANCE_SPARKLE_CHECKSUM" == "$CLIP_SPARKLE_ARTIFACT_CHECKSUM" ]] \
  || fail "DMG provenance has an unexpected Sparkle binary checksum"
[[ "$PROVENANCE_WEBRTC_VERSION" == "$CLIP_WEBRTC_VERSION" ]] \
  || fail "DMG provenance has an unexpected WebRTC version"
[[ "$PROVENANCE_WEBRTC_WRAPPER_REVISION" == "$CLIP_WEBRTC_WRAPPER_REVISION" ]] \
  || fail "DMG provenance has an unexpected WebRTC wrapper revision"
[[ "$PROVENANCE_WEBRTC_UPSTREAM_REVISION" == "$CLIP_WEBRTC_UPSTREAM_REVISION" ]] \
  || fail "DMG provenance has an unexpected WebRTC upstream revision"
[[ "$PROVENANCE_WEBRTC_REPOSITORY" == "$CLIP_WEBRTC_REPOSITORY_URL" ]] \
  || fail "DMG provenance has an unexpected WebRTC source repository"
[[ "$PROVENANCE_WEBRTC_CHECKSUM" == "$CLIP_WEBRTC_ARTIFACT_CHECKSUM" ]] \
  || fail "DMG provenance has an unexpected WebRTC binary checksum"
[[ "$PROVENANCE_WEBRTC_ARTIFACT_EXECUTABLE_SHA256" == \
   "$CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256" ]] \
  || fail "DMG provenance has an unexpected WebRTC source-artifact hash"
[[ "$PROVENANCE_WEBRTC_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "DMG provenance has an invalid packaged WebRTC hash"
[[ "$PROVENANCE_THIRD_PARTY_NOTICES_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "DMG provenance has an invalid third-party-notices hash"
[[ "$PROVENANCE_PACKAGE_RESOLUTION" == "fresh" ]] \
  || fail "DMG was not built with an isolated Swift package resolution"

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAG_COMMIT="$(git -C "$ROOT" rev-list -n 1 "$TAG")"
  [[ "$TAG_COMMIT" == "$GIT_COMMIT" ]] \
    || fail "existing local tag $TAG does not point to HEAD"
fi

"$ROOT/scripts/verify-dmg.sh" "$DMG"

MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clip-release-mount.XXXXXX")"
MOUNTED=0
STAGING_DIRECTORY=""

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_ROOT" -quiet >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_ROOT" 2>/dev/null || true
  if [[ -n "$STAGING_DIRECTORY" && -d "$STAGING_DIRECTORY" ]]; then
    rm -rf "$STAGING_DIRECTORY"
  fi
}
trap cleanup EXIT

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_ROOT" \
  "$DMG" >/dev/null \
  || fail "DMG could not be mounted"
MOUNTED=1

APP="$MOUNT_ROOT/Clip.app"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "DMG does not contain Clip.app/Contents/Info.plist"

plist_value() {
  local key="$1"
  plutil -extract "$key" raw -o - "$INFO" 2>/dev/null \
    || fail "packaged Info.plist is missing required key $key"
}

BUNDLE_IDENTIFIER="$(plist_value CFBundleIdentifier)"
PACKAGED_VERSION="$(plist_value CFBundleShortVersionString)"
PACKAGED_BUILD="$(plist_value CFBundleVersion)"
PACKAGED_FEED_URL="$(plist_value SUFeedURL)"
PACKAGED_PUBLIC_KEY="$(plist_value SUPublicEDKey)"
PACKAGED_EXECUTABLE="$APP/Contents/MacOS/Clip"
PACKAGED_SPARKLE_INFO="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Resources/Info.plist"
PACKAGED_WEBRTC_EXECUTABLE="$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
PACKAGED_THIRD_PARTY_NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
[[ -f "$PACKAGED_WEBRTC_EXECUTABLE" ]] \
  || fail "DMG does not contain the WebRTC runtime"
[[ -f "$PACKAGED_THIRD_PARTY_NOTICES" ]] \
  || fail "DMG does not contain third-party notices"
PACKAGED_EXECUTABLE_SHA256="$(
  shasum -a 256 "$PACKAGED_EXECUTABLE" | awk '{print $1}'
)"
PACKAGED_WEBRTC_EXECUTABLE_SHA256="$(
  shasum -a 256 "$PACKAGED_WEBRTC_EXECUTABLE" | awk '{print $1}'
)"
PACKAGED_THIRD_PARTY_NOTICES_SHA256="$(
  shasum -a 256 "$PACKAGED_THIRD_PARTY_NOTICES" | awk '{print $1}'
)"
PACKAGED_SPARKLE_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$PACKAGED_SPARKLE_INFO"
)"
SIGNATURE_INFO="$(codesign -dvvv "$APP" 2>&1)"

[[ "$BUNDLE_IDENTIFIER" == "com.tomaslejdung.clip" ]] \
  || fail "unexpected bundle identifier: $BUNDLE_IDENTIFIER"
[[ "$PACKAGED_VERSION" == "$VERSION" ]] \
  || fail "tag $TAG does not match packaged marketing version $PACKAGED_VERSION"
[[ "$PACKAGED_BUILD" =~ ^[1-9][0-9]*$ ]] \
  || fail "packaged build must be a positive integer"
[[ "$PACKAGED_VERSION" == "$CLIP_PROJECT_MARKETING_VERSION" ]] \
  || fail "packaged marketing version does not match Clip.xcodeproj"
[[ "$PACKAGED_BUILD" == "$CLIP_PROJECT_BUILD_VERSION" ]] \
  || fail "packaged build number does not match Clip.xcodeproj"

if [[ "$BOOTSTRAP" == "1" ]]; then
  [[ "$TAG" == "v1.0.0" && "$PACKAGED_VERSION" == "1.0.0" && "$PACKAGED_BUILD" == "1" ]] \
    || fail "bootstrap is restricted to the true first updater release, v1.0.0 build 1"
  if git -C "$ROOT" log HEAD --all --format='%H' -- docs/appcast.xml \
      | grep -q .; then
    fail "bootstrap is invalid because docs/appcast.xml already exists in Git history"
  fi
  if [[ -n "$(git -C "$ROOT" tag --list 'v*')" ]]; then
    fail "bootstrap is invalid because a local version tag already exists"
  fi

  ORIGIN_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" \
    || fail "the origin remote is required for bootstrap verification"
  case "$ORIGIN_URL" in
    "https://github.com/$REPOSITORY"|"https://github.com/$REPOSITORY.git"|"git@github.com:$REPOSITORY.git") ;;
    *) fail "origin does not point to the expected public GitHub repository" ;;
  esac
  if ! REMOTE_VERSION_TAGS="$(git -C "$ROOT" ls-remote --tags origin 'refs/tags/v*' 2>/dev/null)"; then
    fail "could not verify the public repository's remote tag state"
  fi
  [[ -z "$REMOTE_VERSION_TAGS" ]] \
    || fail "bootstrap is invalid because the public repository already has a version tag"

  FEED_PROBE="$(mktemp "${TMPDIR:-/tmp}/clip-feed-probe.XXXXXX")"
  if ! FEED_HTTP_STATUS="$(curl \
      --silent \
      --show-error \
      --location \
      --connect-timeout 15 \
      --max-time 30 \
      --output "$FEED_PROBE" \
      --write-out '%{http_code}' \
      "$EXPECTED_FEED_URL")"; then
    rm -f "$FEED_PROBE"
    fail "could not verify that the public update feed is absent"
  fi
  rm -f "$FEED_PROBE"
  [[ "$FEED_HTTP_STATUS" == "404" ]] \
    || fail "bootstrap requires an absent public feed, but it returned HTTP $FEED_HTTP_STATUS"
else
  PUBLISHED_APPCAST="$(mktemp "${TMPDIR:-/tmp}/clip-published-appcast.XXXXXX")"
  if ! curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --connect-timeout 15 \
      --max-time 30 \
      --output "$PUBLISHED_APPCAST" \
      "$EXPECTED_FEED_URL"; then
    rm -f "$PUBLISHED_APPCAST"
    fail "could not download the currently published appcast for monotonic comparison"
  fi
  if ! cmp -s "$CANONICAL_APPCAST" "$PUBLISHED_APPCAST"; then
    rm -f "$PUBLISHED_APPCAST"
    fail "tracked docs/appcast.xml does not exactly match the currently published feed"
  fi
  rm -f "$PUBLISHED_APPCAST"

  xmllint --noout "$CANONICAL_APPCAST" 2>/dev/null \
    || fail "previous appcast is not well-formed XML"
  PREVIOUS_ITEM_COUNT="$(
    xmllint --xpath 'count(/rss/channel/item)' "$CANONICAL_APPCAST" 2>/dev/null
  )"
  [[ "$PREVIOUS_ITEM_COUNT" == "1" ]] \
    || fail "previous appcast must contain exactly one current release"
  PREVIOUS_TOP_LEVEL_BUILD_COUNT="$(
    xmllint \
      --xpath 'count(/rss/channel/item/*[local-name()="version"])' \
      "$CANONICAL_APPCAST" 2>/dev/null
  )"
  PREVIOUS_ATTRIBUTE_BUILD_COUNT="$(
    xmllint \
      --xpath 'count(/rss/channel/item/enclosure/@*[local-name()="version"])' \
      "$CANONICAL_APPCAST" 2>/dev/null
  )"
  [[ "$((PREVIOUS_TOP_LEVEL_BUILD_COUNT + PREVIOUS_ATTRIBUTE_BUILD_COUNT))" == "1" ]] \
    || fail "previous appcast must express its build exactly once"
  if [[ "$PREVIOUS_TOP_LEVEL_BUILD_COUNT" == "1" ]]; then
    PREVIOUS_BUILD="$(
      xmllint \
        --xpath 'string(/rss/channel/item/*[local-name()="version"])' \
        "$CANONICAL_APPCAST" 2>/dev/null
    )"
  else
    PREVIOUS_BUILD="$(
      xmllint \
        --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="version"])' \
        "$CANONICAL_APPCAST" 2>/dev/null
    )"
  fi
  PREVIOUS_VERSION_COUNT="$(
    xmllint \
      --xpath 'count(/rss/channel/item/*[local-name()="shortVersionString"])' \
      "$CANONICAL_APPCAST" 2>/dev/null
  )"
  [[ "$PREVIOUS_VERSION_COUNT" == "1" ]] \
    || fail "previous appcast must express its marketing version exactly once"
  PREVIOUS_VERSION="$(
    xmllint \
      --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' \
      "$CANONICAL_APPCAST" 2>/dev/null
  )"
  [[ "$PREVIOUS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "previous appcast marketing version must use numeric X.Y.Z form"
  PREVIOUS_URL="$(
    xmllint \
      --xpath 'string(/rss/channel/item/enclosure/@url)' \
      "$CANONICAL_APPCAST" 2>/dev/null
  )"
  EXPECTED_PREVIOUS_URL="https://github.com/$REPOSITORY/releases/download/v$PREVIOUS_VERSION/Clip-$PREVIOUS_VERSION.dmg"
  [[ "$PREVIOUS_URL" == "$EXPECTED_PREVIOUS_URL" ]] \
    || fail "tracked appcast does not identify an immutable Clip release in $REPOSITORY"
  [[ "$PREVIOUS_BUILD" =~ ^[1-9][0-9]*$ ]] \
    || fail "previous appcast build must be a positive integer"
  if (( 10#$PACKAGED_BUILD <= 10#$PREVIOUS_BUILD )); then
    fail "packaged build $PACKAGED_BUILD must be greater than published build $PREVIOUS_BUILD"
  fi
fi
[[ "$PACKAGED_FEED_URL" == "$EXPECTED_FEED_URL" ]] \
  || fail "packaged SUFeedURL must equal $EXPECTED_FEED_URL"
[[ "$PACKAGED_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "packaged SUPublicEDKey is not a canonical 32-byte EdDSA public key"
[[ "$PROVENANCE_BUNDLE_IDENTIFIER" == "$BUNDLE_IDENTIFIER" ]] \
  || fail "packaged bundle identifier differs from build provenance"
[[ "$PROVENANCE_VERSION" == "$PACKAGED_VERSION" ]] \
  || fail "packaged marketing version differs from build provenance"
[[ "$PROVENANCE_BUILD" == "$PACKAGED_BUILD" ]] \
  || fail "packaged build differs from build provenance"
[[ "$PROVENANCE_SPARKLE_VERSION" == "$PACKAGED_SPARKLE_VERSION" ]] \
  || fail "packaged Sparkle version differs from build provenance"
[[ "$PACKAGED_SPARKLE_VERSION" == "$CLIP_SPARKLE_VERSION" ]] \
  || fail "release must embed the reviewed Sparkle $CLIP_SPARKLE_VERSION runtime"
[[ "$PROVENANCE_EXECUTABLE_SHA256" == "$PACKAGED_EXECUTABLE_SHA256" ]] \
  || fail "packaged executable differs from build provenance"
[[ "$PROVENANCE_WEBRTC_EXECUTABLE_SHA256" == \
   "$PACKAGED_WEBRTC_EXECUTABLE_SHA256" ]] \
  || fail "packaged WebRTC executable differs from build provenance"
[[ "$PROVENANCE_THIRD_PARTY_NOTICES_SHA256" == \
   "$PACKAGED_THIRD_PARTY_NOTICES_SHA256" ]] \
  || fail "packaged third-party notices differ from build provenance"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
  || fail "packaged app does not embed Sparkle.framework"
if grep -q 'Signature=adhoc' <<<"$SIGNATURE_INFO"; then
  fail "packaged app is ad-hoc signed"
fi

KEY_BYTES_FILE="$(mktemp "${TMPDIR:-/tmp}/clip-public-key.XXXXXX")"
if ! printf '%s' "$PACKAGED_PUBLIC_KEY" \
    | openssl base64 -d -A > "$KEY_BYTES_FILE" 2>/dev/null; then
  rm -f "$KEY_BYTES_FILE"
  fail "packaged SUPublicEDKey is not valid Base64"
fi
KEY_BYTE_COUNT="$(stat -f '%z' "$KEY_BYTES_FILE")"
rm -f "$KEY_BYTES_FILE"
[[ "$KEY_BYTE_COUNT" == "32" ]] \
  || fail "packaged SUPublicEDKey must decode to 32 bytes"

hdiutil detach "$MOUNT_ROOT" -quiet >/dev/null
MOUNTED=0
rmdir "$MOUNT_ROOT" 2>/dev/null || true

OUTPUT_PARENT="$(dirname "$OUTPUT_DIRECTORY")"
mkdir -p "$OUTPUT_PARENT"
STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_PARENT/.${TAG}.XXXXXX")"
ASSET_NAME="Clip-$VERSION.dmg"
STAGED_DMG="$STAGING_DIRECTORY/$ASSET_NAME"
STAGED_APPCAST="$STAGING_DIRECTORY/appcast.xml"
STAGED_NOTES="$STAGING_DIRECTORY/release-notes.md"

ditto "$DMG" "$STAGED_DMG"
ditto "$RELEASE_NOTES" "$STAGED_NOTES"

GENERATOR_ARGUMENTS=(
  --repository "$REPOSITORY"
  --tag "$TAG"
  --dmg "$STAGED_DMG"
  --output "$STAGED_APPCAST"
  --release-notes "$STAGED_NOTES"
)
if [[ -n "$GENERATE_APPCAST" ]]; then
  GENERATOR_ARGUMENTS+=(--generate-appcast "$GENERATE_APPCAST")
fi
if [[ -n "$ED_KEY_FILE" ]]; then
  GENERATOR_ARGUMENTS+=(--ed-key-file "$ED_KEY_FILE")
else
  GENERATOR_ARGUMENTS+=(--keychain-account "$KEYCHAIN_ACCOUNT")
fi

"$ROOT/scripts/generate-appcast.sh" "${GENERATOR_ARGUMENTS[@]}"
"$ROOT/scripts/validate-appcast.sh" \
  "$STAGED_APPCAST" \
  "$STAGED_DMG" \
  "$PACKAGED_VERSION" \
  "$PACKAGED_BUILD"

(
  cd "$STAGING_DIRECTORY"
  shasum -a 256 "$ASSET_NAME" appcast.xml > SHA256SUMS
)

DMG_SHA256="$(shasum -a 256 "$STAGED_DMG" | awk '{print $1}')"
APPCAST_SHA256="$(shasum -a 256 "$STAGED_APPCAST" | awk '{print $1}')"
cat > "$STAGING_DIRECTORY/release-manifest.txt" <<EOF
repository=$REPOSITORY
tag=$TAG
marketing_version=$PACKAGED_VERSION
bundle_version=$PACKAGED_BUILD
git_commit=$GIT_COMMIT
git_tree=$GIT_TREE
source_clean=$PROVENANCE_CLEAN
dmg_filename=$ASSET_NAME
dmg_sha256=$DMG_SHA256
app_executable_sha256=$PACKAGED_EXECUTABLE_SHA256
sparkle_version=$PACKAGED_SPARKLE_VERSION
sparkle_revision=$PROVENANCE_SPARKLE_REVISION
sparkle_repository=$PROVENANCE_SPARKLE_REPOSITORY
sparkle_artifact_checksum=$PROVENANCE_SPARKLE_CHECKSUM
webrtc_version=$PROVENANCE_WEBRTC_VERSION
webrtc_wrapper_revision=$PROVENANCE_WEBRTC_WRAPPER_REVISION
webrtc_upstream_revision=$PROVENANCE_WEBRTC_UPSTREAM_REVISION
webrtc_repository=$PROVENANCE_WEBRTC_REPOSITORY
webrtc_artifact_checksum=$PROVENANCE_WEBRTC_CHECKSUM
webrtc_artifact_executable_sha256=$PROVENANCE_WEBRTC_ARTIFACT_EXECUTABLE_SHA256
webrtc_executable_sha256=$PACKAGED_WEBRTC_EXECUTABLE_SHA256
third_party_notices_sha256=$PACKAGED_THIRD_PARTY_NOTICES_SHA256
swift_package_resolution=$PROVENANCE_PACKAGE_RESOLUTION
appcast_sha256=$APPCAST_SHA256
feed_url=$EXPECTED_FEED_URL
download_url=https://github.com/$REPOSITORY/releases/download/$TAG/$ASSET_NAME
EOF

mv "$STAGING_DIRECTORY" "$OUTPUT_DIRECTORY"
STAGING_DIRECTORY=""

cat <<EOF
Prepared GitHub Release files without publishing them:
  $OUTPUT_DIRECTORY/$ASSET_NAME
  $OUTPUT_DIRECTORY/appcast.xml
  $OUTPUT_DIRECTORY/release-notes.md
  $OUTPUT_DIRECTORY/SHA256SUMS
  $OUTPUT_DIRECTORY/release-manifest.txt

Verified version: $PACKAGED_VERSION ($PACKAGED_BUILD)
Verified source commit: $GIT_COMMIT

After the GitHub Release asset exists, publish the exact staged appcast through
GitHub Pages by copying it to docs/appcast.xml, committing, and pushing it.
See docs/RELEASING.md for the ordered, rollback-safe commands.
EOF
