#!/bin/bash
# M7: shortcut capture and escape hatch (needs Accessibility + Local Network for
# RemoteMirror.app on the iMac).
#  1. Cmd-Tab and Cmd-Space typed on the iMac reach the host (view-only host logs them)
#  2. Ctrl-Option-Cmd-Q on the iMac ends the session cleanly within 2 s; host stops too
#  3. cursor overlay receives shape + positions
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs; FAILS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && swift build -q' || exit 1

echo "== 1. Shortcuts"
.build/debug/RemoteMirrorHost --serve --synthetic --view-only --log-input --duration 20 > logs/host-m7a.log 2>&1 &
sleep 2
scripts/run-client.sh --duration 6 --test-shortcuts > logs/client-m7a.log 2>&1
wait
grep -E '"shortcut_tap"|"shortcuts"|"cursor"' logs/client-m7a.log
CMD=1048576   # kCGEventFlagMaskCommand
grep -q '"shortcut_tap","running":true' logs/client-m7a.log && pass "event tap running" || fail "event tap not running (Accessibility for RemoteMirror on the iMac?)"
for k in 48:Cmd-Tab 49:Cmd-Space; do
  code=${k%%:*}; name=${k#*:}
  if grep -E "\"kind\":5,\"code\":$code,\"flags\":[0-9]+" logs/host-m7a.log | awk -F'"flags":' -v m=$CMD '{f=$2+0; if (int(f/m)%2==1) ok=1} END{exit !ok}'; then
    pass "$name reached the host"
  else fail "$name did not reach the host"; fi
done
grep -q '"shape":true' logs/client-m7a.log && pass "cursor shape received" || fail "no cursor shape"

echo "== 2. Escape hatch"
.build/debug/RemoteMirrorHost --serve --synthetic --duration 30 > logs/host-m7b.log 2>&1 &
HPID=$!; sleep 2
T0=$(date +%s)
scripts/run-client.sh --duration 20 --test-escape 3 > logs/client-m7b.log 2>&1
T1=$(date +%s)
wait $HPID
grep -E '"escape_hatch"|"exit"' logs/client-m7b.log
grep -q '"reason":"escape hatch"' logs/client-m7b.log && pass "client exited via escape hatch" || fail "client did not exit via escape hatch"
[ $((T1 - T0)) -le 12 ] && pass "session ended after $((T1 - T0)) s (escape at 3 s; includes app build/launch)" || fail "took $((T1 - T0)) s"
grep -q '"escape_hatch"' logs/host-m7b.log && pass "host saw escape_hatch bye" || fail "host did not log escape_hatch"
grep -q '"stopping"' logs/host-m7b.log && pass "host stopped" || fail "host did not stop"
pgrep -f "RemoteMirrorHost --serve" >/dev/null && fail "host still running" || pass "no host process left"
ssh "$IMAC" 'pgrep -f RemoteMirrorClient' >/dev/null && fail "client still running" || pass "no client process left"

echo
[ $FAILS -eq 0 ] && { echo "M7: PASS"; exit 0; } || { echo "M7: FAIL ($FAILS)"; exit 1; }
