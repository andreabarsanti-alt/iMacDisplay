# Roadmap

Done: M1-M12 (see `STATUS.md`). Planned next:

## M13: lid closed (clamshell) with an HDMI dummy plug

**Hardware:** a 4K HDMI dummy plug ("headless display emulator", ~€10) in the
MacBook Pro's HDMI port; MacBook on its charger.

**Why:** macOS keeps a closed MacBook awake only with power + an external display.
The dummy plug is that display, and it gives the host something to capture while
the built-in screen is off.

**Work:**
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

## Later ideas (not planned)

- Clipboard sync (dropped 2026-11-22; AirDrop for now; protocol type reserved).
- Audio from the MacBook to the iMac speakers.
- Real Apple Development certificate instead of the local self-signed identity.
