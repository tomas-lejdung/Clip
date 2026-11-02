#!/bin/bash
# Reproducible, minimal arm64 helper. No Homebrew libraries are linked at runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/recording-encoder-config.sh"
BUILD="$ROOT/.build/recording-encoder"
PREFIX="$BUILD/install"
SOURCES="$BUILD/sources"
mkdir -p "$SOURCES" "$PREFIX"

fetch() {
  local name="$1" url="$2" checksum="$3" temporary
  if [[ -f "$SOURCES/$name" ]] &&
      printf '%s  %s\n' "$checksum" "$SOURCES/$name" | shasum -a 256 -c - >/dev/null 2>&1; then
    return
  fi
  temporary="$(mktemp "$SOURCES/.download.XXXXXX")"
  if ! curl --fail --location --retry 3 "$url" -o "$temporary" ||
      ! printf '%s  %s\n' "$checksum" "$temporary" | shasum -a 256 -c -; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$SOURCES/$name"
}
fetch ffmpeg-8.0.tar.xz https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz \
  "$CLIP_FFMPEG_SOURCE_SHA256"
fetch x264-b35605a.tar.bz2 https://code.videolan.org/videolan/x264/-/archive/b35605a/x264-b35605a.tar.bz2 \
  "$CLIP_X264_SOURCE_SHA256"

[[ "$(uname -m)" == arm64 ]] || { echo 'Recording encoder requires an arm64 builder.' >&2; exit 1; }
BUILD_FINGERPRINT="$(shasum -a 256 "$ROOT/scripts/build-recording-encoder.sh" "$ROOT/scripts/recording-encoder-config.sh" | shasum -a 256 | awk '{print $1}')"
if [[ -x "$PREFIX/bin/ffmpeg" && -f "$PREFIX/clip-build-fingerprint" &&
      "$(cat "$PREFIX/clip-build-fingerprint")" == "$BUILD_FINGERPRINT" ]]; then
  exit 0
fi
tar -xf "$SOURCES/x264-b35605a.tar.bz2" -C "$BUILD"
tar -xf "$SOURCES/ffmpeg-8.0.tar.xz" -C "$BUILD"
JOBS="${CLIP_ENCODER_BUILD_JOBS:-8}"
export MACOSX_DEPLOYMENT_TARGET=15.0
(
  cd "$BUILD/x264-b35605a"
  ./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl \
    --enable-pic --bit-depth=8 --chroma-format=420 \
    --extra-cflags=-mmacosx-version-min=15.0 --extra-ldflags=-mmacosx-version-min=15.0
  make -j "$JOBS"
  make install-lib-static
)
# A tiny pkg-config replacement describes only our own pinned static x264.
# Neither building nor running this helper requires a Homebrew installation.
cat > "$BUILD/pkg-config" <<EOF
#!/bin/sh
case "\$*" in
  *--exists*|*--atleast-version*) exit 0 ;;
  *--modversion*) echo 0.165 ;;
  *--cflags*) echo -I$PREFIX/include ;;
  *--libs*) echo -L$PREFIX/lib -lx264 -lpthread -lm ;;
esac
EOF
chmod +x "$BUILD/pkg-config"
(
  cd "$BUILD/ffmpeg-8.0"
  ./configure --prefix="$PREFIX" --arch=arm64 --target-os=darwin \
    --cc=clang --pkg-config="$BUILD/pkg-config" --pkg-config-flags=--static \
    --extra-cflags="-I$PREFIX/include -mmacosx-version-min=15.0" \
    --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=15.0" \
    --disable-autodetect --disable-shared --enable-static --enable-gpl \
    --enable-libx264 --enable-pthreads --enable-videotoolbox \
    --disable-doc --disable-debug --disable-network --disable-everything \
    --enable-ffmpeg --disable-ffprobe --disable-ffplay \
    --enable-protocol=file,pipe --enable-demuxer=mov --enable-muxer=mp4 \
    --enable-decoder=hevc,h264,aac --enable-parser=hevc,h264,aac \
    --enable-encoder=libx264,aac --enable-hwaccel=hevc_videotoolbox,h264_videotoolbox \
    --enable-filter=buffer,buffersink,format,scale,setsar,setpts,hwdownload,abuffer,abuffersink,amix,aresample \
    --enable-bsf=setts,aac_adtstoasc --enable-swscale
  make -j "$JOBS"
  make install
)
otool -L "$PREFIX/bin/ffmpeg" | awk 'NR > 1 { print $1 }' | while read -r dep; do
  case "$dep" in /usr/lib/*|/System/Library/*) ;; *) echo "Non-system dependency: $dep" >&2; exit 1 ;; esac
done
printf '%s\n' "$BUILD_FINGERPRINT" > "$PREFIX/clip-build-fingerprint"
