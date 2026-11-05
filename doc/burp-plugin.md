# Burp 插件模块说明

## 功能现状

Burp 加载后在标签栏新增 **ProxyScan QR** 页签：

1. 自动探测本机局域网 IPv4 填入地址栏（失败回退 `127.0.0.1`），端口默认 8080；
2. 点「生成二维码」按 `doc/qr-format-spec.md` 组装 URI `http://host:port` 并渲染 PNG；
3. 填回环地址时给出醒目警告（手机无法访问 127.0.0.1）。

- `ProxyQrExtension`：扩展入口，注册标签页。
- `ProxyQrTab`：Swing 表单（地址/端口/生成按钮 + 二维码 + 警告）。
- `qr/QrCodeGenerator`：zxing core 编码（纠错 M、白边 2 module），PNG 用 JDK ImageIO 输出，不依赖 zxing-javase。

## 关键约束：montoya-api 无代理监听器枚举接口

核实 montoya-api 2026.7 全包：`api.proxy()` 仅暴露 history/handler 注册，无 Proxy listener 配置读取
（早期文档曾计划 `api.proxy().specifications()`，该接口不存在）。因此地址由用户对照
**Burp → Settings → Network → Connections → Proxy listeners** 手填，默认值为自动探测的局域网 IP。

## 依赖与构建

| 依赖 | 版本 | scope | 说明 |
|---|---|---|---|
| `net.portswigger.burp.extensions:montoya-api` | 2026.7 | provided | Burp 官方扩展 API，Burp 运行时自带 |
| `com.google.zxing:core` | 3.5.3 | compile | 二维码编码，shade 随包打进 jar |
| `org.junit.jupiter:junit-jupiter` | 5.10.2 | test | QrCodeGenerator 单测 |

- 编译级别 Java 17（Montoya 要求）。构建统一走 `script/burp-plugin-build.sh`（无参默认 `package`，显式 `JAVA_HOME=21`）。
- maven-shade-plugin 绑定 package 产出 fat-jar（Burp 单 jar 加载）；surefire 3.2.5 跑 JUnit5。
- 产物：`target/burp-proxy-qr-plugin-<version>.jar`（含 zxing，约 600KB）。
- aliyun 镜像已由 `~/.m2/settings.xml` 全局接管，pom 不写 mirror 段。

## 测试

`QrCodeGeneratorTest` 4 项：PNG 魔数/结构、生成→zxing 解码回读 roundtrip、空 URI 拒绝、尺寸越界拒绝。

## Burp 侧加载

Burp Suite → Extensions → Install → 选择 `burp-proxy-qr-plugin-<version>.jar`。
加载成功输出区显示「ProxyScan QR 插件已加载」。

## 迭代规划

1. montoya-api 若后续版本开放监听器枚举，改为自动填充全部 listener 下拉选择（含 `0.0.0.0` 替换为局域网 IP）。
2. 二维码下方加一键复制 URI；支持同时展示多个 listener 的二维码。
