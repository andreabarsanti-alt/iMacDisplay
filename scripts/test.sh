#!/bin/bash
# Run the unit tests. With only the Command Line Tools installed (no Xcode),
# SwiftPM doesn't find Swift Testing by itself, so pass its paths explicitly.
# Cross-import overlays are disabled: the iMac CLT (Swift 6.2.4) ships
# _Testing_Foundation without its module files.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=$(xcode-select -p)
F="$DEV/Library/Developer/Frameworks"
L="$DEV/Library/Developer/usr/lib"
if [ -d "$F/Testing.framework" ]; then
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F -Xlinker "$F" \
    -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
