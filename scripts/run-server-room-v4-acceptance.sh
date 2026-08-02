#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clip-server-room-v4.XXXXXX")"
SERVER_BIN="$WORK_DIR/clip-live-share-server"
SERVER_LOG="$WORK_DIR/server.log"
PORT=$((18000 + ($$ % 20000)))
ENDPOINT="http://127.0.0.1:$PORT"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT_DIR/.build/server-room-v4-go-cache"
mkdir -p "$ROOT_DIR/.build/server-room-v4-module-cache"

(
  cd "$ROOT_DIR/server"
  GOCACHE="$ROOT_DIR/.build/server-room-v4-go-cache" \
    go build -o "$SERVER_BIN" ./cmd/clip-live-share-server
)

CLIP_SERVER_ADDRESS="127.0.0.1:$PORT" \
CLIP_SERVER_ICE_SERVERS_JSON='[{"urls":["stun:127.0.0.1:3478"]}]' \
CLIP_SERVER_RECONNECT_GRACE="5s" \
  "$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
  if curl --fail --silent "$ENDPOINT/healthz" >/dev/null; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG" >&2
    echo "The local v4 room service exited before becoming healthy." >&2
    exit 1
  fi
  sleep 0.05
done

if ! curl --fail --silent "$ENDPOINT/healthz" >/dev/null; then
  cat "$SERVER_LOG" >&2
  echo "The local v4 room service did not become healthy." >&2
  exit 1
fi

# This acceptance package points at local source packages. Clean only its
# dedicated scratch directory so deleted clean-slate protocol files cannot
# survive in SwiftPM's incremental source list between runs.
swift package \
  --package-path "$ROOT_DIR/Tools/ClipServerRoomV4Acceptance" \
  --scratch-path "$ROOT_DIR/.build/server-room-v4-acceptance" \
  clean

CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/server-room-v4-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/server-room-v4-module-cache" \
  swift run \
    --package-path "$ROOT_DIR/Tools/ClipServerRoomV4Acceptance" \
    --scratch-path "$ROOT_DIR/.build/server-room-v4-acceptance" \
    ClipServerRoomV4Acceptance \
    --endpoint "$ENDPOINT"

# The browser and native app intentionally consume the same fragment-secret
# invite. Keep the shared Swift/JavaScript fixture in the required acceptance
# path so a future web viewer cannot silently drift from the native grammar or
# cryptographic context binding.
node --test \
  "$ROOT_DIR/Packages/ClipLiveShare/Web/clip-server-room-v4-invite.test.mjs"

echo "Clip server-room v4 local acceptance passed."
