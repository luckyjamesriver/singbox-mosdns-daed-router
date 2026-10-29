#!/usr/bin/env bash
# ==============================================================================
# setup-mac-winbox.sh - 为 macOS 注册 winbox:// 协议唤起助手 (专为 WinBox 4 / 3 设计)
# ==============================================================================

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "[-] 此脚本仅适用于 macOS 系统。"
  exit 1
fi

APP_PATH="/Applications/WinBox.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "[-] 未在 /Applications 目录下检测到 WinBox.app，请先安装官方 WinBox 客户端。"
  exit 1
fi

HANDLER_APP="/Applications/WinBox URL Handler.app"
TMP_SCRIPT="$(mktemp /tmp/winbox_handler.XXXXXX.applescript)"

cat << 'EOF' > "$TMP_SCRIPT"
on open location this_URL
	try
		set rawURL to this_URL as text
		if rawURL starts with "winbox://" then
			set targetHost to text 10 through -1 of rawURL
		else if rawURL starts with "winbox:" then
			set targetHost to text 8 through -1 of rawURL
		else
			set targetHost to rawURL
		end if
		
		if targetHost ends with "/" then
			set targetHost to text 1 through -2 of targetHost
		end if
		
		if targetHost contains "@" then
			set savedDelims to AppleScript's text item delimiters
			set AppleScript's text item delimiters to "@"
			set hostParts to text items of targetHost
			set targetHost to last item of hostParts
			set AppleScript's text item delimiters to savedDelims
		end if
		
		if targetHost is not "" then
			do shell script "open -a WinBox --args " & quoted form of targetHost
		else
			do shell script "open -a WinBox"
		end if
		
		delay 0.2
		tell application "WinBox" to activate
	on error
		do shell script "open -a WinBox"
		tell application "WinBox" to activate
	end try
	tell me to quit
end open location
EOF

echo "[*] 正在编译原生 WinBox URL 协议桥接应用..."
osacompile -o "$HANDLER_APP" "$TMP_SCRIPT"
rm -f "$TMP_SCRIPT"

echo "[*] 写入 winbox:// URL Scheme 协议与后台常驻属性..."
plutil -insert CFBundleURLTypes -xml '<array><dict><key>CFBundleURLName</key><string>WinBox URL Handler</string><key>CFBundleURLSchemes</key><array><string>winbox</string></array></dict></array>' "$HANDLER_APP/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$HANDLER_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.mikrotik.winbox.urlhandler" "$HANDLER_APP/Contents/Info.plist"

if [[ -f "$APP_PATH/Contents/Resources/winbox.icns" ]]; then
  cp "$APP_PATH/Contents/Resources/winbox.icns" "$HANDLER_APP/Contents/Resources/applet.icns"
  cp "$APP_PATH/Contents/Resources/winbox.icns" "$HANDLER_APP/Contents/Resources/winbox.icns"
  plutil -replace CFBundleIconFile -string "winbox.icns" "$HANDLER_APP/Contents/Info.plist"
fi

echo "[*] 进行轻量签名并向系统 LaunchServices 注册..."
codesign --force --deep --sign - "$HANDLER_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HANDLER_APP"

echo "[✓] 配置成功！现在在 Chrome、Safari 或 HomeNet Portal 门户中点击「唤起 Winbox」，即可直接秒启并连入指定 RouterOS！"
