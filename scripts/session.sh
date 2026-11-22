#!/bin/bash
# Start a real mirroring session (until the M10/M11 apps exist): host on the
# MacBook, client app on the iMac. Ends when either side stops: Ctrl-Option-Cmd-Q
# on the iMac, Ctrl-C here, or scripts/killall.sh.
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
mkdir -p logs
swift build -q || exit 1
.build/debug/RemoteMirrorHost --serve "$@" > logs/session-host.log 2>&1 &
HPID=$!
trap 'kill $HPID 2>/dev/null' INT TERM
sleep 2
echo "Session running. On the iMac: Ctrl-Option-Cmd-Q to end."
scripts/run-client.sh > logs/session-client.log 2>&1
wait $HPID 2>/dev/null
echo "Session ended."; grep -E '"stopping"' logs/session-host.log
