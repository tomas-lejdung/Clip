#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$ROOT/Clip/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="${TMPDIR:-/tmp}/clip-app-icon-master.png"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required to regenerate the checked-in app icon PNGs." >&2
  exit 1
fi

magick -size 1024x1024 xc:none \
  \( -size 1024x1024 gradient:'#253451-#5A3FBC' \
     \( -size 1024x1024 xc:none -fill white \
        -draw 'roundrectangle 64,64 960,960 216,216' \) \
     -alpha off -compose CopyOpacity -composite \) \
  -compose Over -composite \
  -fill none -stroke 'rgba(255,255,255,0.16)' -strokewidth 3 \
  -draw 'roundrectangle 66,66 958,958 214,214' \
  -fill none -stroke white -strokewidth 56 \
  -draw "path 'M 405,284 L 306,284 C 276,284 252,308 252,338 L 252,421'" \
  -draw "path 'M 619,284 L 718,284 C 748,284 772,308 772,338 L 772,421'" \
  -draw "path 'M 405,740 L 306,740 C 276,740 252,716 252,686 L 252,603'" \
  -draw "path 'M 619,740 L 718,740 C 748,740 772,716 772,686 L 772,603'" \
  -fill white -stroke none \
  -draw 'circle 405,284 433,284' -draw 'circle 252,421 280,421' \
  -draw 'circle 619,284 647,284' -draw 'circle 772,421 800,421' \
  -draw 'circle 405,740 433,740' -draw 'circle 252,603 280,603' \
  -draw 'circle 619,740 647,740' -draw 'circle 772,603 800,603' \
  -fill 'rgba(20,24,48,0.42)' -stroke 'rgba(255,255,255,0.20)' -strokewidth 4 \
  -draw 'circle 512,526 654,526' \
  -fill '#FF5369' -stroke none -draw 'circle 512,512 603,512' \
  -fill 'rgba(255,255,255,0.24)' -draw 'circle 484,480 509,480' \
  -colorspace sRGB -depth 8 -strip "$MASTER"

for size in 16 32 64 128 256 512 1024; do
  magick "$MASTER" -filter Lanczos -resize "${size}x${size}" \
    -colorspace sRGB -depth 8 -strip -define png:color-type=6 \
    "$DESTINATION/ClipAppIcon-${size}.png"
done

rm -f "$MASTER"

echo "Generated Clip app icon assets in $DESTINATION"
