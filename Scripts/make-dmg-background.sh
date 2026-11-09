#!/bin/bash
# Renders the DMG window background (660x400 points, 2x) from the logomark. Needs ImageMagick.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Assets/dmg-background.png"
FONT="/System/Library/Fonts/HelveticaNeue.ttc"
[[ -f "$FONT" ]] || FONT="/System/Library/Fonts/Helvetica.ttc"
magick -size 1320x800 gradient:'#FFFFFF-#EEF3FC' \
    \( "$ROOT/Assets/AppIcon-1024.png" -resize 120x120 \) -gravity north -geometry +0+70 -composite \
    -font "$FONT" -fill '#1E3A8A' -pointsize 44 -gravity north -annotate +0+215 'Drag Proof into Applications' \
    -fill '#7B8AA8' -pointsize 26 -annotate +0+275 'Then open it from Launchpad or Spotlight.' \
    -stroke '#3B82F6' -strokewidth 10 -fill none -draw 'line 540,470 780,470' \
    -draw 'line 740,430 790,470' -draw 'line 740,510 790,470' \
    -units PixelsPerInch -density 144 \
    "$OUT"
echo "Wrote $OUT"
