# Changelog

## [0.1.0] - 2026-11-06

首个发布版本。扫码配置 Burp 代理 → VPN 本地转发抓包全链路可用（Android 实机验证；iOS 编译走 GitHub Actions CI）。

### Added
- APP 扫码启动成功 → 提示 → 自动跳转「运行状态」页；识别失败 2 秒自动恢复扫码
- 动作进行中态（`VpnAction` + `runVpnAction`）：VPN 授权弹窗等 MethodChannel 挂起窗口期间按钮转圈禁用，状态页启停、历史页复用统一走该入口
- 历史记录复用拦截：回环地址（127.0.0.0/8、::1、localhost）直接阻断并提示；非局域网地址二次确认
- Burp 插件回环监听引导面板：选中回环地址时给出四步图文引导 + 本机局域网 IP 一键复制
- Burp 插件 Swing UI 重设计（`Ui`/`Preview` 组件）：主题色跟随 Burp、卡片化布局、统一主/幽灵按钮与输入框样式

### Fixed
- 流量统计恒定为零：统计事件在后台线程投递 EventSink 触发 `@UiThread` 校验异常，`scheduleAtFixedRate` 首次异常后静默停摆——所有事件统一改经主线程 Handler 投递，发送失败仅记日志
- 扫码出结果后相机持续占用：出结果即停相机、返回等待态再重启
- `ProxyListenerDetector` 伴随插件 UI 重设计修正
