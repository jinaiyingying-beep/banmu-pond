#!/bin/bash
# 半亩塘 · 一键打包成 macOS App
# 需要：Xcode 或「命令行工具」（终端运行 xcode-select --install 安装）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/半亩塘.app"
BIN="BanmuPond"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

echo "▸ 编译 Swift…"
FLAGS=(-O -swift-version 5 -framework Cocoa -framework WebKit -framework ServiceManagement)
if swiftc "${FLAGS[@]}" -target arm64-apple-macos12.0 -o "build/$BIN-arm64" mac/main.swift 2>/dev/null \
  && swiftc "${FLAGS[@]}" -target x86_64-apple-macos12.0 -o "build/$BIN-x86_64" mac/main.swift 2>/dev/null; then
  lipo -create "build/$BIN-arm64" "build/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"
  echo "  通用版（Apple 芯片 + Intel）"
else
  swiftc "${FLAGS[@]}" -target "$(uname -m)-apple-macos12.0" -o "$APP/Contents/MacOS/$BIN" mac/main.swift
  echo "  本机架构：$(uname -m)"
fi
rm -f build/$BIN-*

echo "▸ 拷贝资源…"
cp mac/Info.plist "$APP/Contents/Info.plist"
cp web/*.html "$APP/Contents/Resources/web/"
if [ -d mac/AppIcon.iconset ]; then
  iconutil -c icns mac/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ 本机签名…"
codesign --force --deep --sign - "$APP" >/dev/null

echo ""
echo "✓ 完成：$(pwd)/$APP"
echo "  拖进「应用程序」文件夹后双击打开；设置在菜单栏的小鱼图标里。"
open build
