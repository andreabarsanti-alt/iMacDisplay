#!/bin/bash
# Build RemoteMirrorClient.app on the iMac and sign it with the local
# "RemoteMirror Dev" identity (see scripts/setup/signing-cert.sh), so macOS
# permissions granted to the app survive rebuilds. Output: .build/RemoteMirrorClient.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -q --product RemoteMirrorClient
APP=.build/RemoteMirrorClient.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/debug/RemoteMirrorClient "$APP/Contents/MacOS/RemoteMirrorClient"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.remotemirror.client</string>
  <key>CFBundleName</key><string>RemoteMirror</string>
  <key>CFBundleExecutable</key><string>RemoteMirrorClient</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSLocalNetworkUsageDescription</key><string>Connects to the MacBook over the direct Ethernet cable.</string>
</dict></plist>
PLIST
SIGN="$HOME/imacdisplay-setup/signing-cert.sh"
[ -x "$SIGN" ] || SIGN="scripts/setup/signing-cert.sh"
"$SIGN" unlock
codesign -f -s "RemoteMirror Dev" --keychain "$HOME/Library/Keychains/remotemirror.keychain-db" --identifier local.remotemirror.client "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign -d -r- "$APP" 2>&1 | tail -1
