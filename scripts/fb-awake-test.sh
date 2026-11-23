#!/bin/bash
# Feedback items 2+3: keep-awake while sharing, and the session log.
#  1. during a session: MacBook holds PreventUserIdleSystemSleep + PreventUserIdleDisplaySleep
#     ("RemoteMirror: sharing ..."), iMac holds them too ("RemoteMirror: showing ...")
#  2. after the session: both released
#  3. iMac waiting app writes timestamped session lines to ~/Library/Logs/RemoteMirror/iMac.log
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs; FAILS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
H=.build/debug/RemoteMirrorHost
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && scripts/build-client-app.sh >/dev/null' || exit 1
ssh "$IMAC" 'pkill -TERM -f "Applications/RemoteMirror.app/Contents/MacOS"; pkill -TERM -f RemoteMirrorClient.app/Contents/MacOS'; sleep 1

$H --serve --synthetic --view-only --duration 20 > logs/host-fb.log 2>&1 & HP=$!
sleep 2
scripts/run-client.sh --duration 12 > logs/client-fb.log 2>&1 & CP=$!
sleep 7
L=$(pmset -g assertions); R=$(ssh "$IMAC" 'pmset -g assertions')
grep -q 'PreventUserIdleSystemSleep.*RemoteMirror: sharing' <<<"$L" && pass "1. MacBook: no idle sleep while sharing" || fail "1. MacBook system-sleep assertion missing"
grep -q 'PreventUserIdleDisplaySleep.*RemoteMirror: sharing' <<<"$L" && pass "1. MacBook: no display sleep / auto-lock while sharing" || fail "1. MacBook display assertion missing"
grep -q 'PreventUserIdleDisplaySleep.*RemoteMirror: showing' <<<"$R" && pass "1. iMac: display stays on while mirroring" || fail "1. iMac display assertion missing"
wait $CP; wait $HP; sleep 1
L=$(pmset -g assertions); R=$(ssh "$IMAC" 'pmset -g assertions')
grep -q 'RemoteMirror: sharing' <<<"$L" && fail "2. MacBook still holds an assertion after stop" || pass "2. MacBook released after stop"
grep -q 'RemoteMirror: showing' <<<"$R" && fail "2. iMac still holds an assertion after the session" || pass "2. iMac released after the session"

ssh "$IMAC" 'rm -f ~/Library/Logs/RemoteMirror/iMac.log'
BG=1 CLIENT_LOG=/tmp/rm-fb.log scripts/run-client.sh; sleep 4
$H --serve --synthetic --view-only --duration 6 > logs/host-fb2.log 2>&1; sleep 3
LOG=$(ssh "$IMAC" 'cat ~/Library/Logs/RemoteMirror/iMac.log 2>/dev/null')
grep -E 'session_(started|ended)' <<<"$LOG" | cut -c1-140
grep -qE '^20[0-9-]+T[0-9:.]+.* .*"session_started"' <<<"$LOG" && grep -q '"session_ended"' <<<"$LOG" \
  && pass "3. iMac log has timestamped session start/end" || fail "3. iMac log missing session lines"
ssh "$IMAC" 'pkill -TERM -f RemoteMirrorClient.app/Contents/MacOS'; sleep 1
grep -q 'RemoteMirror: showing' <<<"$(ssh "$IMAC" 'pmset -g assertions')" && fail "3. iMac assertion left after quit" || pass "3. nothing held after quit"

echo
[ $FAILS -eq 0 ] && { echo "keep-awake: PASS"; exit 0; } || { echo "keep-awake: FAIL ($FAILS)"; exit 1; }
