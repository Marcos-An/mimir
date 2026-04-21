#!/usr/bin/env bash
set -euo pipefail

# Gera Assets/Mimir.icns a partir de um PNG 1024x1024 exportado do Icon Composer.
# Uso: scripts/make_icns.sh /caminho/para/fonte_1024.png
# Default: Assets/mimir_icon_source.png (se existir no repo).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Assets/mimir_icon_source.png}"
OUT_ICNS="$ROOT/Assets/Mimir.icns"
ICONSET="$ROOT/Assets/AppIcon.iconset"

if [ ! -f "$SRC" ]; then
    echo "PNG fonte 1024x1024 não encontrado: $SRC" >&2
    echo "Uso: scripts/make_icns.sh /caminho/para/fonte_1024.png" >&2
    exit 1
fi

rm -rf "$ICONSET" "$OUT_ICNS"
mkdir -p "$ICONSET"

sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "$OUT_ICNS"
