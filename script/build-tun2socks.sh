#!/usr/bin/env bash
# 交叉编译 badvpn tun2socks 为 Android 共享库（libtun2socks.so）
#
# 产物：src/mobile/android/app/src/main/jniLibs/<abi>/libtun2socks.so
# 源码：tmp/badvpn-src（固定 commit，可离线复用；删除后自动重新拉取）
# 用法：script/build-tun2socks.sh [abi ...]   默认三 ABI 全编
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/src/mobile/android/app/src/main/cpp"
JNI_LIBS="$ROOT_DIR/src/mobile/android/app/src/main/jniLibs"
BUILD_ROOT="$ROOT_DIR/tmp/build-tun2socks"
BADVPN_DIR="$ROOT_DIR/tmp/badvpn-src"
BADVPN_COMMIT="07268f02706e78e282e19641b5d1d41e8e89bf31"  # badvpn master 2021-08-22

ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
    ABIS=(arm64-v8a armeabi-v7a x86_64)
fi

# ---- 工具链定位 ----
ANDROID_HOME="${ANDROID_HOME:-$HOME/dev_env/android/sdk}"
if [ ! -d "$ANDROID_HOME" ]; then
    echo "错误：找不到 Android SDK（ANDROID_HOME=$ANDROID_HOME）" >&2
    exit 1
fi

if [ -z "${NDK:-}" ]; then
    NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$NDK" ] || [ ! -f "$NDK/build/cmake/android.toolchain.cmake" ]; then
    echo "错误：找不到 NDK（NDK=$NDK）" >&2
    exit 1
fi

CMAKE="${CMAKE:-}"
if [ -z "$CMAKE" ]; then
    CMAKE="$(ls -d "$ANDROID_HOME"/cmake/*/bin/cmake 2>/dev/null | sort -V | tail -1)"
fi
[ -z "$CMAKE" ] && CMAKE="$(command -v cmake || true)"
if [ -z "$CMAKE" ]; then
    echo "错误：找不到 cmake" >&2
    exit 1
fi

NINJA="${NINJA:-}"
if [ -z "$NINJA" ]; then
    NINJA="$(ls -d "$ANDROID_HOME"/cmake/*/bin/ninja 2>/dev/null | sort -V | tail -1)"
fi
[ -x "$NINJA" ] || NINJA="$(command -v ninja || true)"
if [ -z "$NINJA" ]; then
    echo "错误：找不到 ninja（NDK 内置或系统）" >&2
    exit 1
fi

echo ">> NDK: $NDK"
echo ">> cmake: $CMAKE"
echo ">> ninja: $NINJA"
echo ">> ABI: ${ABIS[*]}"

# ---- badvpn 源码（固定 commit） ----
if [ ! -d "$BADVPN_DIR/.git" ]; then
    echo ">> 拉取 badvpn 源码..."
    rm -rf "$BADVPN_DIR"
    if ! git clone --quiet https://github.com/ambrop72/badvpn "$BADVPN_DIR"; then
        echo ">> 直连失败，尝试本地代理 7890 重试..."
        rm -rf "$BADVPN_DIR"
        git clone --quiet -c http.proxy=http://127.0.0.1:7890 https://github.com/ambrop72/badvpn "$BADVPN_DIR"
    fi
fi

CURRENT_COMMIT="$(git -C "$BADVPN_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$BADVPN_COMMIT" ]; then
    echo ">> 检出固定 commit $BADVPN_COMMIT"
    git -C "$BADVPN_DIR" fetch --quiet origin "$BADVPN_COMMIT" || \
        git -C "$BADVPN_DIR" fetch --quiet -c http.proxy=http://127.0.0.1:7890 origin "$BADVPN_COMMIT"
    git -C "$BADVPN_DIR" checkout --quiet "$BADVPN_COMMIT"
fi

# ---- 交叉编译 ----
for ABI in "${ABIS[@]}"; do
    BUILD_DIR="$BUILD_ROOT/$ABI"
    echo ">> 编译 $ABI ..."
    "$CMAKE" -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-21 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DBADVPN_SRC="$BADVPN_DIR"
    "$CMAKE" --build "$BUILD_DIR"

    mkdir -p "$JNI_LIBS/$ABI"
    cp "$BUILD_DIR/libtun2socks.so" "$JNI_LIBS/$ABI/libtun2socks.so"
    echo ">> 完成: $JNI_LIBS/$ABI/libtun2socks.so"
done

echo ">> 全部完成"
file "$JNI_LIBS"/*/libtun2socks.so
