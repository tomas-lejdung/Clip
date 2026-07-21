#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DERIVED_DATA="${CLIP_RELEASE_DERIVED_DATA_PATH:-$ROOT/.build/DerivedDataRelease}"

source "$ROOT/scripts/signing-config.sh"

# A permission-free ad-hoc verification must never overwrite a stable-signed
# local release candidate and its certificate-based privacy identity. Stable
# runs retain the canonical Clip.dmg name; ad-hoc CI gets a clearly separate
# diagnostic artifact.
if clip_signing_is_ad_hoc; then
  DMG="$ROOT/.build/Clip-permission-free.dmg"
else
  DMG="$ROOT/.build/Clip.dmg"
fi

cat <<'EOF'
Running Clip's permission-free release gate.
This command does not launch UI automation, move the pointer, or request
Screen Recording, System Audio, Microphone, Accessibility, or Automation.
EOF

"$ROOT/scripts/typecheck.sh"
"$ROOT/scripts/test.sh"
"$ROOT/scripts/run-deterministic-acceptance.sh"
"$ROOT/scripts/run-live-share-acceptance.sh"

CLIP_DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA" \
  CLIP_DMG_PATH="$DMG" \
  "$ROOT/scripts/package-dmg.sh"
"$ROOT/scripts/verify-dmg.sh" "$DMG"

echo "SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "Permission-free Release verification passed: $DMG"
