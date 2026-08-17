#!/usr/bin/env bash
# Regenerates Sources/App/Assets.xcassets/AppIcon.appiconset from the SVG master at
# Design/AppIcon/my-island-icon.svg: renders the SVG to a 1024x1024 PNG headlessly
# (Chrome for Testing, from the Playwright cache), then uses sips -z to derive all
# 10 classic macOS AppIcon slots (16/32/128/256/512 at 1x and 2x).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Design/AppIcon/my-island-icon.svg"
ICONSET="$ROOT/Sources/App/Assets.xcassets/AppIcon.appiconset"
MASTER="$ICONSET/.icon_master_1024.png"

CHROME="$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/"Google Chrome for Testing.app"/Contents/MacOS/"Google Chrome for Testing" 2>/dev/null | head -1)"
[[ -n "$CHROME" ]] || { echo "Chrome for Testing not found under ~/Library/Caches/ms-playwright — run: npx playwright install chromium" >&2; exit 1; }

echo "==> Rendering $SVG to 1024x1024 PNG"
"$CHROME" --headless --disable-gpu --default-background-color=00000000 --screenshot="$MASTER" --window-size=1024,1024 "file://$SVG" >/dev/null 2>&1

echo "==> Deriving appiconset slots with sips"
sips -z 16 16     "$MASTER" --out "$ICONSET/icon_16x16.png"       >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_32x32.png"       >/dev/null
sips -z 64 64     "$MASTER" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
sips -z 128 128   "$MASTER" --out "$ICONSET/icon_128x128.png"     >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_256x256.png"     >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_512x512.png"     >/dev/null
sips -z 1024 1024 "$MASTER" --out "$ICONSET/icon_512x512@2x.png"  >/dev/null

rm -f "$MASTER"
echo "==> Done. 10 slots written to $ICONSET"
