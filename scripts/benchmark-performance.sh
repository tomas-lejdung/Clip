#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${CLIP_PERFORMANCE_RESULT_PATH:-$ROOT/.build/performance/latest.json}"
MODULE_CACHE="$ROOT/.build/ModuleCache"

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

cat <<'EOF'
Running Clip's permission-free native performance benchmark in Release mode.
This command records synthetic HEVC and processes it to H.264 CRF 24. It does not launch Clip,
request privacy permissions, run UI automation, or move the pointer.
EOF

"$ROOT/scripts/build-recording-encoder.sh"
export CLIP_RECORDING_ENCODER="$ROOT/.build/recording-encoder/install/bin/ffmpeg"

exec swift run \
  --package-path "$ROOT/Packages/ClipMedia" \
  --configuration release \
  ClipMediaPerformanceBenchmark \
  --output "$OUTPUT" \
  "$@"
