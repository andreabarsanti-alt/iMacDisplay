#!/bin/bash
# Build the two install packages on the MacBook:
#   dist/RemoteMirror-MacBook.zip   (arm64 menu bar app + install/uninstall)
#   dist/RemoteMirror-iMac.zip      (x86_64 waiting app + install/uninstall)
# The target Macs need no developer tools: the installers sign locally with codesign.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(git describe --tags --always)
rm -rf dist; mkdir -p dist

plist() { # id name exe uielement
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  $( [ "$4" = 1 ] && echo '<key>LSUIElement</key><true/>' )
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Uses the direct Ethernet cable between the MacBook and the iMac.</string>
</dict></plist>
PLIST
}

pkg() { # role dir binary id uielement installer
  local role=$1 dir=dist/$2 bin=$3 id=$4 ui=$5 inst=$6
  mkdir -p "$dir/RemoteMirror.app/Contents/MacOS"
  cp "$bin" "$dir/RemoteMirror.app/Contents/MacOS/RemoteMirror"
  plist "$id" RemoteMirror RemoteMirror "$ui" > "$dir/RemoteMirror.app/Contents/Info.plist"
  codesign -f -s - "$dir/RemoteMirror.app" 2>/dev/null   # ad-hoc; re-signed locally at install
  cp packaging/common.sh packaging/uninstall.sh scripts/setup/link.sh scripts/setup/signing-cert.sh "$dir/"
  cp "packaging/$inst" "$dir/install.sh"
  echo "$role" > "$dir/ROLE"
  chmod +x "$dir"/*.sh
  cat > "$dir/README.txt" <<TXT
RemoteMirror $VERSION ($role)

Install:    open Terminal in this folder and run  ./install.sh
Uninstall:  ./uninstall.sh   (restores the original network settings)
Options:    ./install.sh --help-like header: see the first lines of install.sh

Order: install on the MacBook first; it creates RemoteMirror-pairing.key on the
Desktop. Copy that file to the iMac (AirDrop/USB) next to the iMac installer,
then install on the iMac. The file is deleted after import.
TXT
  (cd dist && ditto -c -k --keepParent "$2" "$2.zip")
  echo "built dist/$2.zip"
}

swift build -q -c release --arch arm64 --product RemoteMirrorHostApp
swift build -q -c release --arch x86_64 --product RemoteMirrorClient
ARM=$(swift build -c release --arch arm64 --show-bin-path)
X86=$(swift build -c release --arch x86_64 --show-bin-path)
pkg macbook RemoteMirror-MacBook "$ARM/RemoteMirrorHostApp" local.remotemirror.host 1 install-macbook.sh
pkg imac RemoteMirror-iMac "$X86/RemoteMirrorClient" local.remotemirror.client 0 install-imac.sh
file dist/RemoteMirror-MacBook/RemoteMirror.app/Contents/MacOS/RemoteMirror dist/RemoteMirror-iMac/RemoteMirror.app/Contents/MacOS/RemoteMirror | sed 's/.*RemoteMirror-\([A-Za-z]*\).*: /\1: /'
