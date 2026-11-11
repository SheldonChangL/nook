# Nook 的 Linux 建置環境。故意用 Ubuntu 22.04（最舊的支援目標）：
# 在哪個 glibc 上編，產出的 .so 就帶那個 glibc 的符號版本需求，
# 在 24.04 上編出來的東西裝到 22.04 會因為 GLIBC_2.38 起不來。
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# clang/llvm 在 jammy 都是 14，Dart native assets 會去 clang 所在的
# /usr/lib/llvm-14/bin 找 llvm-ar，所以 llvm 這個 meta 套件要裝。
# 刻意不裝 JDK。相依樹裡有 jni（local_auth 帶進來的 FFI 外掛），建置機上有 JDK 時
# 它的 CMake 會多編一個 lib/libdartjni.so 進 bundle —— 2026-11-11 在 Ubuntu 24.04 上
# 編出來的 .deb 就有。那個 .so 在 Linux 上從來不會被載入（jni 只有 Android 會用到，
# 而 Linux 版沒有快速解鎖），bundle 的 native_assets.json 也是空的 {}，
# 所以這裡不裝 JDK，讓產物固定沒有它；裝了 default-jdk 也試過，並不會產出（實測）。
# 重點是不要讓「建置機剛好有沒有 Java」決定套件內容。
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils file sudo \
      clang llvm lld cmake ninja-build pkg-config \
      libgtk-3-dev libsecret-1-dev dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

ARG FLUTTER_VERSION=3.41.9
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

# 以非 root 跑（Flutter 不喜歡 root），且要能寫 SDK 的 bin/cache。
RUN git config --system --add safe.directory /opt/flutter \
 && flutter config --no-analytics \
 && flutter precache --linux \
 && chmod -R a+rwX /opt/flutter
