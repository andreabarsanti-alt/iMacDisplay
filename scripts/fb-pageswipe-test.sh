#!/bin/bash
# Magic Mouse page swipe, end to end and native: the iMac app replays a recorded real
# swipe right (scroll events + their companion gesture events) over the mirror; the iMac
# forwards both; the MacBook re-posts them onto a WebKit view with history A -> B, which
# must go back to A (Safari's own swipe recognition).
# Control: RM_NO_GESTURES=1 (MacBook drops the companions) must NOT go back.
# Needs a recording: logs/rec-client.log from --record-gestures (copied to the iMac).
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
[ -s logs/rec-client.log ] || { echo "no recording (logs/rec-client.log)"; exit 2; }
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1
scp -q logs/rec-client.log "$IMAC:/tmp/rm-rec-gestures.log"
rm -f logs/swipe.spec
.build/debug/RemoteMirrorHost --serve --swipe-test --swipe-web --swipe-spec-out logs/swipe.spec --duration 18 > logs/host-pageswipe.log 2>&1 & HP=$!
for _ in $(seq 20); do [ -s logs/swipe.spec ] && break; sleep 0.5; done
sleep 1
scripts/run-client.sh --duration 9 --assume-active --test-swipe-replay /tmp/rm-rec-gestures.log:3 > logs/client-pageswipe.log 2>&1
wait $HP
grep -E "swipe_replayed" logs/client-pageswipe.log
R=$(grep '"swipe_test"' logs/host-pageswipe.log | grep -oE '"web_can_go_back":[a-z]+')
echo "$R (false = went back to page A)"
[ "$R" = '"web_can_go_back":false' ] && { echo "PASS  the swipe went back natively on the MacBook"; exit 0; } || { echo "FAIL  no back navigation"; exit 1; }
