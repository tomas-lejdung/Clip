#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ROOT="$ROOT/server"
CORE_PACKAGE="$ROOT/Packages/ClipLiveShare"
WEBRTC_PACKAGE="$ROOT/Packages/ClipLiveShareWebRTC"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clip-native-v3-acceptance.XXXXXX")"
MODULE_CACHE="$ROOT/.build/ModuleCache"
GO_MODULE_CACHE="${GOMODCACHE:-$ROOT/.build/GoModuleCache}"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
SOURCE_PACKAGES="${CLIP_SOURCE_PACKAGES_PATH:-$ROOT/.build/SourcePackages}"
SERVER_PID=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 && -f "$WORK_DIR/server.log" ]]; then
    echo "Clip native-v3 rendezvous server log:" >&2
    sed -n '1,200p' "$WORK_DIR/server.log" >&2
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in curl go lsof rg swift xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 69
  fi
done

if [[ ! -f "$SERVER_ROOT/go.mod" ||
      ! -f "$SERVER_ROOT/cmd/clip-live-share-server/main.go" ||
      ! -f "$SERVER_ROOT/internal/signaling/native_rendezvous.go" ]]; then
  echo "The in-repository Clip native-v3 rendezvous service is incomplete." >&2
  exit 66
fi

PORT="${CLIP_LIVE_SHARE_ACCEPTANCE_PORT:-}"
if [[ -z "$PORT" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    PORT="$((30000 + RANDOM % 20000))"
    if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      break
    fi
    PORT=""
  done
fi
if [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ||
      "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
  echo "CLIP_LIVE_SHARE_ACCEPTANCE_PORT must be an unused TCP port." >&2
  exit 64
fi

mkdir -p "$MODULE_CACHE" "$GO_MODULE_CACHE" "$SOURCE_PACKAGES"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

echo "Running native-v3 rendezvous service tests..."
(
  cd "$SERVER_ROOT"
  GOCACHE="$WORK_DIR/go-cache" GOMODCACHE="$GO_MODULE_CACHE" go test ./...
)

echo "Building and launching the native-v3 rendezvous service on loopback..."
(
  cd "$SERVER_ROOT"
  GOCACHE="$WORK_DIR/go-cache" GOMODCACHE="$GO_MODULE_CACHE" \
    go build -trimpath -o "$WORK_DIR/clip-live-share-server" \
      ./cmd/clip-live-share-server
)

CLIP_SERVER_ADDRESS="127.0.0.1:$PORT" \
CLIP_SERVER_ICE_SERVERS_JSON='[{"urls":["stun:stun.example.test:3478"]},{"urls":["turns:turn.example.test:5349"],"username":"acceptance","credential":"ephemeral"}]' \
  "$WORK_DIR/clip-live-share-server" >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!

READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl --fail --silent "http://127.0.0.1:$PORT/healthz" \
      >"$WORK_DIR/health.json" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 0.1
done
if [[ "$READY" != "1" ]]; then
  echo "Clip native-v3 rendezvous server did not become ready." >&2
  exit 70
fi

curl --fail --silent "http://127.0.0.1:$PORT/version" \
  >"$WORK_DIR/version.json"
curl --fail --silent \
  "http://127.0.0.1:$PORT/.well-known/clip-native-rendezvous" \
  >"$WORK_DIR/native-capabilities.json"

rg --fixed-strings --quiet '"protocol":"clip-native-rendezvous"' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Capabilities did not identify native rendezvous." >&2; exit 65; }
rg --fixed-strings --quiet '"apiVersion":3' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Native rendezvous did not advertise API v3." >&2; exit 65; }
rg --fixed-strings --quiet '"messageVersion":3' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Native rendezvous did not advertise message v3." >&2; exit 65; }
rg --fixed-strings --quiet \
  '"ownerWebSocketPathTemplate":"/api/native/v3/rendezvous/{rendezvous}/owner"' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Native rendezvous did not advertise its v3 owner route." >&2; exit 65; }
rg --fixed-strings --quiet \
  '"candidateWebSocketPathTemplate":"/api/native/v3/rendezvous/{rendezvous}/candidate"' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Native rendezvous did not advertise its v3 candidate route." >&2; exit 65; }
if rg --quiet \
  '"(hostWebSocketPathTemplate|viewerWebSocketPathTemplate)"' \
  "$WORK_DIR/native-capabilities.json"; then
  echo "Native rendezvous advertised a removed compatibility key." >&2
  exit 65
fi
rg --fixed-strings --quiet '"turns:turn.example.test:5349"' \
  "$WORK_DIR/native-capabilities.json" ||
  { echo "Native capabilities did not carry validated ICE/TURN." >&2; exit 65; }

echo "Running native-v3 protocol and rendezvous package gates..."
swift test \
  --package-path "$CORE_PACKAGE" \
  --filter ClipLiveShareNativeV3
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter ClipNativeRendezvousTransportTests
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter ClipLiveShareNativeV3MeshPeerLinkManagerTests

source "$ROOT/scripts/signing-config.sh"
XCODE_CODE_SIGN_IDENTITY="$(clip_xcode_signing_identity)"
XCODE_DEVELOPMENT_TEAM=""
if ! clip_signing_is_ad_hoc; then
  XCODE_DEVELOPMENT_TEAM="$(clip_resolved_development_team)"
fi

XCODE_ARGUMENTS=(
  -project "$ROOT/Clip.xcodeproj"
  -scheme Clip
  -configuration Debug
  -destination "platform=macOS,arch=arm64"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="$XCODE_CODE_SIGN_IDENTITY"
  ENABLE_TESTABILITY=YES
)
if [[ -n "$XCODE_DEVELOPMENT_TEAM" ]]; then
  XCODE_ARGUMENTS+=(
    DEVELOPMENT_TEAM="$XCODE_DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Manual
  )
fi
XCODE_ARGUMENTS+=(
  test
  -only-testing:ClipTests/MeshParticipantBootstrapCoordinatorTests
  -only-testing:ClipTests/MeshParticipantEncryptedRendezvousTests
  -only-testing:ClipTests/MeshParticipantLocalPublicationControllerTests
  -only-testing:ClipTests/MeshParticipantRoomConnectionSessionTests
  -only-testing:ClipTests/MeshParticipantRuntimeTests
  -only-testing:ClipTests/MeshRoomPresentationModelTests
  -only-testing:ClipTests/NativeV3MeshIntegrationAcceptanceTests
)

echo "Running hosted native-v3 participant-mesh gates..."
xcodebuild "${XCODE_ARGUMENTS[@]}"

echo "Clip native-v3 local acceptance passed."
echo "Covered: native-only HTTP discovery, validated ICE/TURN capabilities, opaque rendezvous ownership and routing, encrypted v3 bootstrap, four-participant full mesh, symmetric publication/control/collaboration, participant removal, and deterministic leadership succession."
echo "Not claimed: real remote Internet/TURN traversal, real ScreenCaptureKit content, microphone/system-audio hardware, or a signed-DMG multi-process GUI run."
