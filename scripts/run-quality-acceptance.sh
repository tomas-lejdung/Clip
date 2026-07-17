#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="$ROOT/.build/QualityAcceptanceModuleCache"

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

# Permission-free, deterministic fidelity gate. The code-rendered source has
# one-pixel rules, tiny bitmap text, color edges, scrolling content and motion
# at 30/60 FPS. Tests decode real H.264 outputs and enforce master, Crisp and
# Compact SSIM/edge floors, timestamps, profile/color metadata, trim, native
# dimensions, and byte-identical eligible Crisp reuse.
swift test \
  --package-path "$ROOT/Packages/ClipMedia" \
  --filter NativeQualityPipelineTests

echo "Deterministic native VideoToolbox quality acceptance passed."
