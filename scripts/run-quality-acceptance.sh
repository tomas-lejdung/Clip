#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$ROOT/.build/QualityAcceptanceModuleCache"

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

# Production media regression gate. Synthetic frames bypass screen capture and
# privacy APIs; hardware HEVC and the shipped x264 recipe are exercised directly.
"$ROOT/scripts/build-recording-encoder.sh"
swift test --package-path "$ROOT/Packages/ClipMedia"

echo "Production recording, processing, and passthrough export acceptance passed."
