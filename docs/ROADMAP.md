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

**Acceptance:** with the lid closed, Start Sharing from the iMac side or a hotkey
(the menu bar isn't visible with the lid closed), 30 min session without sleep,
latency within 10% of M9, full-screen image without bars; opening the lid switches
back to the built-in display cleanly.

**Open question:** starting a session with the lid closed. Options: start before
closing the lid; a "Start" button in the iMac waiting window that asks the MacBook
(needs a small always-on listener on the MacBook, which the M10 rule "nothing
listens while Idle" currently forbids); or a scheduled/hotkey start.

## Later ideas (not planned)

- Clipboard sync (dropped 2026-11-22; AirDrop for now; protocol type reserved).
- Audio from the MacBook to the iMac speakers.
- Real Apple Development certificate instead of the local self-signed identity.
