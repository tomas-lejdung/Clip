#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "--allow-controlled-self-capture" || $# -ne 1 ]]; then
  cat >&2 <<'EOF'
Usage: scripts/run-unattended-quality-acceptance.sh --allow-controlled-self-capture

This is an opt-in, permission-dependent real ScreenCaptureKit lane. It does
not move the pointer, type, use Accessibility/Automation, or contact another
app. Screen Recording must already be authorized for the stable-signed Clip.
It runs the synthetic record → Pause/Resume → Preview-frame generation →
private-pasteboard Copy → byte comparison → decode/evaluate path at both 30
and 60 FPS and requires the strict two-frame-gap and 95% fine-edge targets.
EOF
  exit 64
fi

"$ROOT/scripts/run-unattended-capture-smoke.sh" \
  --allow-controlled-self-capture \
  --duration 4 \
  --fps 30 \
  --require-quality-targets

"$ROOT/scripts/run-unattended-capture-smoke.sh" \
  --allow-controlled-self-capture \
  --duration 4 \
  --fps 60 \
  --require-quality-targets

echo "Unattended real-capture quality acceptance passed at 30 and 60 FPS."
