#!/bin/bash
# 編 Release 版並安裝到 /Applications。
#
#   ./scripts/install.sh
#
# 這支腳本存在的理由是簽章那一步有兩個地雷：
#
#   1. 複製完之後如果跑 `codesign --force --deep --sign -`，entitlements 會被整個
#      剝掉。沙盒沒了，「Release 版沒有網路權限」這個保證也跟著沒了。要重簽就
#      一定要帶 --entitlements。
#   2. 加上 --options runtime（hardened runtime）配 ad-hoc 簽章，app 會直接啟動
#      失敗。那是給公證用的，本機自用不需要。
#
# 這裡重簽一次的目的，是拿掉 Xcode 在本機簽章時塞進來的
# com.apple.security.get-task-allow —— 那個 entitlement 允許別的程序掛除錯器進來
# 讀記憶體，對一個裝機密的 app 來說不該留著。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SecureManage.app"
BUILT="build/macos/Build/Products/Release/$APP_NAME"
TARGET="/Applications/$APP_NAME"

echo "==> 編 Release"
flutter build macos --release

echo "==> 關掉正在跑的"
pkill -f "$APP_NAME/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "==> 安裝到 $TARGET"
rm -rf "$TARGET"
cp -R "$BUILT" "$TARGET"

echo "==> 重簽（保留沙盒、拿掉 get-task-allow）"
codesign --force --sign - \
  --entitlements macos/Runner/Release.entitlements \
  "$TARGET"

echo "==> 驗一下"
codesign --verify --verbose=2 "$TARGET" 2>&1 | tail -2
echo "entitlements："
codesign -d --entitlements - "$TARGET" 2>/dev/null | tr -d '\0' | grep -E '\[Key\]' || true

if codesign -d --entitlements - "$TARGET" 2>/dev/null | tr -d '\0' | grep -q "get-task-allow"; then
  echo "警告：get-task-allow 還在，別的程序可以掛除錯器讀記憶體" >&2
  exit 1
fi
if ! codesign -d --entitlements - "$TARGET" 2>/dev/null | tr -d '\0' | grep -q "app-sandbox"; then
  echo "警告：沙盒 entitlement 不見了" >&2
  exit 1
fi

echo "==> 好了，開起來"
open "$TARGET"
