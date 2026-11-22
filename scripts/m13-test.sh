#!/bin/bash
# M13 (part that runs without the HDMI dummy plug): live capture switching.
#  1. unit tests for display choice and the 16:9 mode picker
#  2. mid-session capture switch (3024x1964 -> 1512x982, same path as lid close /
#     display change): session continues, iMac sees the new size, fps holds
#  3. after a switch, clicks still land exactly (input follows the shared display)
# Still to do with the plug: lid closed for 30 min, dummy at 2560x1440 HiDPI.
set -uo pipefail
export LC_ALL=C   # decimal points, not commas, in awk/printf
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs; FAILS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
H=.build/debug/RemoteMirrorHost
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1

scripts/test.sh --filter "DisplayPolicyTests|IMacModeTests" > logs/m13-unit.log 2>&1 && pass "1. display policy + 16:9 mode unit tests" || fail "1. unit tests"

$H --serve --pattern --test-resize-after 6 --duration 20 > logs/host-m13a.log 2>&1 &
HP=$!; sleep 2
scripts/run-client.sh --duration 14 --stats > logs/client-m13a.log 2>&1
wait $HP
grep -E '"display_switched"|"capturing"' logs/host-m13a.log
grep -E '"video_size"' logs/client-m13a.log
grep -q '"display_switched"' logs/host-m13a.log && pass "2. capture switched mid-session ($(grep -o '"ms":[0-9]*' logs/host-m13a.log | tail -1))" || fail "2. no switch"
grep -q '"video_size","width":1512,"height":982' logs/client-m13a.log && pass "2. iMac got the new size 1512x982" || fail "2. iMac did not see the new size"
grep -q '"reason":"duration elapsed"' logs/client-m13a.log && pass "2. session continued to the end" || fail "2. session ended early"
# fps over the last 5 s (after the switch)
AFTER=$(grep '"event":"stats"' logs/client-m13a.log | tail -6 | head -5 | sed -nE 's/.*"display_fps":([0-9.]+).*/\1/p' | awk '{s+=$1} END{if (NR) printf "%.1f", s/NR}')
awk "BEGIN{exit !(${AFTER:-0} >= 25)}" && pass "2. ${AFTER} fps after the switch" || fail "2. only ${AFTER:-0} fps after the switch"

rm -f logs/mouse.spec
$H --serve --mouse-test --mouse-spec-out logs/mouse.spec --test-resize-after 0.5 --dead-man 30 --duration 25 > logs/host-m13b.log 2>&1 &
HP=$!
for _ in $(seq 20); do [ -s logs/mouse.spec ] && break; sleep 0.5; done
sleep 1
scripts/run-client.sh --duration 9 --mouse-script "$(cat logs/mouse.spec)" > logs/client-m13b.log 2>&1
wait $HP
grep -q '"display_switched"' logs/host-m13b.log && grep -q '^PASS' logs/host-m13b.log \
  && pass "3. clicks exact after a switch ($(grep -o '"max_error_pt":[0-9.]*' logs/host-m13b.log))" || { fail "3. mouse after switch"; grep -E 'FAIL|mouse_test' logs/host-m13b.log; }

echo
[ $FAILS -eq 0 ] && { echo "M13 (no plug): PASS"; exit 0; } || { echo "M13 (no plug): FAIL ($FAILS)"; exit 1; }
