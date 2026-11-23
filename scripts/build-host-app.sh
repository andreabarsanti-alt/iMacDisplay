#!/bin/bash
# Build RemoteMirror.app (menu bar app) on the MacBook and sign it with the local
# "RemoteMirror Dev" identity (scripts/setup/signing-cert.sh), so the Screen
# Recording / Accessibility grants survive rebuilds. Output: .build/RemoteMirror.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -q -c release --arch arm64 --product RemoteMirrorHostApp
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=.build/RemoteMirror.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/RemoteMirrorHostApp" "$APP/Contents/MacOS/RemoteMirror"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.remotemirror.host</string>
  <key>CFBundleName</key><string>RemoteMirror</string>
  <key>CFBundleExecutable</key><string>RemoteMirror</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.10</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSLocalNetworkUsageDescription</key><string>Shares this screen with the iMac over the direct Ethernet cable.</string>
</dict></plist>
PLIST
scripts/setup/signing-cert.sh unlock
codesign -f -s "RemoteMirror Dev" --keychain "$HOME/Library/Keychains/remotemirror.keychain-db" --identifier local.remotemirror.host "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign -d -r- "$APP" 2>&1 | tail -1
