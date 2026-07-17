#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIRECTORY="$ROOT/.build/Acceptance"
MODULE_CACHE="$ROOT/.build/AcceptanceModuleCache"
OUTPUT="$BUILD_DIRECTORY/ClipTestHelper"
SOURCES=("$ROOT"/ClipTestHelper/*.swift)

mkdir -p "$BUILD_DIRECTORY" "$MODULE_CACHE"

xcrun swiftc \
  -emit-executable \
  -o "$OUTPUT" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$MODULE_CACHE" \
  "${SOURCES[@]}"

file "$OUTPUT" | grep -q "Mach-O 64-bit executable arm64"
echo "$OUTPUT"
