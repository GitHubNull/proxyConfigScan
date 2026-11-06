# Changelog

## [Unreleased]

### Added
- 专属 App 图标：扫码框 + 自下而上隧道箭头（深青渐变底），覆盖 Android 传统/自适应/单色主题图标与 iOS 全尺寸；母版与导出脚本见 `src/mobile/icon/`
- 状态页「HTTPS 抓包证书」卡片：一键从当前/最近的 Burp 代理获取 CA——Android 11+ 保存到 `Download/BurpSuite-CA.cer` 并跳安全设置引导手动安装（<11 直接弹系统安装器），iOS 保存到文件并弹分享面板；安装后按 SHA-256 指纹复检状态
- 「最近一次扫码」持久化：DB v2 新增 `last_scan` 单行表，扫码成功双写；状态页冷启动仍可展示并一键回填启动

### Fixed
- 扫码成功后相机仍占用：相机改为仅在「扫码页可见 + App 前台 + 等待扫码」时运行，成功/失败/切页/退后台/启动代理即释放，连续扫码自动恢复
- 状态页“最近一次扫码”恒为空：改读持久化的最近扫码记录，不再依赖启动后即被清空的内存状态
- 历史记录写入与首次加载竞态：写操作串行化，避免新记录被旧列表覆盖

## [0.1.1] - 2026-11-06

### Added
- GitHub Actions 新增 `burp-plugin.yml`：push main/PR/手动触发，JDK 21 跑 `mvn test` + `mvn package`，上传插件 jar artifact（与 android/ios 工作流同列，doc/build-run.md 已同步）

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
