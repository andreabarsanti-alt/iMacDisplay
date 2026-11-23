# Roadmap

Done: M1-M12 (see `STATUS.md`). M13 in progress: everything that works without the
plug is built and tested (`scripts/m13-test.sh`); the lid-closed run waits for the plug.

## M13: lid closed (clamshell) with an HDMI dummy plug

**Hardware:** a 4K HDMI dummy plug ("headless display emulator", ~€10) in the
MacBook Pro's HDMI port; MacBook on its charger.

**Why:** macOS keeps a closed MacBook awake only with power + an external display.
The dummy plug is that display, and it gives the host something to capture while
the built-in screen is off.

**Built (2026-11-22, without the plug):** display choice (Automatic / Built-in /
External; Automatic = external when present) in the menu bar app and `--display`;
"Fit external display to iMac (16:9)" picks 2560x1440 HiDPI or the largest 16:9 HiDPI
mode; live capture switching on display changes (CGDisplay reconfiguration callback,
capture-lost recovery) without ending the session; input and cursor follow the shared
display. Test: mid-session switch in ~60 ms, iMac continues at 57 fps, clicks exact.

**Verified with the plug (2026-11-23, human + logs):** dummy "HDP-V104" plugged in while
sharing the built-in display -> app set it to 2560x1440 HiDPI (5120x2880 px, the iMac's
native 5K) and switched capture live in 1.26 s; the iMac got 5120x2880 without
reconnecting; lid closed, session continued ("it does, lovely").

**Still to verify with the plug:** lid-closed 30 min run, the 16:9 mode on the real
dummy, the switch when the lid actually closes, latency at 5120x2880.

**Work (original plan):**
- Host: choose the display to share (Preferences > Display: built-in / dummy /
  automatic). Automatic = the dummy when the lid is closed, otherwise the built-in.
- Set the dummy to a 16:9 HiDPI mode matching the iMac 5K (2560x1440 HiDPI ->
  5120x2880 pixels, exactly 2x): fills the iMac with no black bars.
- Lid close is no longer "off" while a dummy display is present and power is
  connected; sleep still stops sharing (Mutual kill unchanged).
- Keep windows off the invisible display when the lid is open (or share it).
- Re-run tuning (M9): 5120x2880 capture vs 2560x1440 HiDPI, HEVC 60 fps.

**Acceptance:** Start Sharing with the lid open, close the lid: 30 min session without sleep,
latency within 10% of M9, full-screen image without bars; opening the lid switches
back to the built-in display cleanly.

**Flow (decided 2026-11-22):** start sharing with the lid **open** (menu bar as
today), then close the lid; the session continues. No starting with the lid
closed, so "nothing listens while Idle" stays.

**To decide when the plug arrives:** what the iMac shows while the lid is still open:
- *dummy display from the start* - no switch when the lid closes, no bars; or
- *built-in first, follow the lid* - on lid close macOS moves windows to the dummy
  and the host switches capture to it (brief blink, aspect changes 3:2 -> 16:9).

## Feedback (2026-11-23)

- Done: frequent disconnections (keep-awake while sharing), keep connection when the
  MacBook would lock from idle, screenshot selection from the iMac (mouse deltas),
  session logs.
- Parked: share audio.

## Later ideas (not planned)

- Clipboard sync (dropped 2026-11-22; AirDrop for now; protocol type reserved).
- Audio from the MacBook to the iMac speakers.
- Real Apple Development certificate instead of the local self-signed identity.
