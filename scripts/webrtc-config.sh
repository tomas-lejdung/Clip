#!/bin/bash

# Immutable dependency provenance for Clip Live Share.
CLIP_WEBRTC_VERSION="150.0.0"
CLIP_WEBRTC_ARTIFACT_REPOSITORY_URL="https://github.com/tomas-lejdung/Clip"
CLIP_WEBRTC_ARTIFACT_TAG="webrtc-m150-clip-native-color-3"
CLIP_WEBRTC_ARTIFACT_NAME="WebRTC-150.0.0-clip-native-color-macos-arm64.xcframework.zip"
CLIP_WEBRTC_ARTIFACT_URL="$CLIP_WEBRTC_ARTIFACT_REPOSITORY_URL/releases/download/$CLIP_WEBRTC_ARTIFACT_TAG/$CLIP_WEBRTC_ARTIFACT_NAME"
CLIP_WEBRTC_UPSTREAM_REPOSITORY_URL="https://webrtc.googlesource.com/src"
CLIP_WEBRTC_UPSTREAM_REVISION="1f975dfd761af6e5d76d28333191973b258d82a8"
CLIP_WEBRTC_PATCH_SHA256="e58f6bc5f0dda361000081d6868ca1cf0a791a48576f92b850a1f5df6820cb6a"
CLIP_WEBRTC_ARTIFACT_CHECKSUM="07807d9d8f246da5b6eebbb62cc1acfeb594b2974c62e47cb36bdd03f5256d5a"
CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256="99312b0656b329102d17fde07f2934ef03ea6bd906fbc61025a9c92e2e6b137a"
# Derived only from the exact whole-file hash above using the canonical signing
# parameters below. codesign's default page size changed across macOS releases.
CLIP_WEBRTC_NORMALIZED_ARM64_SHA256="48746de5f0187849333a5cf5ef36796645755d91dd507a293e6b5cfd13cc3911"
CLIP_WEBRTC_LICENSE_SHA256="5b08f62df6d3d7cf1191586b30386055596a1971d4d5fad8974e496096ff4e07"

# Xcode re-signs embedded dynamic frameworks, so their whole-file hashes no
# longer match the reviewed upstream artifact. Normalize one architecture with
# a deterministic ad-hoc signature, then hash every byte before the signature
# blob. This retains Mach-O headers, executable code, data, and linker metadata
# while excluding only the mutable code-signature payload.
clip_webrtc_normalized_payload_sha256() {
  local executable="$1"
  local architecture="$2"
  local thin_executable=""
  local architectures=""
  local signature_offset=""
  local payload_sha256=""

  thin_executable="$(mktemp "${TMPDIR:-/tmp}/clip-webrtc-payload.XXXXXX")" \
    || return 1
  architectures="$(lipo -archs "$executable")" || {
    rm -f "$thin_executable"
    return 1
  }
  if [[ "$architectures" == "$architecture" ]]; then
    if ! ditto "$executable" "$thin_executable"; then
      rm -f "$thin_executable"
      return 1
    fi
  elif ! lipo "$executable" -thin "$architecture" -output "$thin_executable"; then
    rm -f "$thin_executable"
    return 1
  fi
  if ! codesign \
      --force \
      --sign - \
      --identifier org.webrtc.WebRTC \
      --pagesize 4096 \
      --digest-algorithm sha256 \
      --options=0 \
      --requirements '=designated => identifier "org.webrtc.WebRTC"' \
      --timestamp=none \
      "$thin_executable" >/dev/null 2>&1; then
    rm -f "$thin_executable"
    return 1
  fi
  signature_offset="$(
    otool -l "$thin_executable" | awk '
      /LC_CODE_SIGNATURE/ { signature = 1; next }
      signature && $1 == "dataoff" { print $2; exit }
    '
  )"
  if [[ ! "$signature_offset" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$thin_executable"
    return 1
  fi
  payload_sha256="$(
    head -c "$signature_offset" "$thin_executable" | shasum -a 256 | awk '{print $1}'
  )"
  rm -f "$thin_executable"
  [[ "$payload_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$payload_sha256"
}
