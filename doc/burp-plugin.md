# Burp 插件模块说明

## 本期范围（骨架）

- `src/burp-plugin/pom.xml`：Maven 模块定义。
- `src/burp-plugin/src/main/java/com/proxyscan/burp/ProxyQrExtension.java`：扩展入口（`implements BurpExtension`），加载时注册名称并输出日志。
- `.../qr/QrCodeGenerator.java`：二维码生成器骨架（方法体 `TODO`，迭代期用 ZXing 填充）。

## 依赖与构建

| 依赖 | 版本 | scope | 说明 |
|---|---|---|---|
| `net.portswigger.burp.extensions:montoya-api` | 2026.7 | provided | Burp 官方扩展 API，Burp 运行时自带 |
| `com.google.zxing:core` | 3.5.3 | compile | 二维码生成（迭代期使用，本期编入验证依赖链路） |

- 编译级别 Java 17（Montoya 要求）。构建统一走 `script/burp-plugin-build.sh`（显式 `JAVA_HOME=21`）。
- 产物：`target/burp-proxy-qr-plugin-<version>.jar`。
- aliyun 镜像已由 `~/.m2/settings.xml` 全局接管，pom 不写 mirror 段。
- maven-shade-plugin 已声明但挂 `phase=none`：迭代期引入需打包进 jar 的第三方库时启用 fat-jar。

## 迭代规划

1. 读取 Proxy listener 地址（`api.proxy().specifications()`），按 `doc/qr-format-spec.md` 组装 URI（`0.0.0.0`/`127.0.0.1` 替换为局域网 IP）。
2. `QrCodeGenerator.toPng(uri, size)` 用 ZXing `MultiFormatWriter` + `MatrixToImageWriter` 实现（纠错 M、白边 2 module）。
3. 注册 UI Tab 或 Proxy 右键菜单展示二维码。
4. 同格式合规用例测试（对齐 qr-format-spec.md §4）。

## Burp 侧加载

Burp Suite → Extensions → Add → 选择 `burp-proxy-qr-plugin-<version>.jar`。
