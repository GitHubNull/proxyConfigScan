# AGENTS.md

本文件是 AI 编码代理在本仓库工作时的协作约定。人类贡献者也可参考。

## 项目一句话

扫码配置 Burp 代理 → 本地 VPN 转发抓包的跨平台工具（Flutter APP 双端 + Burp 插件）。先读 [doc/architecture.md](doc/architecture.md) 再动手。

## 硬规则

1. **禁止逆向 Burp 的 jar**：监听检测走 OS 层（/proc socket inode 进程反查），不 strings/zipgrep 翻厂商 jar 找配置键。
2. **真机物理动作交用户**：扫码、点授权弹窗等需要用户持机操作的步骤推到该步停下；不盲点用户手持设备（`input tap` 坐标=展示值×1.2 且易误触）。
3. **缺陷先定性再修**：验收不符项先判定是缺陷 / 设计如此 / 平台限制；设计如此对齐文档，平台限制登记 doc/known-limitations.md，缺陷才改代码。
4. **不加简化实现**：SPEC 要求的功能完整实现，不因时间/轮次压力缩水。
5. **诚实报告剩余范围**：骨架就是骨架，不说"就差一步"。

## 构建与验证命令

```bash
# Burp 插件（系统 java 是 1.8，构建脚本已处理；测试需 JDK 21）
cd src/burp-plugin && mvn test && mvn package

# APP 分析/测试/构建（必须走脚本，脚本内 JAVA_HOME=21；直接 flutter build 会因 Gradle 要 JVM 17+ 失败）
cd src/mobile && flutter analyze && flutter test
script/android-build.sh build release

# 安装前必查 APK 时间戳——只 build debug 装 release 的旧包陷阱一天踩过两次
ls -l src/mobile/build/app/outputs/flutter-apk/*.apk
```

- iOS 编译只靠 GitHub Actions CI（无本机 macOS）；"not acquired"=容量排队失败，重推即可。
- 后台命令显式 `cd`；管道接 `tail` 时 exit code 不可信（编译失败被吞→旧 APK 被装去测，装前查时间戳）。
- ColorOS 拦 logcat：APP 自身落盘 `files/vpn-engine.log`，用 `adb shell run-as com.proxyscan.proxy_config_scan cat files/vpn-engine.log` 读取。

## 代码约定

- 对话与产品 UI 默认中文；commit message 用 Conventional Commits + 中文描述（参考 `git log`）。
- 单源文件 ≤500 行硬上限，超限拆分不豁免。
- 默认不写注释；只在"为什么"不显然时写一行（隐藏约束、反直觉不变量、特定 bug 的 workaround）。
- 文档与设计/选型变更全量同步（doc/ 索引、版本、链接）。
- 技术栈：Dart/Flutter + Riverpod；Kotlin（VpnService/tun2socks JNI）；Swift（PacketTunnel）；Java 17（Burp 插件，Montoya API）。
- 平台通道协议（Android/iOS 同面）：MethodChannel `proxy_scan/vpn` + EventChannel `proxy_scan/vpn_events` + MethodChannel `proxy_scan/system`（CA 状态/安装/设置跳转），改动须双端同步并更新 doc/vpn-forwarding-design.md。

## Git 约定

- 只在用户明确要求时提交；push/release 需用户明确授权（smart-commit 技能批除外：版本+CHANGELOG+tag+push 一次走完）。
- 仓库默认私有；**本仓已于 2026-11-08 转公开**（用户决策：无涉密内容 + 无境外卡无法绑 billing，公开仓 Actions 标准 runner 免费）；禁止 force-push main；新远程仓需用户确认。
- 负面测试/诱饵文件用 ignore-config 排除，不删文件过门禁。

## 测试要点

- 单测：Dart 测试 DB 名必须每用例唯一（sqflite_common_ffi 按路径缓存 `:memory:` 实例共享）；过滤用 `--plain-name`。
- EventSink 必须主线程投递；定时器任务内异常要兜死（scheduleAtFixedRate 一次异常后静默停摆）。
- 用户报告的观察即事实——别要求重复验证同一观察；要新证据必须换层级并说明理由。
