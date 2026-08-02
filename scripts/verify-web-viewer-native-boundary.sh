#!/bin/bash

set -euo pipefail

# Web participation may extend the authenticated room descriptor, encrypted
# signaling, peer capability/UI presentation, and exact codec negotiation. It
# must not alter the already-verified native capture, display-density, recording
# media, or Live Share source-geometry pipelines.
readonly WEB_VIEWER_BASE_COMMIT="${CLIP_WEB_VIEWER_BASE_COMMIT:-dbdb48b}"
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
