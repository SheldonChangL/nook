#!/bin/bash
# 在 Ubuntu 22.04 容器裡跑 Nook 的 Linux 建置工具鏈。
#
#   ./scripts/build_linux_container.sh                                   # 編譯並打包成 .deb
#   ./scripts/build_linux_container.sh ./scripts/package_linux.sh --no-build  # 只重打包
#   ./scripts/build_linux_container.sh flutter analyze                   # 容器裡跑任意指令
#
# 為什麼要容器：在哪個發行版上編，產出的 ELF 就帶那個 glibc 的符號版本需求。
# 直接在 Ubuntu 24.04 上編，flutter_secure_storage 的外掛會引用 GLIBC_2.38 的
# __isoc23_strtoll，裝到 Ubuntu 22.04 上 apt 不會擋，但一啟動就被動態連結器
# 以「version `GLIBC_2.38' not found」打回（2026-11-11 在 22.04 實機上踩到）。
# 所以一律在最舊的支援目標上編；package_linux.sh 會再檢查一次基線。
#
# 需要：Docker，以及能寫 dist/ 的權限。架構跟著 host 走（amd64 host 產 amd64 .deb）。
# 產出：dist/nook_<版本>_<架構>.deb
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${NOOK_BUILD_IMAGE:-nook-build:22.04}"

echo "==> 準備建置映像 $IMAGE"
docker build -f linux/packaging/build.Dockerfile -t "$IMAGE" linux/packaging

# 預設跑打包；給了參數就把參數當成容器裡要執行的指令。
if [[ $# -eq 0 ]]; then
  set -- ./scripts/package_linux.sh
fi

echo "==> 在容器裡執行：$*"
# -u：產出的檔案歸現在這個使用者，不是 root，host 這邊才改得動、刪得掉。
# HOME 指到容器內的暫存路徑：pub cache 要可寫，但不該寫進掛進來的原始碼樹。
docker run --rm \
  -v "$PWD:/src" -w /src \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp/nook-home \
  "$IMAGE" bash -euc 'mkdir -p "$HOME"; flutter pub get >/dev/null; exec "$@"' _ "$@"
