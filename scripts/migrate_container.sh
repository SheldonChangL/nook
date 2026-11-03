#!/bin/bash
# 把保險庫從舊的沙盒容器搬到新的。
#
#   ./scripts/migrate_container.sh
#
# 背景：app 從 SecureManage 改名為 Nook 時，bundle identifier 也從
# tw.com.jetopto.securemanage 換成 tw.com.jetopto.nook。沙盒 app 的資料目錄是
# 跟著 bundle identifier 走的，所以換了之後新版會看到一個空的保險庫，
# 舊資料其實還在舊容器裡，只是 app 找不到。
#
# 這支腳本是「複製」不是「移動」：舊容器原封不動留著當備份。確認新的能正常
# 解鎖之後，你要自己決定何時刪掉舊的。
set -euo pipefail

OLD_ID="tw.com.jetopto.securemanage"
NEW_ID="tw.com.jetopto.nook"
APP="/Applications/Nook.app"

container() {
  echo "$HOME/Library/Containers/$1/Data/Library/Application Support/$1"
}

OLD_VAULT="$(container "$OLD_ID")/vault"
NEW_BASE="$(container "$NEW_ID")"
NEW_VAULT="$NEW_BASE/vault"

echo "舊：$OLD_VAULT"
echo "新：$NEW_VAULT"
echo

if [ ! -d "$OLD_VAULT" ]; then
  echo "舊容器裡沒有保險庫，沒東西好搬。" >&2
  exit 1
fi

if [ -f "$NEW_VAULT/vault.json" ]; then
  echo "新容器裡已經有保險庫了，不覆蓋。" >&2
  echo "要重搬的話請先自己把 $NEW_VAULT 移開。" >&2
  exit 1
fi

# 容器目錄是 macOS 在 app 第一次啟動時建的，而且帶有 containermanagerd 的
# metadata。自己 mkdir 出來的容器沙盒不一定認，所以先讓 app 跑一次。
if [ ! -d "$HOME/Library/Containers/$NEW_ID" ]; then
  if [ ! -d "$APP" ]; then
    echo "找不到 $APP，請先跑 ./scripts/install.sh" >&2
    exit 1
  fi
  echo "新容器還不存在，先讓 Nook 跑一次把它建出來…"
  open "$APP"
  for _ in $(seq 1 30); do
    [ -d "$HOME/Library/Containers/$NEW_ID" ] && break
    sleep 1
  done
  pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
  sleep 1
fi

if [ ! -d "$HOME/Library/Containers/$NEW_ID" ]; then
  echo "等不到新容器被建立出來。請手動開一次 Nook 再跑這支。" >&2
  exit 1
fi

echo "複製中…"
mkdir -p "$NEW_BASE"
cp -R "$OLD_VAULT" "$NEW_VAULT"

OLD_COUNT=$(find "$OLD_VAULT/items" -name '*.item' 2>/dev/null | wc -l | tr -d ' ')
NEW_COUNT=$(find "$NEW_VAULT/items" -name '*.item' 2>/dev/null | wc -l | tr -d ' ')

echo
echo "舊容器項目數：$OLD_COUNT"
echo "新容器項目數：$NEW_COUNT"

if [ "$OLD_COUNT" != "$NEW_COUNT" ] || [ ! -f "$NEW_VAULT/vault.json" ]; then
  echo "搬移結果對不上，新容器那份不要用。" >&2
  exit 1
fi

if ! cmp -s "$OLD_VAULT/vault.json" "$NEW_VAULT/vault.json"; then
  echo "vault.json 內容對不上。" >&2
  exit 1
fi

echo
echo "搬好了。用原本的主密碼解鎖即可，資料都在。"
echo "舊容器留著沒動，確認沒問題之後你可以自己刪："
echo "  rm -rf \"$HOME/Library/Containers/$OLD_ID\""
