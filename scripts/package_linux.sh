#!/bin/bash
# 在 Linux 上編 Release 版，打成 Ubuntu／Debian 的 .deb。
#
#   ./scripts/package_linux.sh            # 編譯並打包
#   ./scripts/package_linux.sh --no-build # 沿用現有的 build/linux/*/release/bundle
#
# 需要（建置機）：Flutter、clang、cmake、ninja-build、pkg-config、libgtk-3-dev、
#   libsecret-1-dev（flutter_secure_storage_linux 編譯時要；快速解鎖在 Linux 停用，
#   但外掛仍會連結 libsecret）、lld（Dart native assets 的連結器）、
#   llvm-18（Dart native assets 要在 clang 所在的 /usr/lib/llvm-18/bin 找 llvm-ar；只裝 clang 時 release 建置會失敗，
#   2026-11-11 在原生 x86_64 的 Ubuntu 24.04 容器實測）、dpkg-dev。
# 產出：dist/nook_<版本>_<架構>.deb
#
# 安裝後的配置：
#   /opt/nook/            整份 Flutter bundle（nook、lib/、data/），不能只拿執行檔
#   /usr/bin/nook         指向 /opt/nook/nook 的連結
#   /usr/share/applications/tw.com.jetopto.nook.desktop
#   /usr/share/icons/hicolor/<尺寸>/apps/tw.com.jetopto.nook.png
#
# 保險庫放在 ~/.local/share/tw.com.jetopto.nook/vault/，不在安裝目錄裡，
# 所以移除或升級套件都不會動到資料。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "這支要在 Linux 上跑（flutter build linux 不能跨平台編）" >&2
  exit 1
fi

BUILD=1
[[ "${1:-}" == "--no-build" ]] && BUILD=0

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *) echo "不支援的架構：$ARCH" >&2; exit 1 ;;
esac

# pubspec 的 1.0.0+1 直接當 Debian 版本號（+ 在 upstream version 裡是合法字元）。
VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
[[ -n "$VERSION" ]] || { echo "pubspec.yaml 找不到 version" >&2; exit 1; }
# 維護者欄位要「名字 <email>」格式。不寫死個人信箱，要對外發佈時自己帶進來。
MAINTAINER="${NOOK_DEB_MAINTAINER:-Nook maintainers <nook@localhost.invalid>}"

if [[ $BUILD -eq 1 ]]; then
  echo "==> 編 Release"
  flutter build linux --release
fi

BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
[[ -x "$BUNDLE/nook" ]] || { echo "找不到 $BUNDLE/nook，先編譯" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/nook_${VERSION}_${ARCH}"

echo "==> 排檔案"
install -d "$ROOT/opt/nook" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
  "$ROOT/usr/share/doc/nook" "$ROOT/DEBIAN"
# 只收 bundle 本身；build/ 的中間產物、測試樣本、快取一概不進包。
cp -R "$BUNDLE/." "$ROOT/opt/nook/"
ln -s /opt/nook/nook "$ROOT/usr/bin/nook"
install -m 644 linux/packaging/tw.com.jetopto.nook.desktop "$ROOT/usr/share/applications/"
install -m 644 LICENSE "$ROOT/usr/share/doc/nook/copyright"

# icon 的正本是 macOS asset catalog 裡那組各自重畫的 PNG（design/build_icons.sh 產生）。
for size in 16 32 64 128 256 512; do
  dir="$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
  install -d "$dir"
  install -m 644 "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png" \
    "$dir/tw.com.jetopto.nook.png"
done

# 權限：目錄 755、一般檔 644、執行檔與 .so 755。
find "$ROOT/opt" "$ROOT/usr" -type d -exec chmod 755 {} +
find "$ROOT/opt" -type f -exec chmod 644 {} +
chmod 755 "$ROOT/opt/nook/nook"
find "$ROOT/opt/nook/lib" -name '*.so' -exec chmod 755 {} +

INSTALLED_KB="$(du -sk "$ROOT" --exclude=DEBIAN | cut -f1)"

# 執行期依賴：GTK 3（Flutter 的 Linux 嵌入層）、libsecret（flutter_secure_storage_linux
# 連結它，雖然快速解鎖停用）、libegl1／libgles2（Flutter 引擎執行時 dlopen libEGL.so.1 與 libGLESv2.so.2，ldd 看不到；
# 乾淨的 Ubuntu 沒裝它就會開不起來，實測過）。Ubuntu 24.04 起部分套件因 64 位元 time_t 改名加 t64，
# 用「|」同時接受新舊名字。介面全是中文，沒有 CJK 字型會整片變方塊（英文版 Ubuntu 不一定有裝），
# 所以 fonts-noto-cjk 是 Depends 而不是 Recommends（--no-install-recommends 會略過後者）；主題在 Linux
# 上會明確指名 Noto Sans CJK（lib/app/platform_profile.dart 的 cjkFontFallback），兩者要一起改。
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: nook
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libsecret-1-0, libegl1, libgles2, libstdc++6, libc6, fonts-noto-cjk
Homepage: https://github.com/SheldonChangL/nook
Description: Local-only secret manager for keys, accounts and hosts
 Nook keeps SSH keys, API tokens, account passwords and host credentials in an
 encrypted vault (Argon2id + ChaCha20-Poly1305) on this machine. The master
 password is the only way to open the vault; quick unlock is not available on
 Linux.
CONTROL

# 先確認二進位檔沒有找不到的共享函式庫，再產生 .deb，免得留下壞掉的安裝包。
# 只從 nook 執行檔解析：外掛 .so 是靠 nook 的 RUNPATH（$ORIGIN/lib）載入的，單獨對它
# 跑 ldd 會誤報 libflutter_linux_gtk.so 找不到（在乾淨的 Ubuntu 上實測過）。
# 先存成變數再比對：直接 ldd | grep -q 在 pipefail 下可能因 SIGPIPE 誤判成沒問題。
LDD_OUT="$(ldd "$ROOT/opt/nook/nook" 2>&1 || true)"
if grep -q "not found" <<<"$LDD_OUT"; then
  echo "錯誤：有共享函式庫找不到：" >&2
  grep "not found" <<<"$LDD_OUT" >&2
  exit 1
fi

mkdir -p dist
OUT="dist/nook_${VERSION}_${ARCH}.deb"
echo "==> 打包 $OUT"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT"

echo "==> 檢查"
dpkg-deb --info "$OUT" | sed -n '1,20p'
echo "好了：$OUT"
echo "安裝：sudo apt install ./$OUT"
