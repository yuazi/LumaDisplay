#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
APP_PATH="$PWD/dist/LumaDisplay.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/LumaDisplay" "$APP_PATH/Contents/MacOS/LumaDisplay"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/"
swift Scripts/make-icon.swift "$PWD/dist"
iconutil -c icns dist/AppIcon.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print "Built $APP_PATH"
