#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ROOT="$ROOT/server"
CORE_PACKAGE="$ROOT/Packages/ClipLiveShare"
WEBRTC_PACKAGE="$ROOT/Packages/ClipLiveShareWebRTC"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clip-live-share-acceptance.XXXXXX")"
MODULE_CACHE="$ROOT/.build/ModuleCache"
GO_MODULE_CACHE="${GOMODCACHE:-$ROOT/.build/GoModuleCache}"
SERVER_PID=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 && -f "$WORK_DIR/server.log" ]]; then
    echo "Clip Live Share server log:" >&2
    sed -n '1,200p' "$WORK_DIR/server.log" >&2
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in curl go lsof node rg swift; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 69
  fi
done

if [[ ! -f "$SERVER_ROOT/go.mod" || \
      ! -f "$SERVER_ROOT/cmd/clip-live-share-server/main.go" || \
      ! -f "$SERVER_ROOT/web/clip-protocol.test.mjs" ]]; then
  echo "The in-repository Clip Live Share server/viewer is incomplete." >&2
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
if [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ || "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
  echo "CLIP_LIVE_SHARE_ACCEPTANCE_PORT must be an unused TCP port." >&2
  exit 64
fi

mkdir -p "$MODULE_CACHE" "$GO_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

echo "Running Clip Live Share Go service tests..."
(
  cd "$SERVER_ROOT"
  GOCACHE="$WORK_DIR/go-cache" GOMODCACHE="$GO_MODULE_CACHE" go test ./...
)

echo "Running browser protocol and cryptography tests..."
(
  cd "$SERVER_ROOT"
  node --test web/clip-protocol.test.mjs
)

echo "Building and launching the in-repository service on loopback..."
(
  cd "$SERVER_ROOT"
  GOCACHE="$WORK_DIR/go-cache" GOMODCACHE="$GO_MODULE_CACHE" \
    go build -trimpath -o "$WORK_DIR/clip-live-share-server" \
      ./cmd/clip-live-share-server
)

CLIP_SERVER_ADDRESS="127.0.0.1:$PORT" \
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
  echo "Clip Live Share server did not become ready." >&2
  exit 70
fi

curl --fail --silent "http://127.0.0.1:$PORT/version" \
  >"$WORK_DIR/version.json"
curl --fail --silent "http://127.0.0.1:$PORT/.well-known/clip-live-share" \
  >"$WORK_DIR/capabilities.json"
curl --fail --silent "http://127.0.0.1:$PORT/.well-known/clip-native-rendezvous" \
  >"$WORK_DIR/native-capabilities.json"
curl --fail --silent "http://127.0.0.1:$PORT/CLIP-ACCEPTANCE" \
  >"$WORK_DIR/viewer.html"

rg --fixed-strings --quiet '"protocol":"clip-live-share"' \
  "$WORK_DIR/capabilities.json" \
  || { echo "Capabilities did not identify clip-live-share." >&2; exit 65; }
rg --fixed-strings --quiet '"versions":[1]' "$WORK_DIR/capabilities.json" \
  || { echo "Capabilities did not advertise protocol v1." >&2; exit 65; }
rg --fixed-strings --quiet '"protocol":"clip-native-rendezvous"' \
  "$WORK_DIR/native-capabilities.json" \
  || { echo "Native capabilities did not identify Clip rendezvous." >&2; exit 65; }
rg --fixed-strings --quiet '"apiVersion":1' \
  "$WORK_DIR/native-capabilities.json" \
  || { echo "Native rendezvous did not advertise API v1." >&2; exit 65; }
rg --fixed-strings --quiet '"messageVersion":2' \
  "$WORK_DIR/native-capabilities.json" \
  || { echo "Native rendezvous did not advertise message v2." >&2; exit 65; }
rg --fixed-strings --quiet 'Clip Live Share' "$WORK_DIR/viewer.html" \
  || { echo "The embedded browser viewer was not served." >&2; exit 65; }

echo "Running native protocol, crypto, state, signaling, and WebRTC tests..."
swift test --package-path "$CORE_PACKAGE"
CLIP_RUN_NATIVE_WEBKIT_ACCEPTANCE=1 \
CLIP_LIVE_SHARE_ACCEPTANCE_ENDPOINT="http://127.0.0.1:$PORT" \
  swift test --package-path "$WEBRTC_PACKAGE"

echo "Clip Live Share local acceptance passed."
echo "Covered: in-memory room ownership, native rendezvous discovery/routing, fresh signed-room friendship admission/removal, encrypted signaling, simultaneous four-stream native protocol peers, control after signaling handoff, browser crypto/viewer assets, and decoded stereo Opus waveform quality through the embedded WebKit viewer."
echo "Not claimed: two separate Clip processes, simultaneous WebKit and native rendering on one host, termination of the Go process during live media, real ScreenCaptureKit content, audible hardware output, remote Internet/TURN traversal, overlay exclusion, or signed-DMG packaging."
