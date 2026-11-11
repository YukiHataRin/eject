#!/bin/zsh
# 編譯 release 版、組成 Eject.app、ad-hoc 簽署，並安裝到 ~/Applications。
# 注意：不要從外接碟直接執行 App，否則 App 本身就會擋住那顆碟的退出。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Eject"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"

echo "▸ 編譯 release…"
swift build -c release --arch arm64 2>&1 | grep -vE "^\[|^Building|^Compiling" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "▸ 產生圖示…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$BUILD_DIR/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ 組裝 $APP_NAME.app…"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" != "--no-install" ]]; then
    echo "▸ 安裝到 $INSTALL_DIR…"
    mkdir -p "$INSTALL_DIR"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/"
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "✓ 已啟動，請看選單列右上角的磁碟圖示"
else
    echo "✓ 完成：$APP"
fi
