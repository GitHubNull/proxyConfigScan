# Burp 插件模块说明

## 功能现状

Burp 加载后在标签栏新增 **ProxyScan QR** 页签，**零配置**出码：

1. 打开页签即通过 `api.burpSuite().exportUserOptionsAsJson("proxy.proxy_request_listeners")`
   读取运行中的 Burp Proxy 监听器，填入下拉框（停用的不显示）；
2. 选中监听器立即出码：绑定 `0.0.0.0`/空（全部接口）自动替换为本机探测的局域网 IPv4，
   回环绑定给红色警告（手机扫了连不上）；
3. 「重新读取」可刷新（Burp 里改完监听配置后点一下）；
4. 手填地址/端口兜底（读取失败时）。

- `ProxyQrExtension`：扩展入口，注册标签页。
- `ProxyListenerDetector`：官方配置导出 API 读取 + 解析监听器（路径查询/全量导出两种形态容错）。
- `ProxyQrTab`：Swing UI（监听器下拉 + 二维码 + 警告 + 手填兜底）。
- `qr/QrCodeGenerator`：zxing core 编码（纠错 M、白边 2 module），PNG 用 JDK ImageIO 输出。

## 关键约束：montoya-api 无监听器枚举接口

核实 montoya-api 2026.7 全包：`api.proxy()` 仅暴露 history/handler 注册，无 Proxy listener 读取
（早期文档曾计划 `api.proxy().specifications()`，该接口不存在）。官方替代途径是
`BurpSuite.exportUserOptionsAsJson(path)` 导出实时配置，本插件即用此实现自动读取。
注意磁盘上的 `~/.BurpSuite/UserConfig*.json` 不含监听器段（运行期不落盘），不要走文件解析。

## 依赖与构建

| 依赖 | 版本 | scope | 说明 |
|---|---|---|---|
| `net.portswigger.burp.extensions:montoya-api` | 2026.7 | provided | Burp 官方扩展 API，Burp 运行时自带 |
| `com.google.zxing:core` | 3.5.3 | compile | 二维码编码，shade 随包打进 jar |
| `com.google.code.gson:gson` | 2.11.0 | compile | 解析 Burp 配置导出 JSON，shade 打进 jar |
| `org.junit.jupiter:junit-jupiter` | 5.10.2 | test | 单测 |

- 编译级别 Java 17（Montoya 要求）。构建统一走 `script/burp-plugin-build.sh`（无参默认 `package`，显式 `JAVA_HOME=21`）。
- maven-shade-plugin 绑定 package 产出 fat-jar（Burp 单 jar 加载）；surefire 3.2.5 跑 JUnit5。
- 产物：`target/burp-proxy-qr-plugin-<version>.jar`（含 zxing + gson，约 900KB）。
- aliyun 镜像已由 `~/.m2/settings.xml` 全局接管，pom 不写 mirror 段。

## 测试

`QrCodeGeneratorTest` 4 项：PNG 魔数/结构、生成→zxing 解码回读 roundtrip、空 URI 拒绝、尺寸越界拒绝。

## Burp 侧加载

Burp Suite → Extensions → Install → 选择 `burp-proxy-qr-plugin-<version>.jar`。
加载成功输出区显示「ProxyScan QR 插件已加载」。

## 迭代规划

1. montoya-api 若后续版本开放监听器枚举，改为自动填充全部 listener 下拉选择（含 `0.0.0.0` 替换为局域网 IP）。
2. 二维码下方加一键复制 URI；支持同时展示多个 listener 的二维码。
