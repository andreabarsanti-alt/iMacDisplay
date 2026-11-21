# Agentic build plan: iMac as screen + keyboard/mouse for the MacBook Pro

Companion to `imac-as-mbp-display-plan.md` (technical design). This file covers **who does what**, the **gates** where a human is required, and how the agent **verifies its own work** without seeing the screens.

**Hardware:** MacBook Pro = **Apple silicon (`arm64`)**, host. iMac 2019 = **Intel (`x86_64`)**, client. Different architectures: the host is built on the MacBook, the client is built on the iMac (over SSH).

## Principles

- Human does what only a human can: physical setup, GUI permission prompts, final feel test.
- Agent does everything else: code, build, deploy, run, measure, fix.
- Every milestone has an **automated acceptance test**, so the agent knows when it's done without a person watching.
- All work happens in one git repo (`github.com/andreabarsanti-alt/iMacDisplay`), small commits, one branch per milestone.

## Agent topology

**Recommended: one agent on the MacBook, SSH into the iMac.**
- Claude Code runs on the MacBook (host side, `arm64`), inside the repo.
- The agent reaches the iMac over SSH (Remote Login enabled) to: `git pull`, `swift build` (native `x86_64` client build), launch/kill the client, read logs, run tests.
- One brain, no coordination problems, one source of truth.

**Alternative: Claude Code on both Macs.**
- Same repo, shared via a git remote; coordination through a `COORDINATION.md` file (who is working on what, current protocol version, open questions).
- Only worth it if SSH proves awkward, or if something has to be done inside the iMac's GUI session.

## Phase 0: human setup (one time)

**Both Macs**
- [ ] Direct Ethernet cable between the Macs with static IPs (see "Direct Ethernet link"); Wi-Fi stays on only for internet
- [ ] Xcode installed and launched once (license accepted): `xcodebuild -version` works
- [ ] Command Line Tools installed: `swift --version` works (versions may differ between the Macs; the package targets the older toolchain)
- [ ] Git installed; access to the same remote (or the iMac pulls from the MacBook over SSH)
- [ ] Keep both awake during the work: `caffeinate -d` or Energy settings; iMac display must be on

**iMac (Intel)**
- [ ] System Settings > General > Sharing > **Remote Login** on (your user only)
- [ ] Add the MacBook's SSH public key to `~/.ssh/authorized_keys` (so no passwords)
- [ ] A user session logged in (GUI app tests need it)

**MacBook (Apple silicon)**
- [ ] Claude Code installed, repo cloned on both Macs
- [ ] Stable **code signing identity** (free Apple Development certificate is fine, same one on both Macs) so permissions survive rebuilds
- [ ] Terminal/Claude Code allowed to run builds without prompts for the repo folder
- [ ] USB-C/Thunderbolt Ethernet adapter (the MacBook has no Ethernet port)

## Phase 1: preflight checks (agent runs, human watches)

A script `scripts/preflight.sh` run from the MacBook, reporting PASS/FAIL per line:

1. OS versions and CPU architecture on both: expects `arm64` on the MacBook and `x86_64` on the iMac (`uname -m`); FAIL if not
2. `swift` and `xcodebuild` versions on both; PASS only if the package's `swift-tools-version` is supported by both toolchains and its deployment target is ≤ both macOS versions
3. SSH to iMac works non-interactively
4. Git repo present and in sync on both
5. Network over the link addresses (`10.77.0.1` / `10.77.0.2`): `ping` (avg, max, loss over 30 s), `iperf3` (throughput both directions, 30 s), jitter summary
6. Ports 5001/5002 free; macOS firewall state noted
7. A tiny "hello" Swift binary built natively and run on both machines; `file` confirms `arm64` on the MacBook and `x86_64` on the iMac
8. Link interface up at 1 Gbps full duplex on both (`networksetup -getMedia`), Internet Sharing off, firewall state noted
9. Hardware video: on the MacBook a short `VTCompressionSession` test confirms hardware H.264 (and HEVC) encode; on the iMac a short decode test confirms hardware decode

**Gate 1:** all PASS, with ~900+ Mbps, sub-millisecond ping and no packet loss over the link.

## Phase 2: permissions gate (human, GUI only)

These cannot be granted by an agent. A stub app (`PermissionProbe`, built by the agent for each architecture) requests them so the prompts appear in the right place:

| Machine | Permission | Needed for |
|---------|------------|------------|
| MacBook | Screen Recording | ScreenCaptureKit |
| MacBook | Accessibility | injecting events with `CGEvent` |
| iMac | Accessibility | global event tap (only if used) |
| iMac | Local Network (if prompted) | incoming connections |

