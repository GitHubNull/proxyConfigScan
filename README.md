# proxyConfigScan

扫码配置 Burp Suite 抓包代理的跨平台工具：手机扫描二维码 → 解析代理地址 → 建立本地 VPN 转发 → 全设备流量经 HTTP CONNECT 隧道到达 Burp。配套 Burp 插件负责生成二维码，并对回环地址监听给出引导。

**仅供授权安全测试使用，详见 [DISCLAIMER.md](DISCLAIMER.md)。**

## 功能特性

- **扫码即配代理**：Burp 插件生成代理配置二维码，手机扫码后一键启动 VPN 转发，无需系统 Wi-Fi 代理设置
- **回环监听拦截**：扫码识别到回环地址（127.0.0.0/8、::1、localhost）时阻断并提示——该配置下手机流量无法到达 Burp
- **回环引导面板**（插件侧）：选中回环监听地址时给出四步图文引导 + 本机局域网 IP 一键复制
- **全设备流量抓包**：本地 VPN 接管 → tun2socks → HTTP CONNECT 隧道 → Burp（含非 HTTP  aware 的 APP）
- **实时流量统计**：tx/rx 字节、活跃连接、DNS 查询、UDP 丢弃数，状态页实时刷新
- **配置历史**：成功使用的代理配置自动记录（SQLite），可复用、可删除
- **双端同面**：Android（Kotlin VpnService + libtun2socks）与 iOS（Swift NEPacketTunnelProvider）共用同一 Method/EventChannel 协议

## 模块与目录

| 目录 | 说明 |
|---|---|
| `src/mobile/` | Flutter 工程（Dart 源码在 `lib/`；`android/`、`ios/` 为生成工程） |
| `src/burp-plugin/` | Burp 插件 Maven 模块（Montoya API） |
| `script/` | 构建与调试脚本（见下表） |
| `doc/` | 设计与规约文档（架构、VPN 转发设计、QR 格式、构建运行等） |

## 快速开始

前置：JDK 21（构建用）、Flutter SDK、Android SDK；iOS 编译走 GitHub Actions CI（无本机 macOS）。

```bash
# Burp 插件
script/burp-plugin-build.sh          # 产出 target/proxy-config-scan-*.jar

# Android APP
script/android-build.sh build debug  # 或 release；脚本内自带 JAVA_HOME=21
script/adb-install.sh                # 默认装 release，注意 flavor 对应

# 测试二维码（无 Burp 时调试用）
script/gen-test-qr.sh 192.168.1.10 8080
```

## 文档索引

- [doc/architecture.md](doc/architecture.md) — 总体架构与目录规范
- [doc/vpn-forwarding-design.md](doc/vpn-forwarding-design.md) — VPN 本地转发设计（双端同面协议）
- [doc/qr-format-spec.md](doc/qr-format-spec.md) — 二维码格式规约
- [doc/burp-plugin.md](doc/burp-plugin.md) — Burp 插件组件与行为
- [doc/build-run.md](doc/build-run.md) — 构建与运行
- [doc/known-limitations.md](doc/known-limitations.md) — 已知限制

## 版本与发布

版本历史见 [CHANGELOG.md](CHANGELOG.md)；发布 tag 为语义化版本（`vMAJOR.MINOR.PATCH`）。本仓库为私有仓库。
