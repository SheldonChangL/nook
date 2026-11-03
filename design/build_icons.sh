#!/bin/bash
# 重新產生 app icon 的所有素材。
#
#   ./design/build_icons.sh
#
# 改 design/render_icon.swift 的造型或顏色之後跑這支，然後重新 build app。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=design/out
ICONSET=macos/Runner/Assets.xcassets/AppIcon.appiconset

echo "算圖…"
swift design/render_icon.swift "$OUT"

echo "放進 asset catalog…"
for size in 16 32 64 128 256 512 1024; do
  cp "$OUT/app_icon_$size.png" "$ICONSET/app_icon_$size.png"
done

echo "做 .icns…"
# .icns 給「不是透過 Xcode 打包」的場合用，例如直接發一個 app 或做 DMG。
TMP=$(mktemp -d)/SecureManage.iconset
mkdir -p "$TMP"
cp "$OUT/app_icon_16.png"   "$TMP/icon_16x16.png"
cp "$OUT/app_icon_32.png"   "$TMP/icon_16x16@2x.png"
cp "$OUT/app_icon_32.png"   "$TMP/icon_32x32.png"
cp "$OUT/app_icon_64.png"   "$TMP/icon_32x32@2x.png"
cp "$OUT/app_icon_128.png"  "$TMP/icon_128x128.png"
cp "$OUT/app_icon_256.png"  "$TMP/icon_128x128@2x.png"
cp "$OUT/app_icon_256.png"  "$TMP/icon_256x256.png"
cp "$OUT/app_icon_512.png"  "$TMP/icon_256x256@2x.png"
cp "$OUT/app_icon_512.png"  "$TMP/icon_512x512.png"
cp "$OUT/app_icon_1024.png" "$TMP/icon_512x512@2x.png"
iconutil -c icns "$TMP" -o "$OUT/SecureManage.icns"
rm -rf "$(dirname "$TMP")"

echo "好了："
ls -la "$OUT"
