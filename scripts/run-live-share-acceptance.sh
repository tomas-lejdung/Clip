#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ROOT="$ROOT/server"
CORE_PACKAGE="$ROOT/Packages/ClipLiveShare"
WEBRTC_PACKAGE="$ROOT/Packages/ClipLiveShareWebRTC"
MODULE_CACHE="$ROOT/.build/ModuleCache"
GO_MODULE_CACHE="${GOMODCACHE:-$ROOT/.build/GoModuleCache}"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
SOURCE_PACKAGES="${CLIP_SOURCE_PACKAGES_PATH:-$ROOT/.build/SourcePackages}"

for command in curl go node swift xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 69
  fi
done

if [[ ! -f "$SERVER_ROOT/internal/signaling/room_v4.go" ||
      ! -f "$ROOT/Packages/ClipLiveShare/Sources/ClipLiveShare/ClipLiveShareServerRoomV4Invite.swift" ||
      ! -f "$ROOT/Packages/ClipLiveShareWebRTC/Sources/ClipLiveShareWebRTC/ClipLiveShareServerMeshPeerReconciler.swift" ]]; then
  echo "The clean-slate server-coordinated mesh is incomplete." >&2
  exit 66
fi

"$ROOT/scripts/verify-web-viewer-native-boundary.sh"

mkdir -p "$MODULE_CACHE" "$GO_MODULE_CACHE" "$SOURCE_PACKAGES"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

echo "Running authoritative opaque-room service tests..."
(
  cd "$SERVER_ROOT"
  GOCACHE="$ROOT/.build/server-room-v4-go-cache" \
    GOMODCACHE="$GO_MODULE_CACHE" go test ./...
)

echo "Running dependency-free browser invite, crypto, mesh, and viewer tests..."
node --test "$SERVER_ROOT"/web/tests/*.test.mjs

echo "Running v4 invite, admission, roster, and crypto tests..."
swift test \
  --package-path "$CORE_PACKAGE" \
  --filter ClipLiveShareServerRoomV4
swift test \
  --package-path "$CORE_PACKAGE" \
  --filter ClipLiveShareWebMediaControlInteropTests

echo "Running full-mesh transport and real WebRTC loopback tests..."
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter ClipLiveShareServerRoomV4
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter ClipLiveShareServerMesh
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter WebRTCExactCodecPreferenceTests
swift test \
  --package-path "$WEBRTC_PACKAGE" \
  --manifest-cache none \
  --filter ClipLiveShareNativeV3RealWebRTCLoopbackTests

echo "Running real localhost 2/3/4-participant server-room acceptance..."
"$ROOT/scripts/run-server-room-v4-acceptance.sh"

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
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
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
  -only-testing:ClipTests/ServerCoordinatedMeshRoomSessionTests
  -only-testing:ClipTests/ServerCoordinatedMeshMediaRuntimeTests
  -only-testing:ClipTests/ServerCoordinatedMeshParticipantCoordinatorTests
  -only-testing:ClipTests/ServerCoordinatedMeshThreeParticipantFlowTests
  -only-testing:ClipTests/MeshParticipantLocalPublicationControllerTests
  -only-testing:ClipTests/MeshRoomPresentationModelTests
)

echo "Running hosted server-coordinated participant-mesh gates..."
xcodebuild "${XCODE_ARGUMENTS[@]}"

echo "Clip server-coordinated mesh local acceptance passed."
echo "Covered: client-secret stable invite, authoritative opaque rosters, 1/3/6 direct pair topology, encrypted signaling, pair isolation, symmetric publication/control/collaboration, ordinary leave/reconnect, and terminal creator departure."
echo "Not claimed: remote Internet/TURN availability, real ScreenCaptureKit or audio hardware, or the final signed multi-process GUI run."
