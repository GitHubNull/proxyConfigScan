#!/usr/bin/env python3
"""生成 ProxyScan 的 Android/iOS 应用图标与预览图。

默认只写 tmp/appicon/preview.png 供确认；--apply 才覆盖平台资源。
依赖：rsvg-convert（librsvg）+ Pillow（系统 python3 已有；缺失时用仓库内 uv venv）。
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
MOBILE = ROOT / "src" / "mobile"
ICON_DIR = MOBILE / "icon"
MASTER = ICON_DIR / "app_icon.svg"
FOREGROUND = ICON_DIR / "app_icon_foreground.svg"
MONOCHROME = ICON_DIR / "app_icon_monochrome.svg"
ANDROID_RES = MOBILE / "android" / "app" / "src" / "main" / "res"
IOS_ICONS = MOBILE / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
PREVIEW_DIR = ROOT / "tmp" / "appicon"
PREVIEW_FILE = PREVIEW_DIR / "preview.png"

CORNER_RADIUS_RATIO = 0.225

ANDROID_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

IOS_FILES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="108"
                android:endY="108"
                android:startColor="#0F766E"
                android:endColor="#134E4A" />
        </aapt:attr>
    </path>
</vector>
"""

FOREGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="1024"
    android:viewportHeight="1024">
    <group
        android:scaleX="0.75"
        android:scaleY="0.75"
        android:translateX="128"
        android:translateY="128">
        <path
            android:pathData="M430,258H258v172"
            android:fillColor="#00000000"
            android:strokeColor="#FFFFFF"
            android:strokeWidth="76"
            android:strokeLineCap="round"
            android:strokeLineJoin="round" />
        <path
            android:pathData="M594,258h172v172"
            android:fillColor="#00000000"
            android:strokeColor="#FFFFFF"
            android:strokeWidth="76"
            android:strokeLineCap="round"
            android:strokeLineJoin="round" />
        <path
            android:pathData="M258,594v172h172"
            android:fillColor="#00000000"
            android:strokeColor="#FFFFFF"
            android:strokeWidth="76"
            android:strokeLineCap="round"
            android:strokeLineJoin="round" />
        <path
            android:pathData="M472,424h-30l70,-114l70,114h-30v281a40,40 0,0 1,-80,0Z"
            android:fillColor="#2DD4BF" />
    </group>
</vector>
"""

MONOCHROME_XML = FOREGROUND_XML.replace('android:fillColor="#2DD4BF"', 'android:fillColor="#FFFFFF"')

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"""


def require_tools():
    if subprocess.run(["which", "rsvg-convert"], capture_output=True).returncode != 0:
        sys.exit("缺少 rsvg-convert：请安装 librsvg2-bin 后重试")


def render(svg: Path, size: int) -> Image.Image:
    out = PREVIEW_DIR / f"_render_{svg.stem}_{size}.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(out), str(svg)],
        check=True,
    )
    return Image.open(out).convert("RGBA")


def rounded(img: Image.Image, radius_ratio: float = CORNER_RADIUS_RATIO) -> Image.Image:
    size = img.width
    mask = Image.new("L", (size, size), 0)
    radius = max(1, round(size * radius_ratio))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def circle_masked(img: Image.Image) -> Image.Image:
    size = img.width
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def diagonal_gradient(size: int, start: tuple, end: tuple) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    px = img.load()
    denom = max(1, 2 * (size - 1))
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            px[x, y] = tuple(
                round(start[i] + (end[i] - start[i]) * t) for i in range(3)
            ) + (255,)
    return img


def adaptive_preview(size: int) -> Image.Image:
    base = diagonal_gradient(size, (15, 118, 110), (19, 78, 74))
    base.alpha_composite(render(FOREGROUND, size))
    return circle_masked(base)


def monochrome_preview(size: int) -> Image.Image:
    base = Image.new("RGBA", (size, size), (75, 85, 99, 255))
    base.alpha_composite(render(MONOCHROME, size))
    return circle_masked(base)


