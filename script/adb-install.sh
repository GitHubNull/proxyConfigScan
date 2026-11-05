#!/usr/bin/env bash
# 安装 split-per-abi APK 到已连接设备（按设备 ABI 选包，失败自动重试一次）
#
# 用法：script/adb-install.sh [debug|release]   默认 release
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAVOR="${1:-release}"
APK_DIR="$ROOT_DIR/src/mobile/build/app/outputs/flutter-apk"

DEVICE_ABI="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
echo ">> 设备 ABI: $DEVICE_ABI"

case "$DEVICE_ABI" in
    arm64-v8a)   APK="$APK_DIR/app-arm64-v8a-$FLAVOR.apk" ;;
    armeabi-v7a) APK="$APK_DIR/app-armeabi-v7a-$FLAVOR.apk" ;;
    x86_64)      APK="$APK_DIR/app-x86_64-$FLAVOR.apk" ;;
    *)           echo "错误：未识别的设备 ABI: $DEVICE_ABI" >&2; exit 1 ;;
esac

if [ ! -f "$APK" ]; then
    echo "错误：找不到 $APK，请先运行 script/android-build.sh build $FLAVOR" >&2
    exit 1
fi

echo ">> 安装 $APK"
if ! adb install -r "$APK"; then
    echo ">> 首次安装失败（USB 可能掉线），重试一次..."
    adb wait-for-device
    adb install -r "$APK"
fi

echo ">> 安装完成"
adb shell pm list packages | grep proxy_config_scan
