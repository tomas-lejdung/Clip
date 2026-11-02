#!/bin/bash

set -euo pipefail

# Web participation may extend the authenticated room descriptor, encrypted
# signaling, peer capability/UI presentation, and exact codec negotiation. It
# must not alter the already-verified native capture, display-density, recording
# media, or Live Share source-geometry pipelines.
# Advance this only after an intentional native capture change has passed its
# focused tests and real-Mac acceptance. 2487c4e is the reviewed native-resolution
# HEVC/H.264 recording pipeline, including manual quality, trim, and export checks.
readonly WEB_VIEWER_BASE_COMMIT="${CLIP_WEB_VIEWER_BASE_COMMIT:-2487c4e}"
readonly FORBIDDEN_PATHS=(
  "Packages/ClipCapture"
  "Packages/ClipMedia"
  "Clip/LiveShare/Session/LiveShareCapturePolicy.swift"
  "Clip/LiveShare/Session/LiveShareCaptureController.swift"
  "Clip/Diagnostics/UnattendedCapture"
)

if ! git cat-file -e "${WEB_VIEWER_BASE_COMMIT}^{commit}" 2>/dev/null; then
  echo "Web viewer boundary base commit is unavailable: ${WEB_VIEWER_BASE_COMMIT}" >&2
  exit 1
fi

changed_paths="$(git diff --name-only "${WEB_VIEWER_BASE_COMMIT}" -- "${FORBIDDEN_PATHS[@]}")"
if [[ -n "${changed_paths}" ]]; then
  echo "Web viewer work changed frozen native capture/media paths:" >&2
  echo "${changed_paths}" >&2
  exit 1
fi

echo "Web viewer native boundary verified against ${WEB_VIEWER_BASE_COMMIT}."
