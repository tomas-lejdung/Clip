#!/bin/bash

# Immutable dependency provenance for Clip Live Share.
CLIP_WEBRTC_REPOSITORY_URL="https://github.com/stasel/WebRTC"
CLIP_WEBRTC_VERSION="150.0.0"
CLIP_WEBRTC_WRAPPER_REVISION="6ed87f05368632f71dc95c89c14c051561710925"
CLIP_WEBRTC_UPSTREAM_REVISION="1f975dfd761af6e5d76d28333191973b258d82a8"
CLIP_WEBRTC_ARTIFACT_CHECKSUM="f9890492b0016e4c88ab20f07867b8b420054caedc8a692b2ec6ac041f3cf6b2"
# Hash of the universal macOS WebRTC executable before Clip re-signs it. This
# binds the reviewed archive checksum to the exact payload Xcode embeds.
CLIP_WEBRTC_MACOS_EXECUTABLE_SHA256="8a6936a1beceab72283c54a0396c905313084ed1f9094781c02e3a9f39d55fe3"

# Xcode re-signs embedded dynamic frameworks, so their whole-file hashes no
# longer match the reviewed upstream artifact. Normalize one architecture with
# a deterministic ad-hoc signature, then hash every byte before the signature
# blob. This retains Mach-O headers, executable code, data, and linker metadata
# while excluding only the mutable code-signature payload.
clip_webrtc_normalized_payload_sha256() {
  local executable="$1"
  local architecture="$2"
  local thin_executable=""
  local signature_offset=""
  local payload_sha256=""

  thin_executable="$(mktemp "${TMPDIR:-/tmp}/clip-webrtc-payload.XXXXXX")" \
    || return 1
  if ! lipo "$executable" -thin "$architecture" -output "$thin_executable"; then
    rm -f "$thin_executable"
    return 1
  fi
  if ! codesign \
      --force \
      --sign - \
      --identifier org.webrtc.WebRTC \
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
