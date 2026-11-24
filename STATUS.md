# STATUS

**Current milestone:** M13 done (tag `m13`), release **v1.1** (lid closed with an HDMI dummy at native 5K, feedback fixes, app icon). Pending: a 30-min lid-closed run in real use; Gigabit cable (would mainly cut 5K keyframe spikes).

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

- **v1.2 (2026-11-24):** Magic Mouse gestures verified live by the human ("it worked"; 149 companion gesture events forwarded, 6 two-finger swipes caught). Update check at startup (GitHub releases API; repo made public after rewriting history to the GitHub no-reply address — no old addresses left, backup mirror kept in the scratchpad). Protocol v2: version mismatch reported clearly on both sides (tested against installed v1 iMac app and a v1.1 MacBook build). Full regression M3-M13 + feedback tests pass.
- **Magic Mouse swipes (2026-11-24, autonomous):**
  - Root cause A (fixed, proven): an invisible `loginwindow` window (level 996, 347x313, centre of the iMac screen, present since boot; probably a leftover lock-screen panel) sat above the mirror window (level 25) and swallowed clicks, scrolls and swipes in the middle of the screen (centre 0/1 clicks, 0/5 scrolls; off-centre 1/1, 5/5). Mirror window now at screen-saver level (1000): centre 1/1, 5/5. The real lock screen (shielding level) still covers it.
  - Root cause B (fixed, proven): scroll gesture phases and momentum phases were not forwarded, so swipes arrived as plain scrolls. Now packed into InputEvent.code (ScrollCode, backward compatible) and set on injected events. `scripts/fb-swipe-test.sh`: began/changed/ended + momentum reach the MacBook; control RM_NO_SCROLL_PHASES=1 fails.
  - Root cause C (fixed, proven): precise deltas were rounded per event (slow scrolls < 0.5 px lost). The injector carries the fraction forward: 12 x 0.4 px arrive as 4.0 px (was 0). Unit tests.
  - **Gestures (from a human recording with --record-gestures):** real Magic Mouse scrolls come with companion gesture events (CGEvent type 29, field 110 = 6); two-finger swipes are Dock events (type 30, 110 = 23, 124 = progress). Replaying a recorded swipe with its companions made WebKit go back on the MacBook, without them it didn't (a replay bug - setting field 55 last wiped the other fields - had hidden this at first).
  - One-finger swipes: the iMac forwards the companion events (new `gesture` message), the MacBook re-posts them before the scrolls -> native back/forward with animation. `scripts/fb-pageswipe-test.sh` PASS; control RM_NO_GESTURES=1 FAIL. Fallback (iMac menu, off): recognise on the iMac and send localized Cmd-[ / Cmd-].
  - Two-finger swipes: swallowed on the iMac (its desktops stay put), sent as `action` next/previous desktop; the MacBook presses its *configured* Mission Control shortcuts (com.apple.symbolichotkeys). Replay e2e: iMac caught it, MacBook pressed Ctrl-Right. Real desktop switch not observable here (MacBook has one desktop).
  - Mission Control action: presses the configured shortcut (here F9): opened and closed (Dock windows 2 -> 4 -> 2). Two-finger double tap -> Mission Control not wired yet (event not identified in the recording).
  - Back/Forward shortcut resolution: macOS localizes Cmd-[ per layout (Italian: Cmd-o-grave / Cmd-a-grave); the MacBook finds the key with an in-memory main-menu probe (nothing pressed); verified against a test menu.
  - Unattended runs: the iMac's screen saver (loginwindow frontmost) swallows posted events; tests need the iMac awake (caffeinate).
- **5K tuning (lid closed, dummy at 2560x1440 HiDPI = 5120x2880):** HEVC 60 fps can't keep up (encode ~40 ms; median 80-90 / p95 116-155 ms); 5K 30 fps 58 / 80 ms; 4K-capped 60 fps 51 / 72 ms; 1440p 60 fps 51 / 59 ms. Live comparison by the human: 4K "not sharp enough", 5K 30 fps "looks good" -> default above 4K is 30 fps (menu: 5K frame rate 30/60); built-in stays 60 fps. p95 at 5K grows with bitrate (bigger keyframes on the 100 Mbps link).
- **M13 with the HDMI dummy (2026-11-23, human):** plugged in mid-session -> dummy set to 2560x1440 HiDPI (5120x2880 px), live switch 1.26 s, iMac shows native 5K, lid closed and the session continues. Pending: 30-min lid-closed run, latency/tuning at 5120x2880.
- **Feedback 2026-11-23 (items 2, 3, 5):**
  - Disconnections: the MacBook's idle sleep is 1 min; injected input does reset the idle timer, but any pause without input let the MacBook sleep and the app (by design) ended the session. Now both apps hold IOPM assertions while sharing (MacBook: no idle system/display sleep, so no auto-lock; iMac: display stays on), released at stop. `scripts/fb-awake-test.sh` passes. Deliberate sleep / lid close / manual screen lock still stop the session.
  - Timestamped logs: `~/Library/Logs/RemoteMirror/MacBook.log` and `iMac.log`; MacBook menu shows "Last stopped <time>: <reason>" and "Open log".
  - Screenshot selection could not be moved/resized from the iMac: the screenshot toolbar's handles read the event *deltas*, which injected events lacked. The injector now sets mouseEventDeltaX/Y. `scripts/fb-screenshot-test.sh` (with a control run, RM_NO_MOUSE_DELTAS=1, that must fail) passes.
  - Also fixed: a second host could not listen (port in use) but claimed "Waiting for iMac"; it now fails with "port already in use".
  - Lesson: experiments that inject keys on the MacBook must never send Esc (it reached the Terminal and interrupted the agent) and must end any screenshot session they start (a leftover overlay swallowed the input tests).
  - Regression M3-M13 passes (M4 median 39.5 / p95 53.2 ms).
  - **Incident (fixed):** the screenshot test "restored" `com.apple.screencapture last-selection` with `defaults write -dict`, which stores numbers as strings; screencapture then crashed on every screenshot, even directly on the MacBook. Fixed by deleting the key; the test now exports/imports the whole domain (types preserved).
  - Host app logging was silenced in normal runs (self-test quieting applied always); fixed in code, not yet installed.
- M13 without plug (`scripts/m13-test.sh`): display policy + 16:9 mode unit tests (38 total); mid-session capture switch 3024x1964 -> 1512x982, iMac continued at 57.4 fps to the end; clicks exact after a switch. Regression M3/M4/M6/M8/M10/M11 passes (M4 median 34.6 / p95 43.0 ms).
- Second MacBook: installed from the v1.0 release; installer adapter name problem fixed in v1.0.1 (auto-detect).
- M12: packages built on the MacBook (arm64 host app, x86_64 client cross-built). Sandbox-home install/uninstall on the MacBook (files, key, identity removal) found and fixed 3 installer bugs (signing failure not detected; `| grep -q` under pipefail; keychain search list edge case). Real install on both Macs with `--skip-network`: permissions carried over; installed apps pass 3 start/stop cycles with the iMac connected; real uninstall/reinstall on the iMac (app, login item, process removed; kept items kept).
- **Full uninstall + reinstall on the iMac (human-run, 2026-11-22):** uninstall removed app, login item, permission entry, key and identity and restored the cable interface to DHCP from the backup; install set 10.77.0.2 again with a new backup. The first install run stopped at the pairing step (pairing file missing) after already changing the network, so the installer now checks for the pairing file before touching anything. Completed with a fresh pairing file: new identity, key fingerprint matches the MacBook, Accessibility + Local Network re-granted by the human, 3/3 session cycles pass.
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
