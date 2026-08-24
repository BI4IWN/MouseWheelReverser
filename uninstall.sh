#!/bin/bash
# 停止并完全卸载滚轮反转
set -euo pipefail
LABEL="com.local.scroll-reverser"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f  "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ScrollReverser.app"
rm -f  "$HOME/Library/Logs/scroll-reverser.log"

echo "✔ 已停止并卸载。"
echo "  （可选）到 系统设置 → 隐私与安全性 → 辅助功能 中移除残留条目。"
