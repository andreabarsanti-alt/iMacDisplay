#!/bin/bash
# M9: run the M4 latency harness at several codec / fps / bitrate settings and
# write a comparison table to docs/tuning.md. DUR (default 30) seconds per setting.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f STOP ] && { echo "STOP present"; exit 2; }
DUR="${DUR:-30}"
CONFIGS=(
  "h264-30-30|--h264 --fps 30 --bitrate 30"
  "h264-60-30|--h264 --fps 60 --bitrate 30"
  "h264-60-50|--h264 --fps 60 --bitrate 50"
  "h264-30-15|--h264 --fps 30 --bitrate 15"
  "hevc-30-20|--fps 30 --bitrate 20"
  "hevc-60-20|--fps 60 --bitrate 20"
)
# Override the list: scripts/m9-tune.sh "name|args" ...
[ $# -gt 0 ] && CONFIGS=("$@")
OUT=${OUT:-logs/m9-results.tsv}
printf "config\tsamples\tmedian_ms\tp95_ms\tdisplay_fps\tgap_std_ms\tgap_p95_ms\tdecode_ms\tencode_ms\tmbps\tdropped\n" > $OUT
for c in "${CONFIGS[@]}"; do
  name=${c%%|*}; args=${c#*|}
  echo "== $name ($args)"
  # shellcheck disable=SC2086
  DUR=$DUR scripts/m4-test.sh $args > logs/m9-$name.out 2>&1
  cp logs/host-m4.log logs/m9-$name-host.log; cp logs/client-m4.log logs/m9-$name-client.log
  python3 - "$name" logs/m9-$name-host.log logs/m9-$name-client.log >> $OUT <<'PY'
import json, sys
name, hl, cl = sys.argv[1:4]
def events(path, ev):
    out = []
    for line in open(path):
        line = line.strip()
        if line.startswith("{"):
            try:
                d = json.loads(line)
                if d.get("event") == ev: out.append(d)
            except Exception: pass
    return out
lat = (events(hl, "latency") or [{}])[-1]
hs = (events(hl, "summary") or [{}])[-1]
cs = (events(cl, "summary") or [{}])[-1]
print("\t".join(str(x) for x in [name, lat.get("samples", 0), lat.get("median_ms", "?"), lat.get("p95_ms", "?"),
      cs.get("avg_display_fps", "?"), cs.get("gap_ms_std", "?"), cs.get("gap_ms_p95", "?"), cs.get("decode_ms_avg", "?"),
      hs.get("encode_ms_avg", "?"), cs.get("avg_mbps", "?"), hs.get("dropped", "?")]))
PY
  tail -1 $OUT
done
column -t -s $'\t' $OUT
