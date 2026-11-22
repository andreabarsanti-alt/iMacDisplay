# STATUS

**Current milestone:** M1 done (tag `m1`). Waiting at **Gate 1** (link speed) and **Gate 2** (permissions) before M2.

## Machines

| | MacBook (host) | iMac (client) |
|---|---|---|
| Arch | arm64 | x86_64 |
| macOS | 26.6.2 | 15.7.7 |
| Swift | 6.3.3 (CLT, no Xcode) | 6.2.4 (CLT, no Xcode) |
| Link | Belkin USB-C LAN `en9`, 10.77.0.1/24 | built-in `en0`, 10.77.0.2/24 |
| SSH | — | `andrea@10.77.0.2`, key-only from MacBook |
| Repo | `~/Python/iMacDisplay` | `~/iMacDisplay` (push target `imac`, updateInstead) |

## Gate 1: preflight (`QUICK=1 scripts/preflight.sh`, 2026-11-22)

All pass except link speed:
- FAIL: both ends negotiate **100baseTX**; iperf3 **94 Mbps** each way (target ≥ 900). Likely the cable (needs all 8 wires: Cat5e/Cat6).
- PASS: arch, toolchains vs package (tools 6.0, macOS 13), git in sync, masks, Internet Sharing off, ping 0.69 ms avg / 0% loss, ports 5001/5002 free, native builds, hardware H.264+HEVC encode (MacBook) and decode (iMac).
- Note: macOS firewall is **off** on both; plan step 5 of "Securing the link" wants it on (human to change).

**Human decision needed:** swap the cable, or accept 100 Mbps for now. 100 Mbps is enough for H.264 at ~25-40 Mbps (the plan's bitrate), so development can continue.

## Gate 2: permissions — not started

Needs a human at the MacBook for Screen Recording + Accessibility (before M2/M5), and possibly at the iMac.

## Last test results

- M1: `scripts/test.sh` 16/16 pass on arm64 and x86_64; cross-machine check `RemoteMirrorHost --emit-vectors | ssh imac RemoteMirrorClient --verify-vectors` → PASS (10 vectors); tampered input rejected.

## Decisions

- **Swift Testing, not XCTest:** neither Mac has Xcode; CLT ships only Swift Testing. `scripts/test.sh` passes the framework paths and disables cross-import overlays (the iMac CLT 6.2.4 ships `_Testing_Foundation` without module files).
- **Swift 5 language mode** with tools-version 6.0, to avoid strict-concurrency friction with AVFoundation/VideoToolbox callbacks.
- **Repo reaches the iMac by `git push imac`** over the cable (no GitHub credentials needed on the iMac).
- Protocol v1: `length u32 LE | type u8 | payload`, explicit LE, hard caps 8 MB (video) / 64 KB (control), decoder rejects oversized frames before buffering.

## Blockers

- Gate 1 link speed (human).
- Gate 2 permissions (human).

## Running on the iMac (to clean up at end of session)

- `caffeinate -dims` (PID in `~/.imacdisplay/caffeinate.pid`).
