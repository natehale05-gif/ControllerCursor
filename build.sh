#!/bin/bash
# Builds a universal "Controller Cursor.app" (Apple silicon + Intel) into ./build
set -e
cd "$(dirname "$0")"
APP="build/Controller Cursor.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework GameController -framework ServiceManagement \
    -o "build/ControllerCursor-$arch" ControllerCursor.swift
done
lipo -create build/ControllerCursor-arm64 build/ControllerCursor-x86_64 -output "$APP/Contents/MacOS/ControllerCursor"
rm build/ControllerCursor-*
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Controller Cursor</string>
  <key>CFBundleDisplayName</key><string>Controller Cursor</string>
  <key>CFBundleIdentifier</key><string>com.nate.controllercursor</string>
  <key>CFBundleExecutable</key><string>ControllerCursor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"
(cd build && ditto -c -k --keepParent "Controller Cursor.app" "Controller-Cursor.zip")
echo "Built build/Controller-Cursor.zip"
