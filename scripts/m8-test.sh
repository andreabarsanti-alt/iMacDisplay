#!/bin/bash
# M8: reconnect behaviour.
#  A. --allow-reconnect, client killed and restarted: host keeps waiting; new client
#     gets a keyframe as its first frame.
#  B. --allow-reconnect, host killed and restarted 1 s later: client reconnects within
#     3 s of the host being back, first frame is a keyframe.
#  C. without the flag (Mutual kill): killing the host makes the client quit.
#  D. with the flag, the escape hatch still stops the host.
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
kill_client() { ssh "$IMAC" 'pkill -9 -f RemoteMirrorClient.app/Contents/MacOS'; }

echo "== A. Client killed and restarted (host --allow-reconnect)"
$H --serve --synthetic --view-only --allow-reconnect --duration 40 > logs/host-m8a.log 2>&1 & HPID=$!
sleep 2
scripts/run-client.sh --duration 30 > logs/client-m8a1.log 2>&1 & C1=$!
sleep 8; kill_client; wait $C1 2>/dev/null; sleep 1
kill -0 $HPID 2>/dev/null && pass "host still running after client was killed" || fail "host exited"
grep -q waiting_for_client logs/host-m8a.log && pass "host waiting for client" || fail "host did not enter waiting"
scripts/run-client.sh --duration 5 > logs/client-m8a2.log 2>&1
grep -E '"first_frame"' logs/client-m8a2.log
grep -q '"first_frame","keyframe":true' logs/client-m8a2.log && pass "restarted client's first frame is a keyframe" || fail "first frame not a keyframe"
[ "$(grep -c '"client_ready","peer":"10.77.0.2","port":5001' logs/host-m8a.log)" -ge 2 ] && pass "host served the restarted client" || fail "no second client_ready"
kill $HPID 2>/dev/null; wait $HPID 2>/dev/null

echo "== B. Host killed and restarted (client --allow-reconnect)"
$H --serve --synthetic --view-only --duration 60 > logs/host-m8b1.log 2>&1 & H1=$!
sleep 2
scripts/run-client.sh --allow-reconnect --duration 20 > logs/client-m8b.log 2>&1 & C=$!
sleep 6; kill -9 $H1; wait $H1 2>/dev/null; sleep 1
$H --serve --synthetic --view-only --duration 30 > logs/host-m8b2.log 2>&1 & H2=$!
wait $C
grep -E '"reconnecting"|"connected"|"first_frame"' logs/client-m8b.log | head -8
MS=$(grep '"port":5001' logs/client-m8b.log | sed -nE 's/.*"reconnect_ms":([0-9]+).*/\1/p' | tail -1)
# reconnect_ms counts from the drop; the host was down ~1 s (plus heartbeat detection up to 2 s).
[ -n "$MS" ] && [ "$MS" -le 6000 ] && pass "client reconnected ${MS} ms after the drop (host down ~1 s)" || fail "reconnect took ${MS:-?} ms"
[ "$(grep -c '"first_frame","keyframe":true' logs/client-m8b.log)" -ge 2 ] && pass "keyframe first after reconnect" || fail "no keyframe after reconnect"
grep -q '"reason":"duration elapsed"' logs/client-m8b.log && pass "client session continued to the end" || fail "client ended early"
kill $H2 2>/dev/null; wait $H2 2>/dev/null

echo "== C. No reconnect flag: host killed -> client quits"
$H --serve --synthetic --view-only --duration 60 > logs/host-m8c.log 2>&1 & H1=$!
sleep 2
scripts/run-client.sh --duration 30 > logs/client-m8c.log 2>&1 & C=$!
sleep 6; kill -9 $H1; T0=$(date +%s); wait $C; T1=$(date +%s)
grep -E '"exit"' logs/client-m8c.log
[ $((T1 - T0)) -le 12 ] && pass "client quit $((T1 - T0)) s after the host died (heartbeat 2 s + retry window)" || fail "client took $((T1 - T0)) s"

echo "== D. Escape hatch still stops a --allow-reconnect host"
$H --serve --synthetic --allow-reconnect --duration 40 > logs/host-m8d.log 2>&1 & H1=$!
sleep 2
scripts/run-client.sh --allow-reconnect --duration 20 --test-escape 3 > logs/client-m8d.log 2>&1
sleep 1
kill -0 $H1 2>/dev/null && { fail "host kept running after escape hatch"; kill $H1; } || pass "host stopped on escape hatch"
grep -q '"reason":"escape hatch"' logs/client-m8d.log && pass "client exited via escape hatch (no reconnect)" || fail "client did not exit via escape"
wait 2>/dev/null

echo
[ $FAILS -eq 0 ] && { echo "M8: PASS"; exit 0; } || { echo "M8: FAIL ($FAILS)"; exit 1; }
