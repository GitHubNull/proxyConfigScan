# 构建运行手册

## 环境一览（全部沿用既有 dev_env，不重装）

| 组件 | 位置 | 备注 |
|---|---|---|
| Flutter 3.47.9 / Dart 3.13.7 | `~/dev_env/flutter/flutter` | `PUB_HOSTED_URL=https://pub.flutter-io.cn` 已在 `~/.profile` |
| Android SDK（platforms 35/36、NDK 28.2、cmake 3.22.1） | `~/dev_env/android/sdk` | `ANDROID_HOME` 已在 `~/.profile` |
| JDK 21 | `/usr/lib/jvm/java-21-openjdk-amd64` | 构建脚本内显式 `JAVA_HOME`，系统默认仍为 JDK 8 |
| Maven 3.8.7 + aliyun 镜像 | `~/.m2/settings.xml` | pom.xml 无需 mirror 段 |
| gradle + 中国镜像 | `~/dev_env/android/gradle`（GRADLE_USER_HOME） | 发行包已预置、init.d 重写 aliyun；脚本内显式 export，agent shell 不加载 `~/.profile` 也能生效 |

> 注意：agent/CI 等非登录 shell 不加载 `~/.profile`，`GRADLE_USER_HOME`、`JAVA_HOME`、`ANDROID_HOME` 均由 `script/android-build.sh` 显式 export；缺失时 gradle 会静默回退到 `~/.gradle` 与 `/usr/lib/android-sdk`，导致镜像失效、下载极慢。
>
> wrapper 发行包源已改为腾讯镜像（`gradle-wrapper.properties` 的 `distributionUrl=https://mirrors.cloud.tencent.com/gradle/...`），CI 与本地均可直接用。

## 常用命令

```bash
# 原生库（badvpn tun2socks → jniLibs，三 ABI）
script/build-tun2socks.sh            # 全编
script/build-tun2socks.sh arm64-v8a  # 单 ABI 快速迭代

# Android 应用
script/android-build.sh build            # release + split-per-abi
script/android-build.sh build debug      # 调试用
script/android-build.sh run              # flutter run 到设备
script/adb-install.sh                    # 按设备 ABI 装包（自动重试）

# 测试二维码（Python 依赖只装进 tmp/.venv，uv 管理）
script/gen-test-qr.sh 192.168.x.x 8080

# Burp 插件
script/burp-plugin-build.sh package      # 产出 target/burp-proxy-qr-plugin-0.1.0.jar
```

## 端到端运行（M2 起）

1. Burp Suite → Proxy settings → listener 绑定**局域网 IP**（非仅 127.0.0.1），端口 8080。
2. `script/gen-test-qr.sh <本机局域网IP> 8080`，PNG 投屏。
3. APP 扫码 → 允许 VPN 授权 → 状态页显示"运行中"。
4. 手机浏览器访问 http://neverssl.com → Burp HTTP history 出现条目即通。

## tun2socks 说明

- 源码：github.com/ambrop72/badvpn，固定 commit `07268f0`，由脚本拉取到 `tmp/badvpn-src/`（gitignore，可离线复用）。
- 构建：`src/mobile/android/app/src/main/cpp/{CMakeLists.txt,tun2socks_jni.c}` 为自有构建，不修改 badvpn 源码。
- 关键宏：`BADVPN_LINUX / BADVPN_USE_EPOLL / BADVPN_USE_SIGNALFD / BADVPN_BREACTOR_BADVPN / BADVPN_LITTLE_ENDIAN / BADVPN_THREAD_SAFE=1`（badvpn 官方 cmake 的平台检测不识别 Android，由 CMakeLists 显式注入）。
- JNI 入口：`Tun2Socks.run(tunFd, mtu, netifIp, netifMask, socksAddr, udpgwAddr)` / `Tun2Socks.stop()`，返回 0 或负值错误码（Kotlin 侧镜像定义）。
- 兼容边界：NDK 28 移除了内置 ninja（用 SDK cmake 自带）；NDK 高版本 clang 把隐式函数声明当错误（已加 `-Wno-implicit-function-declaration`）。

## CI 工作流（M5 加入）

| 工作流 | runner | 产物 |
|---|---|---|
| `.github/workflows/android-build.yml` | ubuntu | split-per-abi APK artifact |
| `.github/workflows/ios-build.yml` | macos（计时 ×10 倍率，限定 push main/手动触发） | unsigned IPA artifact |

私有仓即可用 Actions；推送走本机代理（`~/.profile` 已配）。IPA 安装：Xcode/Apple Configurator 2 装到本机信任设备，或 AltStore/Sideloadly 侧载（免费 Apple ID 7 天有效）。

## 常见报错对照

| 现象 | 原因与对策 |
|---|---|
| `mvn` 编译报 `invalid target release: 17` | 用了系统 JDK 8 → 用 `script/burp-plugin-build.sh`（显式 JAVA_HOME=21） |
| flutter 构建报 `Unsupported class file major version` | 同上，用 `script/android-build.sh` |
| tun2socks 构建 `找不到 ninja` | NDK 28 无内置 ninja → 脚本已回退 SDK cmake 目录探测 |
| `Unknown byte order` | BADVPN_LITTLE_ENDIAN 未定义 → 检查 cpp/CMakeLists.txt |
| gradle 依赖拉取超时 | 全局镜像已配；仍失败重试，或检查代理 |
| 手机扫码后 Burp 无流量 | 九成是 Burp listener 绑了 127.0.0.1 → 改绑局域网 IP |
