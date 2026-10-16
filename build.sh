#!/bin/bash
# Builds a universal "Console Mode.app" (Apple silicon + Intel) into ./build
set -e
cd "$(dirname "$0")"
APP="build/Console Mode.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework GameController -framework CoreHaptics \
    -framework ServiceManagement -framework Combine \
    -o "build/ConsoleMode-$arch" ConsoleMode/*.swift
done
lipo -create build/ConsoleMode-arm64 build/ConsoleMode-x86_64 -output "$APP/Contents/MacOS/ConsoleMode"
rm build/ConsoleMode-*
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Console Mode</string>
  <key>CFBundleDisplayName</key><string>Console Mode</string>
  <key>CFBundleIdentifier</key><string>com.nate.consolemode</string>
  <key>CFBundleExecutable</key><string>ConsoleMode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.8</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Console Mode</string>
</dict>
</plist>
PLIST
# Stable signature (same certificate every build) so macOS keeps Accessibility permission across updates
codesign --force --sign "${SIGN_ID:--}" --identifier com.nate.consolemode "$APP"
codesign --verify --verbose "$APP"
codesign -d -r- "$APP"
(cd build && ditto -c -k --keepParent "Console Mode.app" "Console-Mode.zip")
echo "Built build/Console-Mode.zip"
