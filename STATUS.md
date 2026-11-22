# STATUS

**Current milestone:** M11 done (tag `m11`). Human checkpoint passed: both apps together "works like a charm" (2026-11-22). Next: M12 packaged install/uninstall.

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
- MacBook Accessibility: **granted** (2026-11-22).
- iMac: client is now `RemoteMirrorClient.app`, signed with a local self-signed identity "RemoteMirror Dev" (dedicated keychain `remotemirror.keychain-db`, created over SSH by `scripts/setup/signing-cert.sh`, no trust prompt needed). Launched via `open` so permissions belong to the app. **Accessibility: granted. Local Network: granted** (2026-11-22).

## Last test results

- M11 (`scripts/m11-test.sh`): idle window at launch; full screen 1.6 s after the host starts with no action on the iMac; back to idle after host stop, after a second session, and after the host is killed (1 s); escape hatch ends the session and stops the host; quit ends the app. Full regression M3-M10 passes after the client restructuring.
- M10 (`scripts/m10-test.sh`): state-machine unit tests; 20 start/stop cycles with the iMac connected and real capture: Stop avg 10 ms / max 23 ms, nothing listening and no capture left after each; permission denied -> "Error: Screen Recording not granted"; cable unplugged -> "Error: cable unplugged" detected in 0.9 s; no process left.
- **Bug found by M10 and fixed:** `sayGoodbye` held the connection weakly, so when the server dropped its reference the bye never completed, the 0.5 s timeout fired and the connection was never closed (the iMac only noticed via heartbeat timeout). Stop went from ~530 ms to ~10 ms.
- M9 (`scripts/m9-tune.sh`, 2 rounds): best = HEVC 60 fps 12 Mbps, median 32.7 / p95 45.1 ms, 57.2 fps, gap std 6.0 ms. Full regression M3-M8 passes with the new defaults (M3 similarity 0.960).
- Regression caught a bug from the M->Z pause rename: the key-script table mapped "m" to Z. Fixed; lesson: run the full test suite after any blanket rename.
- M8 (`scripts/m8-test.sh`): client killed -> host waits, restarted client served with keyframe first; host killed and restarted after ~1 s -> client reconnected 1372 ms after the drop, keyframe first, session continued; without the flag the client quits at once (Mutual kill); escape hatch stops a --allow-reconnect host.
- M7 + pause (`scripts/m7-test.sh`): all 13 checks pass, incl. pause hides the mirror, resume brings it back, connection kept.
- M7 (`scripts/m7-test.sh`): event tap running on the iMac; Cmd-Tab and Cmd-Space typed on the iMac reached the host with the Cmd flag; cursor shape delivered; escape hatch ended the session cleanly on both sides (no processes left).
- M6 (`scripts/m6-test.sh`, real screen capture): 25 events; 7 clicks (5 left, 1 right, 1 double) all on target, max error 0.00 pt; 5 scroll events, total dy -150.
- M5 (`scripts/m5-test.sh`, run twice): 60 key events incl. Shift, field = "Hello World 2026 ciao Mondo" exactly. Dead man's switch (`--dead-man 1`): injection stopped, 0 events, field empty. Escape hatch Ctrl-Option-Cmd-Q implemented on the client (tested in M7).
- M4 (`scripts/m4-test.sh`, 60 s, 3024x1964 H.264 30 Mbps): 1764 samples, 0 marker misses; latency min 25.1 / **median 49.9 / p95 56.5** / max 167.0 ms (draw -> capture -> encode -> link -> decode -> display enqueue; excludes iMac panel scan-out, ~8 ms avg). 29.5 fps, decode 3.4 ms.
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

- **Quality (human feedback after M3):** point-size capture (1512x982) upscaled ~3x on the iMac 5K looked soft and low-contrast. Now: native Retina pixels (3024x1964), full-range 4:2:0, sRGB/BT.709 tagged end to end, 30 Mbps default. Human: "much better", delay "very short". iMac decode ~3.5 ms/frame.
- Cursor is included in the video (`showsCursor`) until the client overlay in M7; `--no-cursor` turns it off.

- **Latency harness without clock sync:** the client echoes the marker value it decoded; the host subtracts its own draw time, so no cross-machine clock is needed.
- **Lid closed (human question):** not supported now (sleep + no display to capture). Candidate extra milestone after M11: HDMI dummy plug + clamshell mode, capturing that display at a 16:9 mode matching the iMac; alternative is a virtual display via private API.

- **Input on its own TLS connection (port 5002)**, same handshake/pinning as video; either connection dropping stops everything. Keys are sent as hardware keycodes + CGEvent flags; Cmd combos captured via `performKeyEquivalent`. Held keys are released on every stop path.

- **Cursor overlay:** host polls position (120 Hz) and shape (10 Hz) and sends them on the video connection; the client draws the cursor and follows its own mouse instantly, using the host position when the MacBook trackpad moves it. Video no longer contains the cursor (`--video-cursor` to restore).
- **Shortcut capture:** a CGEventTap at HID level on the iMac swallows all key events while the mirror window is active and forwards them; Ctrl-Option-Cmd-Q is handled in the tap too.

- **Pause toggle (human request):** Ctrl-Option-Cmd-Z hides the mirror and gives the iMac back without disconnecting; same combo brings it back (handled in the event tap, so it works while hidden). Modifiers are cleared on the host when pausing.
- **Initial connect retry:** the first launch after an app rebuild can get ENETDOWN while macOS re-checks Local Network permission; the client retries for up to 8 s before giving up.

- **No clipboard sync** (human decision 2026-11-22): AirDrop for moving data for now; protocol keeps the `clipboard` type reserved.

- **Reconnect (M8):** `--allow-reconnect` on either side. Host: a dropped client releases held input and the host waits (escape hatch still stops it). Client: a drop starts a 30 s retry window; the first frame after reconnect is a keyframe. `scripts/session.sh` uses it on both sides.
- **Status items:** both apps show a menu bar icon (Waiting / Connected / Reconnecting / Paused) with Quit; state changes are logged as JSON. Full menus come with M10/M11.

- **HostCore library (M10):** capture/encode/servers/injector/cursor + `HostSession` (start/stop sequence) + pure `HostStateMachine`. The CLI (`RemoteMirrorHost --serve`, used by all tests) and the menu bar app both run on it.
- **Menu bar app:** SwiftUI MenuBarExtra, LSUIElement. Start/Stop toggle, status + fps/Mbps line, allow keyboard & mouse switch, quality preset (12/20 Mbps), permissions with buttons to the right Settings panes, Check link, Ctrl-Option-Cmd-S global hotkey (Carbon, no permission), auto-stop on sleep / screen lock / cable unplugged / escape hatch. Reconnect always on in the app. Pairing moves to M12 (installer). MacBook now also has the local "RemoteMirror Dev" signing identity.

- **Client waiting mode (M11):** default when launched without test flags. Idle window "Waiting for MacBook…" + status item; polls the host quietly every 1 s; each session gets fresh connections/decoder; any session end returns to idle. Test runs (`--duration`, `--once`) keep the old one-shot behaviour. `scripts/run-client.sh` has `BG=1` for background launches.

## Blockers

- None.

## Running (to clean up at end of session)

- iMac: `caffeinate -dims` (PID in `~/.imacdisplay/caffeinate.pid` on the iMac).
- MacBook: `caffeinate -dims` (PID in `~/.imacdisplay/caffeinate.pid` on the MacBook).
