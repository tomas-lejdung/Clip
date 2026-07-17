#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEVELOPER_DIR="$(xcode-select -p)"
PLATFORM_DEVELOPER="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
XCTEST_MODULES="$PLATFORM_DEVELOPER/usr/lib"
TEST_FRAMEWORKS="$PLATFORM_DEVELOPER/Library/Frameworks"
TESTING_PLUGIN="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
MODULE_CACHE="$ROOT/.build/TypecheckModuleCache"
CORE_MODULES="$ROOT/Packages/ClipCore/.build/arm64-apple-macosx/debug/Modules"
MEDIA_MODULES="$ROOT/Packages/ClipMedia/.build/arm64-apple-macosx/debug/Modules"
CORE_OBJECTS=("$ROOT"/Packages/ClipCore/.build/arm64-apple-macosx/debug/ClipCore.build/*.swift.o)
MEDIA_OBJECTS=("$ROOT"/Packages/ClipMedia/.build/arm64-apple-macosx/debug/ClipMedia.build/*.swift.o)
MANUAL_BUILD="$ROOT/.build/Manual"
SOURCES=()
TEST_SOURCES=()
UI_TEST_SOURCES=()

mkdir -p "$MODULE_CACHE" "$MANUAL_BUILD"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

"$ROOT/scripts/audit-project.sh"

while IFS= read -r -d '' source; do
  SOURCES+=("$source")
done < <(find "$ROOT/Clip" -type f -name '*.swift' -print0)
while IFS= read -r -d '' source; do
  TEST_SOURCES+=("$source")
done < <(find "$ROOT/ClipTests" -type f -name '*.swift' -print0)
while IFS= read -r -d '' source; do
  UI_TEST_SOURCES+=("$source")
done < <(find "$ROOT/ClipUITests" -type f -name '*.swift' -print0)

swift test --package-path "$ROOT/Packages/ClipCore"
swift test --package-path "$ROOT/Packages/ClipMedia"

xcrun swiftc \
  -typecheck \
  -swift-version 6 \
  -strict-concurrency=complete \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$CORE_MODULES" \
  -I "$MEDIA_MODULES" \
  "${SOURCES[@]}"

# Type checking does not exercise Swift IR generation. Link a real arm64
# executable as a second gate so compiler crashes and unresolved symbols fail.
xcrun swiftc \
  -emit-executable \
  -o "$MANUAL_BUILD/Clip" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$CORE_MODULES" \
  -I "$MEDIA_MODULES" \
  "${SOURCES[@]}" \
  "${CORE_OBJECTS[@]}" \
  "${MEDIA_OBJECTS[@]}"

file "$MANUAL_BUILD/Clip" | grep -q "Mach-O 64-bit executable arm64"

# Emit a testable Clip module, then compile every application and UI test source
# even when xcodebuild is unavailable during Xcode first-launch initialization.
xcrun swiftc \
  -emit-module \
  -parse-as-library \
  -enable-testing \
  -module-name Clip \
  -emit-module-path "$MANUAL_BUILD/Clip.swiftmodule" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$CORE_MODULES" \
  -I "$MEDIA_MODULES" \
  "${SOURCES[@]}"

xcrun swiftc \
  -typecheck \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$MANUAL_BUILD" \
  -I "$CORE_MODULES" \
  -I "$MEDIA_MODULES" \
  -I "$XCTEST_MODULES" \
  -F "$TEST_FRAMEWORKS" \
  -load-plugin-library "$TESTING_PLUGIN" \
  "${TEST_SOURCES[@]}"

xcrun swiftc \
  -typecheck \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$XCTEST_MODULES" \
  -F "$TEST_FRAMEWORKS" \
  "${UI_TEST_SOURCES[@]}"

# Compile the explicitly opted-in real lanes as a separate conditional source
# shape. The ordinary lane above catches warnings in dormant skip branches;
# this one proves the permission-backed implementations continue to compile.
xcrun swiftc \
  -typecheck \
  -D CLIP_REAL_CAPTURE_ACCEPTANCE \
  -D CLIP_REAL_AUDIO_ACCEPTANCE \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx15.0 \
  -sdk "$SDK" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$XCTEST_MODULES" \
  -F "$TEST_FRAMEWORKS" \
  "${UI_TEST_SOURCES[@]}"

"$ROOT/scripts/build-test-helper.sh" >/dev/null
