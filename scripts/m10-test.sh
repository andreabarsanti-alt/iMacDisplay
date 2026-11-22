#!/bin/bash
# M10: host menu bar app acceptance (runs the app binary from Terminal so it
# inherits Terminal's Screen Recording / Accessibility during development).
#  - state machine unit tests
#  - 20 start/stop cycles with the iMac connected: Stop < 1 s, nothing listening,
#    no capture left, back to Idle every time
#  - permission denied and cable unplugged end in a clear error state, nothing left
set -uo pipefail
export LC_ALL=C   # decimal points, not commas, in awk/printf
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs; FAILS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1
B=.build/debug/RemoteMirrorHostApp

scripts/test.sh --filter HostCoreTests > logs/m10-unit.log 2>&1 && pass "state machine unit tests" || fail "unit tests (logs/m10-unit.log)"

scripts/run-client.sh --allow-reconnect --duration 150 > logs/client-m10.log 2>&1 &
sleep 3
$B --self-test-cycles 20 --with-client > logs/m10-cycles.log 2>&1 && pass "20 cycles: $(grep cycles_summary logs/m10-cycles.log)" || { fail "cycles"; grep FAIL logs/m10-cycles.log | head -5; }
scripts/killall.sh >/dev/null

$B --self-test-error permission > logs/m10-perm.log 2>&1 && pass "permission denied -> $(grep -o '"state":"[^"]*"' logs/m10-perm.log)" || fail "permission path"
$B --self-test-error unplug --synthetic > logs/m10-unplug.log 2>&1 && pass "cable unplugged -> $(grep -o '"state":"Error: cable unplugged' logs/m10-unplug.log), $(grep -o '"detect_ms":[0-9]*' logs/m10-unplug.log)" || fail "unplug path"
pgrep -f RemoteMirrorHostApp >/dev/null && fail "app process left running" || pass "no app process left"

echo
[ $FAILS -eq 0 ] && { echo "M10: PASS"; exit 0; } || { echo "M10: FAIL ($FAILS)"; exit 1; }
