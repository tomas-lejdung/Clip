#!/bin/bash

# Shared version resolution. Xcode's project remains the checked-in source of
# truth. Explicit environment overrides remain available for non-release local
# acceptance, while package-dmg.sh rejects them for publishable artifacts.

CLIP_VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIP_VERSION_PROJECT="$CLIP_VERSION_ROOT/Clip.xcodeproj/project.pbxproj"

clip_unique_project_setting() {
  local setting="$1"
  local values
  local count

  values="$(
    sed -n "s/^[[:space:]]*$setting = \([^;][^;]*\);$/\1/p" \
      "$CLIP_VERSION_PROJECT" \
      | sort -u
  )"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" != "1" ]]; then
    echo "Expected one unique $setting in $CLIP_VERSION_PROJECT, found $count" >&2
    return 1
  fi
  printf '%s' "$values"
}

CLIP_PROJECT_MARKETING_VERSION="$(
  clip_unique_project_setting MARKETING_VERSION
)"
CLIP_PROJECT_BUILD_VERSION="$(
  clip_unique_project_setting CURRENT_PROJECT_VERSION
)"

CLIP_MARKETING_VERSION="${CLIP_MARKETING_VERSION:-$CLIP_PROJECT_MARKETING_VERSION}"
CLIP_BUILD_VERSION="${CLIP_BUILD_VERSION:-$CLIP_PROJECT_BUILD_VERSION}"

if [[ ! "$CLIP_MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CLIP_MARKETING_VERSION must use numeric X.Y.Z form" >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ! "$CLIP_BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "CLIP_BUILD_VERSION must be a positive integer" >&2
  return 1 2>/dev/null || exit 1
fi

export \
  CLIP_PROJECT_MARKETING_VERSION \
  CLIP_PROJECT_BUILD_VERSION \
  CLIP_MARKETING_VERSION \
  CLIP_BUILD_VERSION
