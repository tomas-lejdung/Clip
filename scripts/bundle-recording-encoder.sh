#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/recording-encoder-config.sh"
APP="${1:?Usage: bundle-recording-encoder.sh /path/to/Clip.app}"
[[ -d "$APP/Contents" ]] || { echo 'Missing app bundle' >&2; exit 1; }
"$ROOT/scripts/build-recording-encoder.sh"
BUILD="$ROOT/.build/recording-encoder"
DEST="$APP/Contents/Resources/RecordingEncoderSources"
mkdir -p "$APP/Contents/Helpers" "$DEST"
ditto "$BUILD/install/bin/ffmpeg" "$APP/Contents/Helpers/ffmpeg"
# Distribute corresponding complete source, licenses, and the exact build script
# with the standalone GPL encoder executable instead of relying on a download offer.
ditto "$BUILD/sources/ffmpeg-8.0.tar.xz" "$DEST/ffmpeg-8.0.tar.xz"
ditto "$BUILD/sources/x264-b35605a.tar.bz2" "$DEST/x264-b35605a.tar.bz2"
ditto "$ROOT/scripts/build-recording-encoder.sh" "$DEST/build-recording-encoder.sh"
ditto "$ROOT/scripts/recording-encoder-config.sh" "$DEST/recording-encoder-config.sh"
ditto "$BUILD/ffmpeg-8.0/COPYING.GPLv2" "$DEST/COPYING.GPLv2"
ditto "$BUILD/x264-b35605a/COPYING" "$DEST/x264-COPYING"
ditto "$ROOT/Clip/Resources/RecordingEncoderNotices.txt" "$APP/Contents/Resources/RecordingEncoderNotices.txt"
ditto "$BUILD/ffmpeg-8.0/ffbuild/config.log" "$DEST/config.log"
"$BUILD/install/bin/ffmpeg" -version > "$DEST/build-version.txt" 2>&1
[[ -s "$DEST/build-version.txt" ]] || { echo 'Could not inspect the encoder build' >&2; exit 1; }
shasum -a 256 "$APP/Contents/Helpers/ffmpeg" > "$DEST/unsigned-binary-sha256.txt"
cat > "$DEST/manifest.txt" <<EOF
schema=1
ffmpeg_version=$CLIP_FFMPEG_VERSION
ffmpeg_source_sha256=$CLIP_FFMPEG_SOURCE_SHA256
x264_revision=$CLIP_X264_REVISION
x264_source_sha256=$CLIP_X264_SOURCE_SHA256
build_script_sha256=$(shasum -a 256 "$DEST/build-recording-encoder.sh" | awk '{print $1}')
build_config_sha256=$(shasum -a 256 "$DEST/recording-encoder-config.sh" | awk '{print $1}')
normalized_payload_sha256=$(clip_recording_encoder_payload_sha256 "$APP/Contents/Helpers/ffmpeg")
EOF
cat > "$DEST/README.txt" <<'EOF'
Corresponding source for Clip's standalone recording encoder

The source archives are unmodified and their hashes are pinned in the build script.
To rebuild on an Apple Silicon Mac with Xcode command-line tools:
1. Create a working directory with scripts/ and .build/recording-encoder/sources/.
2. Copy build-recording-encoder.sh and recording-encoder-config.sh into scripts/.
3. Copy the two source archives into .build/recording-encoder/sources/.
4. Run bash scripts/build-recording-encoder.sh from that directory.
The executable is created at .build/recording-encoder/install/bin/ffmpeg.
No Homebrew packages are required. The existing archives avoid network downloads.

The binary uses system frameworks and statically linked x264 only. It is invoked
as a separate process by Clip. COPYING.GPLv2 and x264-COPYING contain the full
license terms. build-version.txt and config.log identify this exact build.
EOF

# Direct Xcode builds/hosted tests invoke this build phase before host signing.
# Shell/manual builds sign explicitly with the same helper afterwards.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  "$ROOT/scripts/sign-recording-encoder.sh" "$APP" "$EXPANDED_CODE_SIGN_IDENTITY"
fi