The probe prints a JSON status line per permission (`granted` / `denied`), which the agent reads over SSH/locally.

**Gate 2:** all required permissions report `granted` using the signed build. Note: if the signing identity changes, permissions reset, so the agent must never change the signing setup.

## Phase 3: autonomous development

The agent works through milestones in order, runs the acceptance test for each, commits, and moves on only when it passes. Test hooks are built into the apps so no one needs to look at a screen.

**Build and deploy loop**
- Host: `swift build` on the MacBook (`arm64`).
- Client: push, then over SSH on the iMac `git pull && swift build` (`x86_64`). Fallback: `swift build --arch x86_64` on the MacBook and copy the binary over the link.
- Every milestone build must pass on **both** architectures before its test runs; shared code is tested on both (`swift test` locally and over SSH).

**Debug/control channel** (built early, used by every test)
- Both apps accept a local control socket or CLI flags: `--test-mode`, `--log-json`, `--dump-frame <path>`, `--stats`.
- Host logs: capture fps, encode time, bytes sent, dropped frames.
- Client logs: frames received/decoded/displayed, decode time, arrival jitter, and can **write the current displayed frame to a PNG** so the agent can inspect it.

| # | Milestone | Automated acceptance test |
|---|-----------|---------------------------|
| M1 | Skeleton, shared protocol, framing | Unit tests for message encode/decode and framing round-trip pass on both `arm64` and `x86_64`; a message encoded on one machine decodes identically on the other |
| M2 | Host capture + hardware encode | Host runs 10 s, logs ≥ 25 fps average, encoder reports hardware acceleration, encoded bytes > 0, no errors |
| M3 | Transport + client display (TLS-PSK, link-only binding) | Client logs ≥ 25 fps displayed for 30 s; `--dump-frame` PNG compared to a host-side screenshot (similarity threshold); a connection with a wrong key or from another address is rejected |
| M4 | **Latency measurement harness** | Host draws a timestamp/QR-like marker in a test window; client dump-frame decodes it; agent computes glass-to-glass latency over 60 s; reports median/p95 |
| M5 | Input forward (keyboard) | Agent runs a test text field on the MacBook; client test mode sends a scripted key sequence; host logs and the field content match exactly |
| M6 | Input forward (mouse/scroll) | Scripted moves/clicks on a test window with known button rectangles; host test window logs hit positions within ±2 px after scaling |
| M7 | Cursor overlay, shortcut capture, escape hatch | Scripted test of the escape combo releases capture and exits cleanly; shortcut test forwards Cmd-Tab events to the host log |
| M8 | Clipboard sync, reconnect, status items | Kill/restart each side mid-session; with `--allow-reconnect`, reconnection within 3 s with a keyframe (without it, the apps stay stopped, per Mutual kill); clipboard text round-trips |
| M9 | Quality/latency tuning | Run M4 harness at 3+ settings, including H.264 vs HEVC and 30 vs 60 fps, watching iMac decode time; keep the best by p95 latency and smoothness; record results in `docs/tuning.md` |
| M10 | Host menu bar app (see "Host app") | State machine unit tests; 20 start/stop cycles leave no process, port or capture session behind; Stop completes in < 1 s; permission-denied and cable-unplugged paths end in a clear error state |
| M11 | Client waiting/status UI on the iMac | Client idles with "Waiting for MacBook"; goes full-screen when sharing starts and returns to idle when it ends, with no manual step on the iMac |

**Agent rules**
- Never run sudo or change system settings, firewall, or signing configuration; ask the human instead.
- Never raise `swift-tools-version` or the deployment target above what the iMac supports.
- Keep a `STATUS.md`: current milestone, last test results, blockers, and decisions taken. Update after every milestone.
- Commit after each passing milestone; tag `m1`...`m11`.
- If a test fails 3 times with different fixes, stop, write the findings in `STATUS.md`, and flag a human checkpoint rather than thrash.

## Host app (menu bar GUI on each MacBook)

Sharing is controlled entirely from the app: you start it there and you stop it there.

**Form:** a SwiftUI `MenuBarExtra` app with no Dock icon (`LSUIElement`), macOS 13+. The existing host code becomes a library the app drives. Built `arm64`; built universal if it must also run on an Intel MacBook.

**States and icon:** Idle, Connecting, Sharing, Error. The menu bar icon changes per state (a clear "sharing" indicator while capture and input are live). macOS also shows its own recording indicator while capture runs.

