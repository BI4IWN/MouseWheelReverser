#!/bin/bash
#
# 安装：编译 → 打包成 App → 注册 LaunchAgent（开机自启）
# 额外参数会透传给程序，例如：./install.sh --invert-x
#
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ScrollReverser.app"
LABEL="com.local.scroll-reverser"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/scroll-reverser.log"

echo "==> 编译..."
swiftc -O -o ScrollReverser main.swift

echo "==> 打包 $APP"
mkdir -p "$APP/Contents/MacOS"
cp ScrollReverser "$APP/Contents/MacOS/ScrollReverser"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ScrollReverser</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.scroll-reverser</string>
    <key>CFBundleName</key>
    <string>滚轮反转</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
# 优先用本地固定证书签名：重新编译后程序签名不变，无需重新授权
IDENTITY="ScrollReverser Local"
if codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "    已用本地固定证书签名（以后重编译不影响授权）"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> 注册 LaunchAgent（开机自启）"
EXTRA_ARGS=""
for a in "$@"; do
    EXTRA_ARGS="${EXTRA_ARGS}        <string>$a</string>
"
done
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/ScrollReverser</string>
$EXTRA_ARGS    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sleep 1
# bootout 异步清理可能未完成，bootstrap 失败时重试一次
launchctl bootstrap "gui/$UID" "$PLIST" || launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart "gui/$UID/$LABEL" 2>/dev/null || launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true

echo
echo "✔ 安装完成：已在后台运行，并设置了开机自启。"
echo
echo "★ 还差最后一步——授权（只需一次）："
echo "  1. 打开 系统设置 → 隐私与安全性 → 辅助功能"
echo "  2. 列表中出现“滚轮反转 / ScrollReverser”就打开开关；"
echo "     没有的话点 “+” 添加（文件对话框里按 Cmd+Shift+G 输入）：$APP"
echo "  3. 授权后最多等 10 秒自动生效"
echo "     （也可手动重启：launchctl kickstart -k gui/$UID/${LABEL}）"
echo
echo "日志：$LOG"
echo "卸载：./uninstall.sh"
