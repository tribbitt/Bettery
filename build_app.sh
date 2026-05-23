#!/usr/bin/env bash
set -euo pipefail

APP="Bettery.app"
BINARY="Bettery"
BUNDLE_ID="com.bettery.bettery"

# Pass --universal to build a fat arm64+x86_64 binary (~11 MB vs ~6 MB).
UNIVERSAL=false
for arg in "$@"; do [[ "$arg" == "--universal" ]] && UNIVERSAL=true; done

if $UNIVERSAL; then
    swift build -c release --arch arm64 --arch x86_64
    BUILD_DIR=".build/apple/Products/Release"
else
    swift build -c release
    BUILD_DIR=".build/$(uname -m)-apple-macosx/release"
fi

# Assemble bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/$BINARY" "$APP/Contents/MacOS/$BINARY"

# SwiftPM resource bundle (Package name _ Target name)
RESOURCE_BUNDLE="${BINARY}_${BINARY}.bundle"
if [ -d "$BUILD_DIR/$RESOURCE_BUNDLE" ]; then
    cp -r "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP/Contents/Resources/$RESOURCE_BUNDLE"
fi

# App icon
ICONSET_DIR="/tmp/Bettery.iconset"
swift icons/make_icns.swift icons/betterywhiteicon.png "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${BINARY}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${BINARY}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
</dict>
</plist>
PLIST

# Re-sign with the correct bundle identifier so the code signature matches
# Info.plist — macOS uses the signature identifier (not Info.plist) to
# register apps with UNUserNotificationCenter and other system services.
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

echo "Built $APP"
