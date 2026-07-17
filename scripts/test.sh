#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${CLIP_DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
MODULE_CACHE="$ROOT/.build/ModuleCache"
TEST_CONFIGURATION="${CLIP_TEST_CONFIGURATION:-Debug}"
TEST_SELECTION=(-only-testing:ClipTests)
REAL_CAPTURE_CONDITION=""

source "$ROOT/scripts/signing-config.sh"
clip_warn_if_ad_hoc_signing

case "$TEST_CONFIGURATION" in
  Debug|Release) ;;
  *)
    echo "CLIP_TEST_CONFIGURATION must be Debug or Release." >&2
    exit 64
    ;;
esac

XCODE_DEVELOPMENT_TEAM=""
if ! clip_signing_is_ad_hoc; then
  XCODE_DEVELOPMENT_TEAM="$(clip_resolved_development_team)" || {
    echo "Could not resolve a unique development team for signing identity '$CLIP_CODE_SIGN_IDENTITY'" >&2
    exit 1
  }
fi

if [[ $# -gt 2 ]]; then
  echo "Usage: $0 [--ui --allow-pointer-control|--real-ui|--real-fullscreen-ui|--real-audio-ui]" >&2
  exit 64
fi

case "${1:-}" in
  "")
    if [[ $# -ne 0 ]]; then
      echo "Usage: $0 [--ui --allow-pointer-control|--real-ui|--real-fullscreen-ui|--real-audio-ui]" >&2
      exit 64
    fi
    ;;
  --ui)
    if [[ "${2:-}" != "--allow-pointer-control" ]]; then
      cat >&2 <<'EOF'
The UI-test lane uses XCTest automation, which moves the visible macOS pointer
and types into real app windows. To acknowledge that behavior, run:

  scripts/test.sh --ui --allow-pointer-control

Run scripts/test.sh without arguments for the non-UI test suite.
EOF
      exit 64
    fi
    cat >&2 <<'EOF'
WARNING: XCTest UI automation will drive the visible macOS pointer and
keyboard. Leave the Mac idle until the command finishes.
EOF
    TEST_SELECTION=(-only-testing:ClipTests -only-testing:ClipUITests)
    ;;
  --real-ui)
    if [[ $# -ne 1 ]]; then
      echo "--real-ui must be invoked by scripts/run-real-capture-acceptance.sh." >&2
      exit 64
    fi
    if [[ "${CLIP_RUN_REAL_CAPTURE_ACCEPTANCE:-0}" != "1" ]]; then
      echo "--real-ui is permission-gated; use scripts/run-real-capture-acceptance.sh." >&2
      exit 64
    fi
    REAL_CAPTURE_CONDITION="CLIP_REAL_CAPTURE_ACCEPTANCE"
    TEST_SELECTION=(
      -only-testing:ClipUITests/ClipLaunchTests/testRealScreenCaptureCopyRoundTripWhenExplicitlyEnabled
    )
    ;;
  --real-fullscreen-ui)
    if [[ $# -ne 1 ]]; then
      echo "--real-fullscreen-ui must be invoked by scripts/run-real-fullscreen-acceptance.sh." >&2
      exit 64
    fi
    if [[ "${CLIP_RUN_REAL_FULLSCREEN_ACCEPTANCE:-0}" != "1" ]]; then
      echo "--real-fullscreen-ui is permission-gated; use scripts/run-real-fullscreen-acceptance.sh." >&2
      exit 64
    fi
    REAL_CAPTURE_CONDITION="CLIP_REAL_CAPTURE_ACCEPTANCE"
    TEST_SELECTION=(
      -only-testing:ClipUITests/ClipLaunchTests/testRealFullscreenCapturePreviewFlowWhenExplicitlyEnabled
    )
    ;;
  --real-audio-ui)
    if [[ $# -ne 1 ]]; then
      echo "--real-audio-ui must be invoked by scripts/run-real-audio-acceptance.sh." >&2
      exit 64
    fi
    if [[ "${CLIP_RUN_REAL_AUDIO_ACCEPTANCE:-0}" != "1" ]]; then
      echo "--real-audio-ui is permission-gated; use scripts/run-real-audio-acceptance.sh." >&2
      exit 64
    fi
    REAL_CAPTURE_CONDITION="CLIP_REAL_AUDIO_ACCEPTANCE"
    TEST_SELECTION=(
      -only-testing:ClipUITests/ClipLaunchTests/testRealMicrophoneCaptureProducesNonemptyAudioTrack
      -only-testing:ClipUITests/ClipLaunchTests/testRealSystemAudioCaptureProducesNonemptyAudioTrack
      -only-testing:ClipUITests/ClipLaunchTests/testRealMicrophoneAndSystemAudioCaptureProducesMixedAudioTrack
    )
    ;;
  *)
    echo "Usage: $0 [--ui --allow-pointer-control|--real-ui|--real-fullscreen-ui|--real-audio-ui]" >&2
    exit 64
    ;;
esac

mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

swift test --package-path "$ROOT/Packages/ClipCore"
swift test --package-path "$ROOT/Packages/ClipMedia"

# Keep the command array non-empty for the system Bash 3.2 shipped by macOS.
# Expanding an empty array under `set -u` is otherwise reported as an unbound
# variable, which prevented the ordinary (no explicit xcresult path) lane from
# reaching xcodebuild.
XCODEBUILD_ARGUMENTS=(
  -project "$ROOT/Clip.xcodeproj"
  -scheme Clip
  -configuration "$TEST_CONFIGURATION"
  -destination "platform=macOS,arch=arm64"
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="$CLIP_CODE_SIGN_IDENTITY"
  # Hosted tests use `@testable import Clip`. Debug enables this by default;
  # make the explicit Release test lane equivalent without changing the normal
  # Release/package build settings.
  ENABLE_TESTABILITY=YES
  CLIP_RUN_REAL_CAPTURE_ACCEPTANCE="${CLIP_RUN_REAL_CAPTURE_ACCEPTANCE:-0}"
  CLIP_REAL_CAPTURE_CONDITION="$REAL_CAPTURE_CONDITION"
)
if [[ -n "$XCODE_DEVELOPMENT_TEAM" ]]; then
  XCODEBUILD_ARGUMENTS+=(
    DEVELOPMENT_TEAM="$XCODE_DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Manual
  )
fi
if [[ -n "${CLIP_XCRESULT_PATH:-}" ]]; then
  XCODEBUILD_ARGUMENTS+=(-resultBundlePath "$CLIP_XCRESULT_PATH")
fi
XCODEBUILD_ARGUMENTS+=(test "${TEST_SELECTION[@]}")

exec xcodebuild "${XCODEBUILD_ARGUMENTS[@]}"
