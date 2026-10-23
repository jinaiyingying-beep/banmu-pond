#!/bin/bash
# 半亩塘 · 双击安装：打包 → 替换「应用程序」里的旧版 → 打开
cd "$(dirname "$0")"
LOG="$(pwd)/安装日志.txt"
exec > >(tee "$LOG") 2>&1
echo "=== 半亩塘安装 $(date) ==="

if ! xcode-select -p >/dev/null 2>&1; then
  echo "还没装「命令行工具」，正在弹出安装窗口。装完后再双击一次这个文件。"
  xcode-select --install
  read -p "按回车关闭…"
  exit 1
fi

echo "▸ 退出旧版…"
pkill -x BanmuPond 2>/dev/null; sleep 1

chmod +x build.sh
if ! ./build.sh; then
  echo ""
  echo "✗ 打包失败。把这个窗口里的内容截图发给 Claude，或者告诉它「看安装日志」。"
  read -p "按回车关闭…"
  exit 1
fi

echo "▸ 放进「应用程序」…"
rm -rf "/Applications/半亩塘.app"
cp -R "build/半亩塘.app" "/Applications/" || { echo "✗ 复制到「应用程序」失败"; read -p "按回车关闭…"; exit 1; }

if [ -d "build/半亩塘.saver" ]; then
  echo "▸ 安装屏保…"
  mkdir -p "$HOME/Library/Screen Savers"
  rm -rf "$HOME/Library/Screen Savers/半亩塘.saver"
  cp -R "build/半亩塘.saver" "$HOME/Library/Screen Savers/"
  killall legacyScreenSaver 2>/dev/null
  SAVER_DONE=1
fi

echo "▸ 打开新版…"
open "/Applications/半亩塘.app"
echo ""
echo "✓ 装好了！点菜单栏的小鱼图标 → 场景 → 兰寿缸（正视）"
if [ "$SAVER_DONE" = 1 ]; then
  echo "✓ 屏保也装好了：在「系统设置 → 屏幕保护程序」里选「半亩塘」"
  open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension" 2>/dev/null || open -b com.apple.systempreferences
fi
sleep 3
