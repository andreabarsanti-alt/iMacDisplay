# Tuning (M9)

Measured with the M4 harness (`scripts/m9-tune.sh`, 30 s per setting) on 2026-11-22:
MacBook Pro (Apple silicon, macOS 26.6.2) capturing 3024x1964 native pixels, iMac 2019
(Intel, Radeon Pro 580X, 5K, macOS 15.7.7), direct Ethernet at **100 Mbps** (cable limit).
Content: desktop + animated test-pattern window + latency marker.

Latency = host draws marker -> capture -> encode -> link -> decode -> display enqueue
(the iMac panel scan-out, ~8 ms on average, is not included). Smoothness = spread of the
time between displayed frames (`gap_std_ms`); lower is smoother.

## Round 1

| config | samples | median_ms | p95_ms | display_fps | gap_std_ms | gap_p95_ms | decode_ms | encode_ms | mbps | dropped |
|---|---|---|---|---|---|---|---|---|---|---|
| h264-30-30 | 867 | 47.2 | 56.9 | 29.54 | 9.45 | 36.36 | 3.44 | 25.22 | 3.04 | 1 |
| h264-60-30 | 1675 | 59.8 | 102.4 | 58.37 | 9.22 | 19.02 | 3.28 | 37.66 | 5.78 | 2 |
| h264-60-50 | 1362 | 62.9 | 127.4 | 58.23 | 14.63 | 19.63 | 3.33 | 35.23 | 8.77 | 2 |
| h264-30-15 | 879 | 44.4 | 50.5 | 29.47 | 8.92 | 38.04 | 3.35 | 23.83 | 3.19 | 0 |
| hevc-30-20 | 876 | 52.1 | 61.5 | 29.32 | 7.25 | 39.01 | 3.29 | 25.1 | 3.12 | 1 |
| hevc-60-20 | 1673 | 34.5 | 58.3 | 56.97 | 8.33 | 22.4 | 3.27 | 13.3 | 5.97 | 1 |

## Round 2 (top candidates again)

| config | samples | median_ms | p95_ms | display_fps | gap_std_ms | gap_p95_ms | decode_ms | encode_ms | mbps | dropped |
|---|---|---|---|---|---|---|---|---|---|---|
| hevc-60-20 | 1700 | 35.1 | 55.4 | 56.93 | 7.07 | 22.54 | 3.23 | 13.32 | 6.07 | 0 |
| hevc-60-12 | 1690 | 32.7 | 45.1 | 57.17 | 6.03 | 22.32 | 2.96 | 13.36 | 5.0 | 0 |
| hevc-60-30 | 1707 | 38.6 | 62.2 | 57.23 | 7.61 | 22.05 | 3.25 | 14.2 | 7.47 | 1 |
| h264-30-15 | 874 | 44.2 | 53.9 | 29.28 | 11.15 | 39.18 | 3.48 | 21.92 | 3.18 | 1 |

## Findings

- **H.264 at 60 fps doesn't keep up** at 3024x1964: encode time rises to ~35-38 ms per
  frame, frames queue, and p95 latency jumps to 100-130 ms.
- **HEVC encodes ~2.5x faster** on the MacBook's media engine at this size (~13 ms at
  60 fps), so 60 fps is affordable: median latency drops to ~33-35 ms.
- **Lower bitrate helps p95**: smaller keyframes mean shorter bursts on the link.
  At 12 Mbps the p95 is 45 ms vs 55-62 ms at 20-30 Mbps.
- **The iMac decoder is not a limit**: ~3-3.5 ms per frame for every setting.
- Image similarity vs. a host screenshot (M3 check) went from 0.974 (H.264 30 Mbps)
  to 0.960 (HEVC 12 Mbps): slightly softer under motion; static text is unaffected.
  Human judgement decides whether to trade a little latency for bitrate.

## Decision

Default: **HEVC, 60 fps, 12 Mbps** (best p95 latency and smoothness; median 33 ms,
p95 45 ms, 57 fps). Overrides: `--h264`, `--fps`, `--bitrate` on the host.
If text looks soft during scrolling, `--bitrate 20` costs ~10 ms of p95.

Compared with the M4 baseline (H.264, 30 fps, 30 Mbps: median 49.9 / p95 56.5 ms, 29.5 fps):
about **a third less latency and twice the frame rate**.
