#!/bin/bash
# M11: iMac waiting app. Starts the client app in waiting mode (no test flags), then:
#  1. idle window shown, nothing mirrored
#  2. host starts sharing -> client goes full screen within 3 s, no action on the iMac
#  3. host stops -> client returns to idle, keeps running
#  4. second session works the same
#  5. host killed abruptly -> client notices (heartbeat) and returns to idle
#  6. escape hatch on the iMac ends the session: client idle, host stopped
#  7. quit from the client ends the app
set -uo pipefail
export LC_ALL=C   # decimal points, not commas, in awk/printf
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs; FAILS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
H=.build/debug/RemoteMirrorHost
CLOG=/tmp/rm-m11.log
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main' || exit 1
clog() { ssh "$IMAC" "cat $CLOG"; }
# wait_for <grep pattern> <count> <timeout s>: wait until the client log has >= count matches
wait_for() { local end=$(( $(date +%s) + $3 )); while [ "$(date +%s)" -le $end ]; do
  [ "$(clog | grep -c "$1")" -ge "$2" ] && return 0; sleep 0.25; done; return 1; }
running() { ssh "$IMAC" 'pgrep -f RemoteMirrorClient.app/Contents/MacOS' >/dev/null; }

ssh "$IMAC" 'pkill -f RemoteMirrorClient.app/Contents/MacOS'; sleep 1
BG=1 CLIENT_LOG=$CLOG scripts/run-client.sh
wait_for '"event":"idle","idle_window":true,"mirror_visible":false' 1 15 && pass "1. idle window shown, no mirror" || fail "1. not idle"

T0=$(python3 -c 'import time;print(time.time())')
$H --serve --synthetic --view-only --duration 8 > logs/host-m11a.log 2>&1 & HP=$!
if wait_for '"session_started","n":1,"mirror_visible":true' 1 10; then
  T1=$(python3 -c 'import time;print(time.time())')
  S=$(python3 -c "print(round($T1-$T0,1))")
  awk "BEGIN{exit !($S <= 3.0)}" && pass "2. full screen ${S} s after the host started" || fail "2. took ${S} s"
else fail "2. session 1 did not start"; fi
wait $HP
wait_for '"session_ended"' 1 8 && wait_for '"event":"idle","idle_window":true,"mirror_visible":false' 2 8 \
  && pass "3. back to idle after host stop ($(clog | grep -o '"session_ended","reason":"[^"]*"' | tail -1))" || fail "3. did not return to idle"
running && pass "3. client still running" || fail "3. client exited"

$H --serve --synthetic --view-only --duration 6 > logs/host-m11b.log 2>&1 & HP=$!
wait_for '"session_started","n":2' 1 10 && pass "4. second session started" || fail "4. no second session"
wait $HP
wait_for '"event":"idle","idle_window":true' 3 10 && pass "4. idle again" || fail "4. not idle after session 2"

$H --serve --synthetic --view-only --duration 60 > logs/host-m11c.log 2>&1 & HP=$!
wait_for '"session_started","n":3' 1 10 || fail "5. session 3 did not start"
sleep 2; kill -9 $HP; wait $HP 2>/dev/null; T0=$(date +%s)
wait_for '"event":"idle","idle_window":true' 4 10 && pass "5. host killed -> idle after $(( $(date +%s) - T0 )) s ($(clog | grep -o '"session_ended","reason":"[^"]*"' | tail -1))" || fail "5. not idle after host kill"

ssh "$IMAC" 'pkill -TERM -f RemoteMirrorClient.app/Contents/MacOS'; sleep 2
running && fail "7. client still running after quit" || pass "7. quit ends the app"

# 6. escape hatch: a waiting client that posts Ctrl-Option-Cmd-Q 3 s into each session
BG=1 CLIENT_LOG=$CLOG scripts/run-client.sh --test-escape 3
wait_for '"event":"idle"' 1 15 || fail "6. client not idle"
$H --serve --synthetic --duration 60 > logs/host-m11d.log 2>&1 & HP=$!
wait_for '"session_started","n":1' 1 10 || fail "6. session did not start"
wait_for '"session_ended","reason":"escape hatch"' 1 10 && pass "6. escape hatch ended the session" || fail "6. no escape"
wait_for '"event":"idle","idle_window":true' 2 8 && pass "6. client back to idle" || fail "6. client not idle after escape"
sleep 1; kill -0 $HP 2>/dev/null && { fail "6. host still running after escape"; kill $HP; } || pass "6. host stopped on escape"
ssh "$IMAC" 'pkill -TERM -f RemoteMirrorClient.app/Contents/MacOS'

echo
[ $FAILS -eq 0 ] && { echo "M11: PASS"; exit 0; } || { echo "M11: FAIL ($FAILS)"; exit 1; }
