#!/bin/bash
# Magic Mouse swipes, end to end: the iMac app posts two phased swipes (right, left) over
# the mirror; the MacBook's swipe test window reports which scroll phases and momentum
# phases arrived and the total horizontal movement.
# Control: RM_NO_SCROLL_PHASES=1 scripts/fb-swipe-test.sh must FAIL (no phases arrive).
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1
rm -f logs/swipe.spec
.build/debug/RemoteMirrorHost --serve --swipe-test --swipe-spec-out logs/swipe.spec --dump-scroll --duration 16 > logs/host-swipe.log 2>&1 & HP=$!
for _ in $(seq 20); do [ -s logs/swipe.spec ] && break; sleep 0.5; done
scripts/run-client.sh --duration 8 --test-swipe > logs/client-swipe.log 2>&1
wait $HP
S=$(grep '"swipe_test"' logs/host-swipe.log)
echo "$S" | cut -c1-200
grep -q test_swipe_posted logs/client-swipe.log || { echo "FAIL  swipes not posted on the iMac"; exit 1; }
FAILS=0
for p in 1 4 8; do grep -qE "\"phases\":\[[^]]*\b$p\b" <<<"$S" || { echo "FAIL  scroll phase $p (NSEvent) missing"; FAILS=$((FAILS+1)); }; done
for m in 1 4 8; do grep -qE "\"momentum\":\[[^]]*\b$m\b" <<<"$S" || { echo "FAIL  momentum phase $m (NSEvent) missing"; FAILS=$((FAILS+1)); }; done
# Sub-pixel deltas: injected straight on the MacBook (synthetic iMac events can't carry
# fractions into AppKit there). 12 events of 0.4 px (= 4.8 px) must add up to ~4-5 px,
# not 0 (AppKit reads whole pixels, so the injector carries the fractions forward).
rm -f logs/swipe.spec
.build/debug/RemoteMirrorHost --serve --synthetic --swipe-test --swipe-spec-out logs/swipe.spec --self-scroll 0.4 \
  --dump-scroll --duration 5 > logs/host-subpixel.log 2>&1
TDX=$(grep '"swipe_test"' logs/host-subpixel.log | sed -nE 's/.*"total_dx":(-?[0-9.]+).*/\1/p')
awk "BEGIN{exit !(${TDX:-0} >= 4 && ${TDX:-0} <= 5)}" && echo "PASS  sub-pixel deltas preserved: 12 x 0.4 px arrived as ${TDX} px" \
  || { echo "FAIL  sub-pixel delta lost"; grep '"event":"scroll"' logs/host-subpixel.log | head -3; FAILS=$((FAILS+1)); }
[ $FAILS -eq 0 ] && { echo "PASS  phases began/changed/ended and momentum begin/continue/end reach the MacBook"; exit 0; } || exit 1
