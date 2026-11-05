# 总体架构

## 项目定位

扫码配置 Burp Suite 抓包代理：移动应用扫描二维码 → 解析代理地址 → 建立本地 VPN 转发 → 全设备流量经 HTTP CONNECT 隧道到达 Burp。历史配置存 SQLite。配套 Burp 插件负责生成二维码（迭代期开发，本期仅骨架）。

## 双模块总览

```
Android 端                      iOS 端                    局域网        本机 Linux
┌───────────────────┐   ┌──────────────────────┐                 ┌──────────────┐
│ Flutter APP (Dart) │   │ Flutter APP (Dart)    │                 │ Burp :8080   │
│  ↓ Method/EventCh. │   │  ↓ Method/EventCh.    │                 │ (本期不动)    │
│ Kotlin VpnService  │   │ Swift PacketTunnel    │── Wi-Fi ───────→│ ← 插件(骨架)  │
│ ├ libtun2socks.so  │   │ (NEPacketTunnelProv.) │  HTTP CONNECT   │              │
│ ├ SOCKS5+CONNECT桥 │   │ ├ NEPacketTunnelFlow  │  隧道            │              │
│ └ DNS→223.5.5.5    │   │ └ CONNECT 转发(同规约) │                 │              │
└───────────────────┘   └──────────────────────┘                 └──────────────┘
   本机真机调试验证           仅 CI 编译验证（无 macOS）
```

- **Android 数据流**：App TCP 连接 → VpnService tun fd → libtun2socks（用户态 IP/TCP 栈）→ 127.0.0.1:10808 本地 SOCKS5 → `CONNECT host:port` 到 Burp → 双向 relay。UDP/53 → udpgw 协议 → DnsForwarder → 公共 DNS 直连。
- **iOS 数据流**：与 Android 同规约（见 vpn-forwarding-design.md），NEPacketTunnelProvider 替换 VpnService。本期不实现，仅 runner 预留。

## 目录规范

| 目录 | 归属 |
|---|---|
| `src/mobile/` | Flutter 工程（lib/ Dart 源码；android/ios 为生成工程） |
| `src/burp-plugin/` | Burp 插件 Maven 模块 |
| `doc/` | 全部文档（本目录） |
| `script/` | 辅助脚本（构建/安装/二维码），均不改全局配置 |
| `test/` | 测试（`unit/dart/` flutter test；`jvm/` 本地桥单测） |
| `tmp/` | 临时产物（gitignore：badvpn 源码、构建目录、uv venv、测试 QR） |
| `.github/workflows/` | CI 工作流（M5 加入） |

## 技术选型决策

| 领域 | 选定 | 否决项及理由 |
|---|---|---|
| 跨平台框架 | Flutter 3.47（dev_env 已有，双端一套代码） | RN（需 node 重型工具链）、原生双端（双倍工作量） |
| 状态管理 | Riverpod（编译期安全、粒度灵活） | Provider（维护停滞）、Bloc（三页面场景 ceremony 过重） |
| 扫码 | mobile_scanner（ML Kit 官方绑定，双端兼容） | qr_code_scanner（已废弃） |
| 存储 | sqflite（单表零代码生成） | drift（build_runner 代码生成，表少无收益） |
| tun 侧 TCP 栈 | badvpn tun2socks（NDK 交叉编译 .so，HTTP Toolkit/shadowsocks 同路线） | 自实现 TCP 栈（数千行高危）、gVisor netstack（需引入 Go 工具链） |
| 向上游 CONNECT | Kotlin 本地桥（Java Socket 可 `VpnService.protect()` 防回环，可 JVM 单测） | C 侧实现（protect 不方便、单测难） |
| 代理生效 | VPN 本地转发（免 root） | 直写系统代理（需 root）、引导手动配置（不算自动） |
| 插件 API | montoya-api 2026.7（Burp 官方唯一推荐） | 旧版 burp-extender-api（已废弃） |

## 关键设计原则

1. **防回环双保险**：`addDisallowedApplication(自身)` + 本地桥所有上游 socket `protect()`。
2. **双端同规约**：Android 桥与 iOS 桥遵守 vpn-forwarding-design.md 同一份 CONNECT 转发条款。
3. **二维码格式唯一事实源**：doc/qr-format-spec.md，APP（解析端）与插件（生成端）共同遵守。
4. **构建可复现**：badvpn 固定 commit（`07268f0`），脚本一键三 ABI；脚本内显式 `JAVA_HOME=21`，不改全局环境。
