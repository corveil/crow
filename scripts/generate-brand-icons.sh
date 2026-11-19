#!/usr/bin/env bash
# Regenerate Crow's raster icons from the gold particle crow (CROW-1469).
#
#   scripts/brand/appicon-gold.svg   512x512 rounded #121416 tile, 760 gold dots
#
# Writes:
#   crow-desktop/src-tauri/icons/{32x32,64x64,128x128,128x128@2x,icon}.png
#   crow-desktop/src-tauri/icons/icon.icns   (macOS: tile on Apple's 824/1024 grid)
#   crow-desktop/src-tauri/icons/icon.ico    (16–256, PNG-compressed entries)
#   Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/{icon-192,icon-512,apple-touch-icon}.png
#
# The web client's /brand.svg variants (brand-gold.svg, brand-pink.svg) are
# hand-placed SVGs, not outputs of this script.
#
# Needs: rsvg-convert (brew install librsvg), iconutil (macOS), python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/scripts/brand/appicon-gold.svg"
ICONS="$ROOT/crow-desktop/src-tauri/icons"
WEB="$ROOT/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/crow-icons.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil not found (macOS only)" >&2; exit 1; }

render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# The tile without its SVG prolog, to nest inside the padded/square variants.
INNER="$(sed -e 's#<svg[^>]*>##' -e 's#</svg>$##' "$SRC")"

# macOS: Apple's icon grid puts the tile at 824/1024, centered, so the dock
# shows it at the same size as every other app.
cat > "$WORK/macos.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><svg x="100" y="100" width="824" height="824" viewBox="0 0 512 512">$INNER</svg></svg>
SVG
# iOS home screen: the OS rounds the corners itself, so the tile goes square.
sed 's#rx="112"#rx="0"#' "$SRC" > "$WORK/square.svg"

# Tauri PNGs (Linux/Windows bundles, window icon).
render "$SRC" 32 "$ICONS/32x32.png"
render "$SRC" 64 "$ICONS/64x64.png"
render "$SRC" 128 "$ICONS/128x128.png"
render "$SRC" 256 "$ICONS/128x128@2x.png"
render "$SRC" 512 "$ICONS/icon.png"

# icon.icns
SET="$WORK/icon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  render "$WORK/macos.svg" "$s" "$SET/icon_${s}x${s}.png"
  render "$WORK/macos.svg" "$((s * 2))" "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$ICONS/icon.icns"

# icon.ico: PNG-compressed entries (Windows Vista+), packed with the stdlib.
ICO_SIZES=(16 24 32 48 64 128 256)
for s in "${ICO_SIZES[@]}"; do render "$SRC" "$s" "$WORK/ico-$s.png"; done
python3 -I - "$ICONS/icon.ico" "${ICO_SIZES[@]/#/$WORK/ico-}" <<'PY'
import struct, sys
out, pngs = sys.argv[1], [p + ".png" for p in sys.argv[2:]]
blobs = [open(p, "rb").read() for p in pngs]
sizes = [struct.unpack(">II", b[16:24]) for b in blobs]
offset = 6 + 16 * len(blobs)
head = struct.pack("<HHH", 0, 1, len(blobs))
for (w, h), b in zip(sizes, blobs):
    head += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(out, "wb").write(head + b"".join(blobs))
PY

# PWA install icons (manifest.webmanifest) and the iOS home-screen icon.
render "$SRC" 192 "$WEB/icon-192.png"
render "$SRC" 512 "$WEB/icon-512.png"
render "$WORK/square.svg" 180 "$WEB/apple-touch-icon.png"

echo "icons regenerated from $SRC"