**Menu**
- **Start Sharing / Stop Sharing**: a single toggle.
- Status line: "iMac connected", fps, latency, link speed (from the stats channel).
- **Allow keyboard & mouse control**: switch; off means view-only.
- **Preferences:** iMac address, key ID, display to share, quality preset.
- **Permissions:** shows Screen Recording and Accessibility as granted or missing, with buttons that open the right System Settings pane.
- **Check link:** runs the preflight link checks (interface up, iMac reachable, port).
- **Pair this MacBook:** first-run step that creates this MacBook's key (stored in Keychain) with a name (for example `mbp-new`) and exports a pairing file to install on the iMac (copied over the cable).
- **Quit**.

**Start sequence:** check permissions, check that the link interface has `10.77.0.1` and the iMac answers, open the listener on the link address only, authenticate, start capture, then start accepting input.

**Stop sequence (also used on any failure):** stop accepting input, release all held keys and buttons, stop capture, send a `bye` message so the iMac client returns to idle, close the connection and the listener. The app is then Idle and nothing is listening.

**Rules**
- **Opt-in each session:** nothing listens while Idle, and the app does not start sharing at login. This shrinks the exposed surface to the time you are sharing.
- **Automatic stop** on sleep, screen lock, cable unplugged, missed heartbeat, or the iMac's escape combo.
- **A local hotkey on the MacBook** (for example Ctrl-Option-Cmd-S) also triggers Stop, so you never need the menu if it is hard to reach.
- The MacBook's own keyboard and trackpad always work, so the menu is always clickable.
- The watchdog and `STOP` file keep working during development and call the same stop path.

**iMac client:** a small matching app (`x86_64`): idle shows "Waiting for MacBook" (with the connected host name once paired), goes full-screen when sharing begins, and returns to idle when it ends. The iMac-side escape combo ends the session from that side.

## Direct Ethernet link (replaces Wi-Fi as the app and dev link)

A cable straight between the two Macs is a private two-host network: no router, no other devices, nothing else can reach it.

**Setup (human, once)**
- MacBook: USB-C/Thunderbolt Ethernet adapter into the iMac's Ethernet port (any normal cable; auto-crossover handles it).
- System Settings > Network > the Ethernet interface > Details > TCP/IP > Configure IPv4 **Manually**:
  - MacBook: `10.77.0.1`, subnet mask `255.255.255.0`, router blank
  - iMac: `10.77.0.2`, subnet mask `255.255.255.0`, router blank
- Keep Wi-Fi first in the service order so internet traffic doesn't try to use the cable.
- Internet Sharing stays **off** on both Macs (otherwise the cable gets bridged to the internet).
- Check: `ping 10.77.0.2` from the MacBook; `iperf3` should show ~900+ Mbps and sub-millisecond latency. Update `scripts/preflight.sh` to run these checks over the link addresses, and let the agent SSH to `10.77.0.2` so dev traffic stays off Wi-Fi.

**Securing the link (do these from M1, not later)**
1. **Bind to the link address only.** The host listens on `10.77.0.1`, never `0.0.0.0`; the client connects to that address. Nothing is exposed on Wi-Fi.
2. **Peer pinning.** The host accepts connections only from `10.77.0.2`; the client connects only to `10.77.0.1`.
3. **Authenticated and encrypted with TLS-PSK** (`Network.framework`, `sec_protocol_options_add_pre_shared_key`). The key is a random 32-byte secret stored in each Mac's Keychain, never in the repo. This blocks any other local process or user on either Mac from impersonating the client, and protects the stream if someone ever taps the cable.
4. **Handshake with protocol version and a nonce** before any video or input; the host rejects anything malformed, with a hard cap on message sizes.
5. **macOS firewall on** on both Macs, stealth mode on; allow only the two apps.
6. **SSH only over the link:** key-only authentication, password login disabled. If you can, restrict the iMac's Remote Login to your user only (Sharing settings).
7. **Heartbeat and watchdog run over the same link** (see Mutual kill); unplugging the cable counts as "off" and stops everything.

**What this does and doesn't cover**
- Covers: other devices on your Wi-Fi, passive sniffing, and spoofed clients from the network.
- Doesn't cover: malware already running as your user on either Mac (it could read the Keychain secret), or someone with physical access to the Macs. The Keychain item should be limited to the app's signature.

## Stop controls (you can halt the agent at any time)

