# 已知限制登记

> 验收不符或用户反馈问题时先查本文档定性：设计如此 / 平台限制 / 待修缺陷。

## iOS

| 限制 | 定性 | 说明 |
|---|---|---|
| 本机无法编译/调试 iOS | 平台限制 | 开发机为 Linux，Xcode 仅 macOS。验证方式：GitHub Actions macOS runner 构建 unsigned IPA 通过（M5 起双工作流绿）+ 代码评审；真机行为待有 Mac 后补验 |
| iOS 仅编译验证、未真机运行 | 平台限制 | PacketTunnel extension 已实现（hev + Swift 桥，设计见 vpn-forwarding-design.md §9）；无实体 macOS/iPhone，运行时行为未验，侧载安装见 build-run.md |
| 安装需侧载或付费账号 | 平台限制 | 免费 Apple ID 侧载 7 天过期需重签、同时限 3 个 App；长期分发需 99 美元/年开发者账号。NetworkExtension entitlement 免费账号在开发期可用 |
| iOS 无法自动安装/枚举 CA | 平台限制 | App 只能把 Burp CA 存到临时文件并弹分享面板；用户须存到「文件」后到 设置 → 通用 → VPN 与设备管理 安装，并在「证书信任设置」完全信任。安装结果 App 无法读取，状态卡片显示“无法检测” |

## 证书（Burp CA）

| 限制 | 定性 | 说明 |
|---|---|---|
| Android 11+ 无法一键静默安装用户 CA | 平台限制 | 系统禁止应用携带证书数据直接调用安装器（`KeyChain.createInstallIntent` 被限制，Reqable 非 root 同样只能下载后手动安装）。App 已做到自动获取 + 保存到 `Download/BurpSuite-CA.cer` + 跳转安全设置 + 回 App 指纹复检，最终确认必须在系统 UI 完成 |
| 用户 CA 不被部分被测 App 信任 | 被测 App 侧限制 | targetSdk 24+ 且未配置 `networkSecurityConfig` 的应用默认不信任用户 CA；浏览器通常可用。免 root 无解，需在被测 App 侧处理 |
| 不支持 root / 系统证书 | 设计如此 | 定位免 root 用户证书；不做写入系统信任库、不自动点击系统页面 |
| 非 Burp 代理或被关闭内建端点时取不到 CA | 设计如此 | 证书仅从 `http://burp/cert`、`http://burpsuite/cert` 获取；失败文案明确，保留 build-run.md 的手动导入兜底 |

## 网络能力

| 限制 | 定性 | 说明 |
|---|---|---|
| IPv6 不支持 | 设计如此（本期） | Builder 只配 `0.0.0.0/0`；IPv6 流量不进隧道。后续按需求评估 |
| 非 53 端口 UDP 丢弃 | 设计如此 | Burp 为 HTTP 代理，无法承载 UDP；游戏/语音类 UDP 应用不受影响地直连失败，需断开 VPN 使用 |
| DNS 走公共 DNS 直连不过 Burp | 设计如此 | Burp 无法解析 DNS over UDP；域名在 CONNECT 中明文传给 Burp，抓包仍可见 |
| SSL pinning 的 App 抓不到明文 | 被测 App 侧限制 | 隧道层正确，但 App 拒绝 Burp 证书。需在测试机上另行处理（如 Frida/重打包） |
| Burp 看到的全部是 CONNECT 隧道 | 设计如此 | IP 层转发的必然结果；HTTP 明文站点 Burp 可解，HTTPS 需装 CA |

## 设备/厂商

| 限制 | 定性 | 说明 |
|---|---|---|
| ColorOS 后台冻结 | 平台限制 | 一加/OPPO 需在系统设置允许本 App 后台运行并关闭电池优化，否则灭屏后连接中断 |
| ColorOS 拦截应用 logcat | 平台限制（已缓解） | untrusted_app 日志不进 logcat；引擎关键事件落盘 `files/vpn-engine.log`，debug 包用 `adb shell run-as com.proxyscan.proxy_config_scan cat files/vpn-engine.log` 读取 |
| ColorOS 上 `VpnService.protect()` 不可靠 | 平台限制（已缓解） | 离主线程调用返回 false 或抛 @UiThread 异常（即便切主线程也可能返回 false）；protect 降级为尽力调用，防回环由 `addDisallowedApplication(self)` 兜底（内核级路由排除，与 protect 无关） |
| USB 安装大 APK 易掉线 | 平台限制（已缓解） | 用 `--split-per-abi` 出小包 + `script/adb-install.sh` 自动重试 |

## 其他

| 限制 | 定性 | 说明 |
|---|---|---|
| Burp 插件功能已实现（M4 后迭代） | — | 零配置：进程反查自动发现 Burp 监听地址（见 burp-plugin.md）；无 Listener 时支持手动填写兜底 |
| 切蜂窝网络后 VPN 上游不可达 | 设计如此 | Burp 在局域网；切网后需重新扫码（历史记录一键复用） |
