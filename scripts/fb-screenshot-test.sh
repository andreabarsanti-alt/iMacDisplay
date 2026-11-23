#!/bin/bash
# Feedback item 5: reshaping/moving the screenshot selection from the iMac.
# Opens the Cmd-Shift-5 screenshot toolbar on the MacBook, drags inside its selection
# from the iMac through the normal mouse path, and checks the selection moved
# (before/after screen pictures differ). Needs the injected mouse deltas.
# Control: RM_NO_MOUSE_DELTAS=1 scripts/fb-screenshot-test.sh must FAIL (similarity 1.0000).
# Safety: injects only the Cmd-Shift-5 shortcut (no Esc: an Esc reaching the
# Terminal would interrupt the agent) and force-ends the screenshot helper afterwards.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs
T=$(mktemp -d /tmp/rm-shot.XXXXXX)
# macOS remembers the last selection (com.apple.screencapture last-selection); start
# from a known one in the middle of the screen and put the user's value back afterwards.
OLDSEL=$(defaults export com.apple.screencapture - 2>/dev/null | plutil -extract last-selection json -o - - 2>/dev/null)
restore_sel() {
  if [ -n "$OLDSEL" ]; then
    defaults write com.apple.screencapture last-selection -dict \
      X "$(plutil -extract X raw -o - - <<<"$OLDSEL")" Y "$(plutil -extract Y raw -o - - <<<"$OLDSEL")" \
      Width "$(plutil -extract Width raw -o - - <<<"$OLDSEL")" Height "$(plutil -extract Height raw -o - - <<<"$OLDSEL")"
  else defaults delete com.apple.screencapture last-selection 2>/dev/null; fi
}
cleanup() { pkill -9 -f /usr/sbin/screencapture 2>/dev/null; killall screencaptureui 2>/dev/null; restore_sel; rm -rf "$T"; }
trap cleanup EXIT
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1
cat > "$T/k.swift" <<'SW'
import CoreGraphics
import Foundation
let s = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: s, virtualKey: 23, keyDown: down); e?.flags = [.maskCommand, .maskShift]; e?.post(tap: .cghidEventTap)
    usleep(30_000)
}
SW
swiftc -o "$T/k" "$T/k.swift" || exit 1
cleanup_shot() { pkill -9 -f /usr/sbin/screencapture 2>/dev/null; killall screencaptureui 2>/dev/null; }
cleanup_shot
defaults write com.apple.screencapture last-selection -dict X 500 Y 300 Width 400 Height 300
sleep 1
"$T/k"; sleep 1.5
screencapture -x "$T/before.png"
# Known selection 500,300 400x300 points -> centre (700,450) on the 1512x982 screen.
B=$(swift -e 'import CoreGraphics; let b = CGDisplayBounds(CGMainDisplayID()); print(Int(b.width), Int(b.height))' 2>/dev/null)
read -r SWP SHP <<<"${B:-1512 982}"
CX=$(awk "BEGIN{print 700/$SWP}"); CY=$(awk "BEGIN{print 450/$SHP}")
DX=-0.10; DY=-0.06
echo "dragging from the selection centre $CX,$CY by $DX,$DY"
TX=$(awk "BEGIN{print $CX + $DX}"); TY=$(awk "BEGIN{print $CY + $DY}")
.build/debug/RemoteMirrorHost --serve --duration 25 > logs/host-fbshot.log 2>&1 & HP=$!
sleep 2
scripts/run-client.sh --duration 8 --test-drag "$CX,$CY,$TX,$TY" > logs/client-fbshot.log 2>&1
screencapture -x "$T/after.png"
cleanup_shot; wait $HP 2>/dev/null
grep -q test_drag_sent logs/client-fbshot.log || { echo "FAIL  drag not sent"; exit 1; }
SIM=$(.build/debug/RemoteMirrorHost --compare "$T/before.png" "$T/after.png" | sed -nE 's/.*:([0-9.]+).*/\1/p')
echo "before/after similarity: $SIM (identical = 1.0000 means nothing moved)"
awk "BEGIN{exit !($SIM < 0.998)}" \
  && { echo "PASS  the iMac drag moved the screenshot selection"; exit 0; } \
  || { echo "FAIL  selection did not move"; exit 1; }
