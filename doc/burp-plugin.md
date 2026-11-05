# Burp 插件模块说明

## 功能现状

Burp 加载后在标签栏新增 **ProxyScan QR** 页签，**零配置**出码：

1. 打开页签即**进程反查** Burp 实际监听的 TCP 端口（主路径，见下节），填入下拉框；
2. 选中监听器立即出码：绑定 `0.0.0.0`/空（全部接口）自动替换为本机探测的局域网 IPv4，
   回环绑定给红色警告（手机扫了连不上）；
3. 「重新读取」可刷新；手填地址/端口兜底。

- `ProxyQrExtension`：扩展入口，注册标签页。
- `BurpProcessScanner`：进程反查（主路径）。
- `ProxyListenerDetector`：官方配置导出 API 读取（兜底路径）。
- `ProxyQrTab`：Swing UI（监听器下拉 + 二维码 + 警告 + 手填兜底）。
- `qr/QrCodeGenerator`：zxing core 编码（纠错 M、白边 2 module），PNG 用 JDK ImageIO 输出。

## 监听器获取：进程反查为主，配置导出兜底

历史结论（全部实测/全包核实）：

1. montoya-api 2026.7 无监听器枚举接口（`api.proxy()` 仅 history/handler）；
2. `exportUserOptionsAsJson` 在本机 Burp（Community 2026）实测拿不到监听器——
   Burp 2023.9+ 代理监听器移到 project options，且磁盘 `~/.BurpSuite/UserConfig*.json`
   不含监听器段（运行期不落盘）；
3. **主路径（用户提出）**：扫系统实际监听端口 → 反查进程命令行含 `burpsuite` 确认 →
   得到真实绑定地址端口。Linux 走 `/proc/net/tcp{,6}`（LISTEN 态）+ `/proc/<pid>/fd`
   socket inode 精确归属（同用户无需 root）；其他平台回退 `netstat -ano` 按 pid 过滤。
   已在真机 Burp 上预验：`::ffff:127.0.0.1:8181` 等监听项可按 inode 精确归属到 Burp 进程。
4. 兜底路径仍是配置导出 API（project→user、按路径→全量四组合，两种 JSON 形态容错）。

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
