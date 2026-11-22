#!/bin/bash
# M4: latency harness. The host shows a marker strip encoding a counter (60 Hz);
# the client reads it from each decoded frame and echoes it back; the host
# computes draw -> capture -> encode -> network -> decode -> display-enqueue
# latency per sample and reports median / p95.
# Not included: the iMac panel's own scan-out (up to ~1 refresh, 16.7 ms).
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
IMAC="${IMAC_USER:-andrea}@${IMAC_IP:-10.77.0.2}"
DUR="${DUR:-60}"
mkdir -p logs
swift build -q || exit 1
git push -q -f imac HEAD:main && ssh "$IMAC" 'cd ~/iMacDisplay && git reset -q --hard main && swift build -q' || exit 1
rm -f logs/marker.spec
.build/debug/RemoteMirrorHost --serve --latency --pattern --duration "$((DUR + 3))" --marker-spec-out logs/marker.spec "$@" > logs/host-m4.log 2>&1 &
HPID=$!
for _ in $(seq 20); do [ -s logs/marker.spec ] && break; sleep 0.5; done
[ -s logs/marker.spec ] || { echo "no marker spec"; kill $HPID; exit 1; }
SPEC=$(cat logs/marker.spec); echo "marker: $SPEC"
scripts/run-client.sh --duration "$DUR" --marker "$SPEC" --stats > logs/client-m4.log 2>&1
wait $HPID; CODE=$?
grep -E '"marker_misses"|"summary"' logs/client-m4.log
grep -E '"latency"|^PASS|^FAIL' logs/host-m4.log
exit $CODE
