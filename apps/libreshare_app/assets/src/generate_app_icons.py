#!/usr/bin/env python3
"""Generates multi-platform app icons from the source app icon (assets/logo/app_icon.png).

Supports:
- Android mipmap densities (mdpi, hdpi, xhdpi, xxhdpi, xxxhdpi)
- iOS AppIcon set (iPhone, iPad, App Store 1024x1024 RGB)
- macOS AppIcon set (16x16 up to 1024x1024)
- Windows app_icon.ico (multi-resolution embedded ICO)
- Linux desktop icon (libreshare.png 512x512)

Usage:
    python3 assets/src/generate_app_icons.py
"""
import os
import sys
from PIL import Image

def generate_icons():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    app_dir = os.path.abspath(os.path.join(script_dir, "..", ".."))
    
    src_icon_path = os.path.join(app_dir, "assets", "logo", "app_icon.png")
    if not os.path.exists(src_icon_path):
        print(f"Error: Source icon not found at {src_icon_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading source icon: {src_icon_path}")
    src_img = Image.open(src_icon_path)
    
    # 1. Android
    android_res = os.path.join(app_dir, "android", "app", "src", "main", "res")
    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android_sizes.items():
        out_dir = os.path.join(android_res, folder)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "ic_launcher.png")
        resized = src_img.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(out_path, format="PNG")
        print(f"  Android {folder}: {out_path} ({size}x{size})")

    # 2. iOS
    ios_iconset = os.path.join(app_dir, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    if os.path.exists(ios_iconset):
        ios_files = {
            "Icon-App-20x20@1x.png": (20, 20),
            "Icon-App-20x20@2x.png": (40, 40),
            "Icon-App-20x20@3x.png": (60, 60),
            "Icon-App-29x29@1x.png": (29, 29),
            "Icon-App-29x29@2x.png": (58, 58),
            "Icon-App-29x29@3x.png": (87, 87),
            "Icon-App-40x40@1x.png": (40, 40),
            "Icon-App-40x40@2x.png": (80, 80),
            "Icon-App-40x40@3x.png": (120, 120),
            "Icon-App-60x60@2x.png": (120, 120),
            "Icon-App-60x60@3x.png": (180, 180),
            "Icon-App-76x76@1x.png": (76, 76),
            "Icon-App-76x76@2x.png": (152, 152),
            "Icon-App-83.5x83.5@2x.png": (167, 167),
            "Icon-App-1024x1024@1x.png": (1024, 1024),
        }
        for filename, (w, h) in ios_files.items():
            out_path = os.path.join(ios_iconset, filename)
            resized = src_img.resize((w, h), Image.Resampling.LANCZOS)
            if filename == "Icon-App-1024x1024@1x.png":
                # App Store icon must be opaque RGB (no alpha)
                resized = resized.convert("RGB")
            resized.save(out_path, format="PNG")
            print(f"  iOS icon: {out_path} ({w}x{h})")

    # 3. macOS
    macos_iconset = os.path.join(app_dir, "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    if os.path.exists(macos_iconset):
        macos_files = {
            "app_icon_16.png": 16,
            "app_icon_32.png": 32,
            "app_icon_64.png": 64,
            "app_icon_128.png": 128,
            "app_icon_256.png": 256,
            "app_icon_512.png": 512,
            "app_icon_1024.png": 1024,
        }
        for filename, size in macos_files.items():
            out_path = os.path.join(macos_iconset, filename)
            resized = src_img.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(out_path, format="PNG")
            print(f"  macOS icon: {out_path} ({size}x{size})")

    # 4. Windows
    windows_res = os.path.join(app_dir, "windows", "runner", "resources")
    if os.path.exists(windows_res):
        ico_path = os.path.join(windows_res, "app_icon.ico")
        ico_sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)]
        src_img.save(ico_path, format="ICO", sizes=ico_sizes)
        print(f"  Windows ico: {ico_path} {ico_sizes}")

    # 5. Linux
    linux_dir = os.path.join(app_dir, "linux")
    if os.path.exists(linux_dir):
        linux_icon_path = os.path.join(linux_dir, "libreshare.png")
        resized = src_img.resize((512, 512), Image.Resampling.LANCZOS)
        resized.save(linux_icon_path, format="PNG")
        print(f"  Linux icon: {linux_icon_path} (512x512)")

    print("All platform icons successfully generated!")

if __name__ == "__main__":
    generate_icons()
