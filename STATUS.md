# STATUS

**Current milestone:** M3 done (tag `m3`). Human checkpoint: look at the iMac mirror. Next: M4 latency harness. Accessibility (needed for M5) still `denied`.

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

**Decision (2026-11-22):** human accepted 100 Mbps for now; cable upgrade later. Bitrate must stay well under ~90 Mbps.

## Gate 2: permissions

- Decision: permissions granted to **Terminal.app** (no signing identity on either Mac; processes started from Terminal inherit its TCC grants, so rebuilds don't reset them). Revisit with a real certificate for the M10 app.
- MacBook Screen Recording: **granted** (works without restarting Terminal).
- MacBook Accessibility: **denied** so far (needed from M5).
- iMac: client runs over SSH, attaches to the logged-in GUI session; no prompts so far (no Local Network prompt either).

## Last test results

- M3 (`scripts/m3-test.sh`): real screen 30 s → 29.5 fps displayed, HW decode 1.7 ms, 0 errors; client frame vs host screenshot similarity 0.974; mutual kill on client exit; wrong key, wrong source address (10.77.0.1) and plain TCP all rejected.
- M2 (`RemoteMirrorHost --capture-test`): 28.9 fps, HW H.264 1512x982, encode 4.8 ms avg. `--encoder-test` (synthetic) passes for H.264 and HEVC.
- M1: `scripts/test.sh` 16/16 pass on arm64 and x86_64; cross-machine check `RemoteMirrorHost --emit-vectors | ssh imac RemoteMirrorClient --verify-vectors` → PASS (10 vectors); tampered input rejected.

## Decisions

- **Swift Testing, not XCTest:** neither Mac has Xcode; CLT ships only Swift Testing. `scripts/test.sh` passes the framework paths and disables cross-import overlays (the iMac CLT 6.2.4 ships `_Testing_Foundation` without module files).
- **Swift 5 language mode** with tools-version 6.0, to avoid strict-concurrency friction with AVFoundation/VideoToolbox callbacks.
- **Repo reaches the iMac by `git push imac`** over the cable (no GitHub credentials needed on the iMac).
- Protocol v1: `length u32 LE | type u8 | payload`, explicit LE, hard caps 8 MB (video) / 64 KB (control), decoder rejects oversized frames before buffering.

- **PSK in a file, not Keychain (dev deviation):** `~/.imacdisplay/psk` (mode 600) on both Macs, installed by `scripts/install-key.sh`. Unsigned binaries would trigger Keychain access prompts on every rebuild. Move to Keychain with the signed M10 app.
- `requiredInterfaceType = .wiredEthernet` removed: made the iMac connection fail with ENETDOWN. Binding to 10.77.0.1 + peer pinning to 10.77.0.2 keeps traffic on the cable.
- **Firewall:** off on both, turned on by the human later with allow rules (unsigned rebuilds would re-prompt).
- Client launched with plain `ssh` (`scripts/run-client.sh`); `launchctl asuser` needs root.

## Blockers

- Accessibility for Terminal on the MacBook (human) before M5.

## Running (to clean up at end of session)

- iMac: `caffeinate -dims` (PID in `~/.imacdisplay/caffeinate.pid` on the iMac).
- MacBook: `caffeinate -dims` (PID in `~/.imacdisplay/caffeinate.pid` on the MacBook).
