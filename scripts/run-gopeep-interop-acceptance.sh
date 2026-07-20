#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOPEEP_ROOT="${CLIP_GOPEEP_ROOT:-$ROOT/../gopeep}"
PACKAGE="$ROOT/Packages/ClipLiveShareWebRTC"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clip-gopeep-interop.XXXXXX")"
MODULE_CACHE="$ROOT/.build/ModuleCache"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$GOPEEP_ROOT/go.mod" || ! -f "$GOPEEP_ROOT/cmd/server/main.go" ]]; then
  echo "GoPeep source checkout not found at: $GOPEEP_ROOT" >&2
  echo "Set CLIP_GOPEEP_ROOT to the compatible GoPeep checkout." >&2
  exit 66
fi

PORT="${CLIP_GOPEEP_INTEROP_PORT:-}"
if [[ -z "$PORT" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    PORT="$((30000 + RANDOM % 20000))"
    if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      break
    fi
    PORT=""
  done
fi
if [[ -z "$PORT" ]]; then
  echo "Could not find an unused loopback port." >&2
  exit 69
fi

echo "Building the current GoPeep v1 signaling server and viewer..."
(
  cd "$GOPEEP_ROOT"
  # The reference checkout carries a stale vendor directory. `-mod=readonly`
  # deliberately ignores it without mutating go.mod, go.sum, or vendor.
  GOCACHE="$WORK_DIR/go-cache" go build -mod=readonly \
    -o "$WORK_DIR/gopeep-server" ./cmd/server
)

"$WORK_DIR/gopeep-server" -port "$PORT" >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!

READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl --fail --silent "http://127.0.0.1:$PORT/CLIP-HEALTH-00" \
      >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.1
done
if [[ "$READY" != "1" ]]; then
  echo "GoPeep server did not become ready. Server log:" >&2
  sed -n '1,160p' "$WORK_DIR/server.log" >&2
  exit 70
fi

echo "Running real GoPeep routing, H.264 -> VP8 -> VP9 -> AV1 -> H.264 switching, and control-channel acceptance..."
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
CLIP_RUN_GOPEEP_INTEROP=1 \
CLIP_RUN_GOPEEP_WEBKIT_ACCEPTANCE=1 \
CLIP_GOPEEP_INTEROP_SIGNAL_URL="ws://127.0.0.1:$PORT" \
swift test --package-path "$PACKAGE"

echo "GoPeep interoperability acceptance passed."
echo "Covered: real reserve/auth/join/offer/answer/ICE routing and served viewer artifact."
echo "Covered: exact H.264/VP8 plus preferred VP9 -> VP8 and AV1 -> VP9 -> VP8 per-viewer negotiation."
echo "Covered: hardware H.264 and native-geometry software VP8/VP9-profile-0/AV1 encode/decode."
echo "Covered: one WebKit session with stable tracks across H.264 -> VP8 -> VP9 -> AV1 -> H.264, actual outbound-codec stats, and ordered gopeep-control metadata."
echo "Not claimed: remote Internet/TURN traversal."