def load_font(size: int, bold: bool = False):
    candidates = [
        f"/usr/share/fonts/opentype/noto/NotoSansCJK-{'Bold' if bold else 'Regular'}.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def build_preview():
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    canvas = Image.new("RGB", (1480, 1010), "#0B1220")
    draw = ImageDraw.Draw(canvas)
    title = load_font(30, bold=True)
    label = load_font(20)
    small = load_font(18)

    draw.text((48, 28), "ProxyScan 图标预览：扫码框 + 隧道箭头", font=title, fill="#F9FAFB")

    big = rounded(render(MASTER, 512))
    canvas.paste(big, (48, 84), big)
    draw.text((48, 620), "Android 传统图标（预圆角 22.5%）", font=label, fill="#9CA3AF")

    draw.rounded_rectangle((640, 70, 1440, 660), radius=28, fill="#F3F4F6")
    masked = rounded(render(MASTER, 512))
    canvas.paste(masked, (700, 104), masked)
    draw.text((700, 628), "启动器遮罩示意（浅色背景）", font=small, fill="#4B5563")

    draw.text((48, 690), "各密度：192 / 144 / 96 / 72 / 48 px", font=label, fill="#9CA3AF")
    x = 48
    for size in (192, 144, 96, 72, 48):
        icon = rounded(render(MASTER, size))
        canvas.paste(icon, (x, 734), icon)
        x += size + 36

    draw.text((840, 690), "自适应图标（圆形遮罩）", font=label, fill="#9CA3AF")
    adaptive = adaptive_preview(240)
    canvas.paste(adaptive, (840, 734), adaptive)

    draw.text((1140, 690), "单色图标（主题化）", font=label, fill="#9CA3AF")
    mono = monochrome_preview(240)
    canvas.paste(mono, (1140, 734), mono)

    canvas.save(PREVIEW_FILE)
    print(f"预览已生成：{PREVIEW_FILE}")


def write_xml(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def apply_android():
    for density, size in ANDROID_SIZES.items():
        out_dir = ANDROID_RES / f"mipmap-{density}"
        out_dir.mkdir(parents=True, exist_ok=True)
        rounded(render(MASTER, size)).save(out_dir / "ic_launcher.png")

    drawable = ANDROID_RES / "drawable"
    write_xml(drawable / "ic_launcher_background.xml", BACKGROUND_XML)
    write_xml(drawable / "ic_launcher_foreground.xml", FOREGROUND_XML)
    write_xml(drawable / "ic_launcher_monochrome.xml", MONOCHROME_XML)
    write_xml(ANDROID_RES / "mipmap-anydpi-v26" / "ic_launcher.xml", ADAPTIVE_XML)
    print("Android：5 档 mipmap + adaptive/monochrome vector 已写入")


def apply_ios():
    contents = json.loads((IOS_ICONS / "Contents.json").read_text(encoding="utf-8"))
    referenced = {item["filename"] for item in contents["images"] if "filename" in item}
    if referenced != set(IOS_FILES):
        missing = referenced - set(IOS_FILES)
        extra = set(IOS_FILES) - referenced
        sys.exit(f"iOS Contents.json 与导出清单不一致：缺少={missing} 多余={extra}")

    for name, size in IOS_FILES.items():
        render(MASTER, size).convert("RGB").save(IOS_ICONS / name, optimize=True)
    print(f"iOS：{len(IOS_FILES)} 个尺寸已写入（无 alpha）")


def verify():
    for name, size in IOS_FILES.items():
        img = Image.open(IOS_ICONS / name)
        assert img.size == (size, size), f"{name} 尺寸 {img.size} != {size}"
        assert img.mode == "RGB", f"{name} 含 alpha 通道：{img.mode}"
    for density, size in ANDROID_SIZES.items():
        img = Image.open(ANDROID_RES / f"mipmap-{density}" / "ic_launcher.png")
        assert img.size == (size, size), f"mipmap-{density} 尺寸 {img.size} != {size}"
    assert (ANDROID_RES / "mipmap-anydpi-v26" / "ic_launcher.xml").exists()
    print("校验通过：Android 5 档尺寸正确，iOS 尺寸与 Contents.json 一致且无 alpha")


def main():
    parser = argparse.ArgumentParser(description="生成 ProxyScan 应用图标")
    parser.add_argument("--apply", action="store_true", help="覆盖 Android/iOS 图标资源")
    args = parser.parse_args()

    require_tools()
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    build_preview()
    if args.apply:
        apply_android()
        apply_ios()
        verify()
        build_preview()
    else:
        print("未加 --apply：仅生成预览，未改动平台资源。")


if __name__ == "__main__":
    main()
