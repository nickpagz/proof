#!/bin/bash
# Regenerates the app icon and menu bar icon from the SVG sources in Assets/, using macOS's own
# SVG renderer (Scripts/render-svg.swift), sips and iconutil. No third-party tools.
#   Assets/proof-icon.svg      full-bleed 1024 tile; macOS 26 masks it into its own shape
#   Assets/proof-menubar.svg   monochrome black glyph, 18pt template image
# Outputs (committed, so builders don't need to run this):
#   Assets/AppIcon-1024.png, Assets/AppIcon.icns, Assets/MenuBarIcon.png, Assets/MenuBarIcon@2x.png
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
render() { swift "$ROOT/Scripts/render-svg.swift" "$@"; }

render "$OUT/proof-icon.svg" "$OUT/AppIcon-1024.png" 1024 1024
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

render "$OUT/proof-menubar.svg" "$OUT/MenuBarIcon.png" 18 18
render "$OUT/proof-menubar.svg" "$OUT/MenuBarIcon@2x.png" 36 36
echo "Wrote AppIcon-1024.png, AppIcon.icns, MenuBarIcon.png and MenuBarIcon@2x.png in Assets/"