**Stop the agent**
- **Esc** in Claude Code interrupts the current action immediately; **Ctrl+C** twice exits the session. Nothing is lost: work is in small commits on milestone branches.
- Run Claude Code in the **default permission mode**, not auto-accept or bypass. Allowlist only routine commands (build, test, git, the repo's scripts) in `.claude/settings.json`; anything else, including new `ssh` commands, prompts you.
- **STOP file:** the agent checks for a file named `STOP` in the repo root before every milestone step, deployment and app launch. If it exists, it halts, writes the state to `STATUS.md` and waits. Create it from either Mac: `touch STOP` (remove it to resume).

**Stop the apps**
- `scripts/killall.sh` stops the host app locally and the client app on the iMac (over SSH). Manual equivalent: `pkill -f RemoteMirror` on each Mac.
- Every launched process is tracked in a pidfile so nothing is left running after a halt.
- The client's escape key combo releases capture and quits; the host's dead man's switch stops injection on a lost connection.

**Mutual kill: if one machine goes off, the other stops everything immediately**
- **App-level heartbeat** (not TCP keepalive, which is too slow to notice a power-off): both apps send a tiny ping every 500 ms on the control connection. No ping for 2 s means the peer is gone.
- **Apps:** on heartbeat timeout or socket close, the host stops injecting input and the client releases capture; both then quit and do not auto-reconnect while the watchdog flag is set (reconnect is only for brief drops, see M8: a timeout of 2 s is a stop, a reconnect window applies only if `--allow-reconnect` is passed).
- **Dev watchdog** (`scripts/watchdog.sh`, runs on the MacBook for the whole session): every 1 s it checks the iMac (`ping -c1 -W1` plus an SSH probe every 5 s). After 3 consecutive failures it:
  1. creates the `STOP` file,
  2. runs `scripts/killall.sh` (kills the host app locally and, if reachable, the client),
  3. writes the reason and timestamp to `STATUS.md`.
- **Agent halt on STOP:** a Claude Code **PreToolUse hook** in `.claude/settings.json` runs `scripts/check-stop.sh`, which exits with code 2 when `STOP` exists. That blocks every further tool call, so the agent cannot build, deploy or launch anything until you remove the file.
- **If the MacBook goes off:** the agent dies with it, and the iMac client quits on the missed heartbeat (2 s). The iMac cannot start anything on its own because the agent only acts through the MacBook.
- **Sleep or lid close counts as off:** the missed heartbeat triggers the same stop.
- Resume manually: remove `STOP`, run `scripts/preflight.sh`, then restart the session.

**Hard cut-offs (no software needed)**
- Local keyboard and trackpad on the MacBook are never blocked.
- Unplug the Ethernet cable, or turn off Remote Login on the iMac, to cut the agent's reach and the video/input link instantly (Wi-Fi is only for internet and no longer carries the link).

## Safety for input injection

Remote input injection can lock you out of the MacBook if something goes wrong. Built in from M5 onward:
- **Escape hatch:** a reserved key combo on the client that always releases capture and quits (tested in M7, but a basic version ships with M5).
- **Dead man's switch:** in test mode the host auto-stops injecting after N seconds and on any lost connection.
- **Never test input unattended** until the escape hatch has passed its test; keep the MacBook's own keyboard/trackpad usable (local input is never blocked).
- Injection only accepted from the configured client IP plus a shared secret in the handshake.

## Human checkpoints

| When | What the human does |
|------|---------------------|
| Gate 1 | Confirm network numbers and toolchain versions are acceptable |
| Gate 2 | Grant permissions on both Macs |
| After M3 | Look at the iMac: does the mirror look right? |
| After M7 | Feel test: typing, mouse, shortcuts, escape hatch |
| After M9 | Final judgement on latency and image quality |

## Suggested kickoff prompt for the agent (MacBook, in the repo)

> Read `imac-as-mbp-display-plan.md` and `imac-mbp-agentic-build-plan.md`. The MacBook is Apple silicon (arm64) and the iMac is Intel (x86_64): build the host here and the client natively on the iMac over SSH. Create the repo skeleton, then write and run `scripts/preflight.sh` against the iMac at `10.77.0.2` (SSH user `<user>`). Report results and stop at Gate 1. After I confirm Gates 1 and 2, work through M1-M11 autonomously, following the agent rules and updating `STATUS.md` after each milestone.

## Fill in before starting

- iMac IP / hostname: `10.77.0.2` / `________`
- MacBook IP / hostname: `10.77.0.1` / `________`
- Architectures: MacBook `arm64` (Apple silicon) / iMac `x86_64` (Intel)
- SSH user on iMac: `________`
- macOS versions (iMac / MacBook): `________ / ________`
- Xcode / Swift versions (iMac / MacBook): `________ / ________`
- Repo location / remote: `github.com/andreabarsanti-alt/iMacDisplay` (private)
