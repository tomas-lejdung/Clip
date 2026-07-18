#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${CLIP_SETTINGS_SNAPSHOT_DERIVED_DATA:-$ROOT/.build/DerivedDataSettingsSnapshots}"
OUTPUT_DIRECTORY="${1:-$ROOT/.build/settings-snapshots}"
MODULE_CACHE="$ROOT/.build/SettingsSnapshotModuleCache"
XCTESTRUN_COPY="$DERIVED_DATA/Build/Products/SettingsSnapshots.xctestrun"

mkdir -p "$OUTPUT_DIRECTORY" "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

xcodebuild build-for-testing \
  -project "$ROOT/Clip.xcodeproj" \
  -scheme Clip \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClipTests/SettingsVisualSnapshotTests

GENERATED_XCTESTRUN="$(
  find "$DERIVED_DATA/Build/Products" \
    -maxdepth 1 \
    -name '*.xctestrun' \
    ! -name 'SettingsSnapshots.xctestrun' \
    -print \
    -quit
)"
if [[ -z "$GENERATED_XCTESTRUN" ]]; then
  echo "Xcode did not produce an xctestrun file for the Settings snapshot lane." >&2
  exit 1
fi

cp "$GENERATED_XCTESTRUN" "$XCTESTRUN_COPY"
/usr/bin/plutil -insert \
  ClipTests.EnvironmentVariables.CLIP_SETTINGS_SNAPSHOT_DIRECTORY \
  -string "$OUTPUT_DIRECTORY" \
  "$XCTESTRUN_COPY"

xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN_COPY" \
  -destination "platform=macOS,arch=arm64" \
  -only-testing:ClipTests/SettingsVisualSnapshotTests/testRenderEverySettingsTabAtTopAndBottom

EXPECTED_SNAPSHOT_COUNT=10
ACTUAL_SNAPSHOT_COUNT="$(
  find "$OUTPUT_DIRECTORY" \
    -maxdepth 1 \
    -name 'settings-*-*.png' \
    -type f \
    | wc -l \
    | tr -d '[:space:]'
)"
if [[ "$ACTUAL_SNAPSHOT_COUNT" -ne "$EXPECTED_SNAPSHOT_COUNT" ]] ||
   [[ ! -f "$OUTPUT_DIRECTORY/settings-snapshots.json" ]]; then
  echo "Expected 10 Settings PNGs and a manifest, found $ACTUAL_SNAPSHOT_COUNT PNGs." >&2
  exit 1
fi

echo "Settings visual-audit snapshots: $OUTPUT_DIRECTORY"
