#!/bin/bash
# M6: mouse and scroll. Host shows 5 targets at known positions; the client clicks
# each (left), right-clicks target 0, double-clicks target 1 and scrolls on target 2,
# going through the same view <-> video coordinate mapping as real mouse input.
# Every click must land within 2 pt of its target centre.
set -uo pipefail
export LC_ALL=C   # decimal points, not commas, in awk/printf
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
mkdir -p logs
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && swift build -q' || exit 1
rm -f logs/mouse.spec
.build/debug/RemoteMirrorHost --serve ${SYNTHETIC:+--synthetic} --mouse-test --mouse-spec-out logs/mouse.spec --dead-man 30 --duration 25 > logs/host-m6.log 2>&1 &
HPID=$!
for _ in $(seq 20); do [ -s logs/mouse.spec ] && break; sleep 0.5; done
[ -s logs/mouse.spec ] || { echo "no target spec"; kill $HPID; exit 1; }
scripts/run-client.sh --duration 8 --mouse-script "$(cat logs/mouse.spec)" > logs/client-m6.log 2>&1
wait $HPID; CODE=$?
grep -E '"mouse_script"|"exit"' logs/client-m6.log
grep -E '"input"|"mouse_test"|^PASS|^FAIL' logs/host-m6.log
exit $CODE
