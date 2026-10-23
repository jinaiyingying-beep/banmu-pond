#!/bin/bash
# 半亩塘 · 屏保诊断：收集最近 15 分钟屏保相关的系统日志，存到同一文件夹的「屏保诊断.txt」
cd "$(dirname "$0")"
OUT="$(pwd)/屏保诊断.txt"
{
  echo "=== 屏保诊断 $(date) ==="
  sw_vers
  echo "--- 已安装的屏保 ---"
  ls -la "$HOME/Library/Screen Savers/" 2>&1
  echo "--- 半亩塘相关日志 ---"
  log show --last 15m --style compact --predicate 'eventMessage CONTAINS "BanmuSaver" OR eventMessage CONTAINS "半亩塘" OR eventMessage CONTAINS "local.banmu"' 2>&1 | tail -150
  echo "--- 屏保进程报错 ---"
  log show --last 15m --style compact --predicate '(process CONTAINS "legacyScreenSaver" OR process CONTAINS "ScreenSaverEngine" OR process CONTAINS "WebContent") AND messageType >= 16' 2>&1 | tail -150
} > "$OUT" 2>&1
echo "✓ 诊断完成，已存到：$OUT"
echo "回到 Claude 说一句「看屏保诊断」就行。"
sleep 3
