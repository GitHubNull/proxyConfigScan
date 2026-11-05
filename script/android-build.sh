#!/usr/bin/env bash
# Flutter Android 构建/运行封装（显式 JDK 21，不改动全局配置）
#
# 用法：
#   script/android-build.sh build [debug|release]   默认 release + split-per-abi
#   script/android-build.sh run                     flutter run 到已连接设备
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/dev_env/android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/dev_env/android/gradle}"
export http_proxy="${http_proxy:-http://127.0.0.1:7890}"
export https_proxy="${https_proxy:-http://127.0.0.1:7890}"
FLUTTER="$HOME/dev_env/flutter/flutter/bin/flutter"

MODE="${1:-build}"
FLAVOR="${2:-release}"

cd "$ROOT_DIR/src/mobile"

case "$MODE" in
    build)
        "$FLUTTER" build apk "--$FLAVOR" --split-per-abi
        echo ">> 产物目录: src/mobile/build/app/outputs/flutter-apk/"
        ls build/app/outputs/flutter-apk/*.apk
        ;;
    run)
        "$FLUTTER" run
        ;;
    *)
        echo "用法: $0 [build [debug|release] | run]" >&2
        exit 1
        ;;
esac
