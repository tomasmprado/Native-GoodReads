#!/usr/bin/env bash
#
# make-icon.sh [source.png]
#
# Turns a square PNG (1024x1024 ideally) into AppIcon.icns.
# Uses sips and iconutil, both built into macOS. Nothing to install.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$ROOT/icon-source.png}"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUT="$ROOT/AppIcon.icns"

[ -f "$SRC" ] || { echo "No source image at $SRC"; exit 1; }

echo "==> Source: $SRC"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# macOS wants each size at 1x and 2x. iconutil is strict about these names.
for size in 16 32 128 256 512; do
    sips -z $size $size            "$SRC" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null
    sips -z $((size*2)) $((size*2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png"  >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "==> Wrote $OUT"
echo "    Now run: bash build-app.sh"
