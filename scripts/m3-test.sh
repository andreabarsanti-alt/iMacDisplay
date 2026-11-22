#!/bin/bash
# M3 acceptance test, run from the MacBook:
#  1. real screen streamed for 30 s, client displays >= 25 fps
#  2. client's last displayed frame matches a host screenshot (similarity >= 0.90)
#  3. a client with the wrong key is rejected
#  4. a connection from another address (the MacBook itself) is rejected
#  5. a plain TCP (non-TLS) connection is rejected
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
DUR="${DUR:-30}"
mkdir -p logs
FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
H=.build/debug/RemoteMirrorHost

start_host() { "$H" --serve "$@" > logs/host.log 2>&1 & echo $! > logs/host.pid; sleep 2; }
stop_host() { kill "$(cat logs/host.pid)" 2>/dev/null; sleep 1; }

swift build -q || { echo "build failed"; exit 1; }
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && swift build -q' || { echo "iMac build failed"; exit 1; }

echo "== 1+2. Real screen, ${DUR} s"
start_host --pattern --stats
scripts/run-client.sh --duration "$DUR" --stats --min-fps 25 --dump-frame /tmp/rm-m3.png > logs/client.log 2>&1 &
CPID=$!
sleep $((DUR - 1)); screencapture -x -m /tmp/rm-host.png
wait $CPID; CODE=$?
grep -E '"summary"|"exit"' logs/client.log
[ $CODE -eq 0 ] && grep -q '^PASS' logs/client.log && pass "display fps >= 25 for ${DUR} s" || fail "display fps (see logs/client.log)"
scp -q "$IMAC:/tmp/rm-m3.png" logs/client-frame.png && cp /tmp/rm-host.png logs/host-frame.png
SIM=$("$H" --compare logs/client-frame.png logs/host-frame.png | sed -nE 's/.*:([0-9.]+).*/\1/p')
awk "BEGIN{exit !(${SIM:-0} >= 0.90)}" && pass "frame similarity $SIM" || fail "frame similarity ${SIM:-?} < 0.90"
sleep 1; pgrep -f "RemoteMirrorHost --serve" >/dev/null && { fail "host still running after client left"; stop_host; } || pass "host stopped when client left (mutual kill)"

echo "== 3. Wrong key"
start_host --synthetic
ssh "$IMAC" 'umask 077; openssl rand -hex 32 > /tmp/rm-wrong.key'
scripts/run-client.sh --duration 5 --key /tmp/rm-wrong.key > logs/client-wrongkey.log 2>&1
ssh "$IMAC" 'rm -f /tmp/rm-wrong.key'
grep -q '"connected"' logs/client-wrongkey.log && fail "client with wrong key connected" || pass "wrong key: no connection"
grep -q '"rejected"' logs/host.log && pass "host logged rejection" || fail "host did not log a rejection"

echo "== 4. Wrong source address"
.build/debug/RemoteMirrorClient --duration 4 > logs/client-local.log 2>&1
grep -q '"connected"' logs/client-local.log && fail "connection from 10.77.0.1 accepted" || pass "connection from 10.77.0.1 rejected"
grep -q 'peer 10.77.0.1 is not 10.77.0.2' logs/host.log && pass "host rejected by peer pinning" || fail "no peer-pinning rejection logged"

echo "== 5. Plain TCP"
ssh "$IMAC" 'printf "GET / HTTP/1.0\r\n\r\n" | nc -w 3 10.77.0.1 5001 | head -c 100 | xxd | head -2' > logs/plain.log 2>&1
grep -c . logs/plain.log >/dev/null; pgrep -f "RemoteMirrorHost --serve" >/dev/null && pass "host survived plain TCP" || fail "host died on plain TCP"
grep -q '"client_ready"' logs/host.log && fail "a test client reached client_ready" || pass "no unauthenticated client got through"
stop_host

echo
[ $FAILS -eq 0 ] && { echo "M3: PASS"; exit 0; } || { echo "M3: FAIL ($FAILS)"; exit 1; }
