# 应用图标

设计方向：**扫码框 + 隧道箭头**——深青渐变底、白色 QR 取景角标、中央青色箭头自下而上，表达“扫码 → 代理转发”。无文字、无第三方商标色，48px 下仍可辨认。

## 文件

| 文件 | 用途 |
|---|---|
| `app_icon.svg` | 1024 母版（满幅方形），供 Android 传统图标预圆角与 iOS 全尺寸导出 |
| `app_icon_foreground.svg` | Android 自适应图标前景（内容缩至 66dp 安全圆内） |
| `app_icon_monochrome.svg` | Android 13 主题化图标单色剪影 |

## 色值

- 背景渐变：`#0F766E → #134E4A`（母版另含 `#115E59` 过渡与轻微径向高光）
- 箭头：`#2DD4BF → #5EEAD4`
- 取景角标：`#FFFFFF`

## 生成

```bash
python3 script/gen-app-icons.py            # 只出预览 tmp/appicon/preview.png
python3 script/gen-app-icons.py --apply    # 覆盖 Android/iOS 资源并校验
```

依赖 `rsvg-convert` 与 Pillow 10（系统 python3 已装；如需隔离，用仓库内 uv venv 安装 Pillow，禁止全局 pip）。

产物：

- Android 传统图标：`mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png`（48/72/96/144/192，预圆角 22.5%）
- Android 自适应：`mipmap-anydpi-v26/ic_launcher.xml` + `drawable/ic_launcher_{background,foreground,monochrome}.xml`
- iOS：`AppIcon.appiconset` 15 个独立文件（对应 Contents.json 的 19 条引用），1024 marketing 图强制 RGB、无 alpha

## 验证

```bash
unzip -l src/mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk | grep ic_launcher
"$ANDROID_HOME"/build-tools/*/aapt2 dump badging <apk> | grep -i application-icon
```

- `unzip -l` 应包含 `mipmap-anydpi-v26/ic_launcher.xml` 与三份 vector drawable。
- iOS 图标由 CI 的 `actool` 编译验证；改图后重跑脚本即可，不要手改平台 PNG/vector。
