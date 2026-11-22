#!/bin/bash
# M5: keyboard forwarding. The host shows a focused text field; the client types
# a scripted sequence (hardware keycodes, incl. Shift); the field must match exactly.
# Also checks the dead man's switch is armed and keys are released on stop.
set -uo pipefail
export LC_ALL=C   # decimal points, not commas, in awk/printf
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
TEXT="${TEXT:-Hello World 2026 ciao Mondo}"
mkdir -p logs
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && swift build -q' || exit 1
.build/debug/RemoteMirrorHost --serve --synthetic --input-test --expect-text "$TEXT" --dead-man 30 --duration 25 > logs/host-m5.log 2>&1 &
HPID=$!
sleep 2
scripts/run-client.sh --duration 8 --type-text "$TEXT" > logs/client-m5.log 2>&1
wait $HPID; CODE=$?
grep -E '"typed"|"exit"' logs/client-m5.log
grep -E '"input"|"input_test"|"warning"|^PASS|^FAIL' logs/host-m5.log
exit $CODE
