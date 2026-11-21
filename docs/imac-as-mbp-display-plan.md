# iMac 2019 as screen + keyboard/mouse for the MacBook Pro

Custom Swift app, two targets: **Host** (MacBook) and **Client** (iMac).
Goal: mirror the MacBook screen on the iMac and control it with the iMac's keyboard and mouse.
Link: direct Ethernet cable between the two Macs (static IPs, TLS-PSK; see `imac-mbp-agentic-build-plan.md`). Wi-Fi is used only for internet.
Repo: `github.com/andreabarsanti-alt/iMacDisplay` (private).

## Hardware

| Machine | Role | CPU / arch | Notes |
|---------|------|------------|-------|
| MacBook Pro | Host | **Apple silicon, `arm64`** | Hardware H.264/HEVC encode in the media engine; ScreenCaptureKit; USB-C/Thunderbolt ports (Ethernet via adapter) |
| iMac 2019 | Client | **Intel, `x86_64`** | Built-in Gigabit Ethernet; hardware H.264/HEVC decode; may be limited to an older macOS than the MacBook |

The two machines have **different architectures**: every binary is built per architecture (see "Building for two architectures"). No Rosetta is needed.

## Architecture

```
MacBook (Host, arm64)                        iMac (Client, x86_64)
ScreenCaptureKit -> VideoToolbox H.264  ---> VideoToolbox decode -> AVSampleBufferDisplayLayer
                  (video: TCP, port 5001)
CGEvent injection  <---------------------   NSView / CGEventTap input capture
                  (input: TCP, port 5002)
```

Two separate connections: video must be allowed to drop frames, input must never lose events.

## Building for two architectures

- One Swift package, shared code in `Shared/`; nothing architecture-specific in the code (use fixed-size integer types and explicit little-endian encoding in the protocol).
- **Host** builds natively on the MacBook (`arm64`). **Client** builds natively on the iMac (`x86_64`) via SSH (`git pull && swift build`). This avoids cross-compiling and guarantees the client links against the iMac's own SDK and macOS.
- Deployment target: the lower of the two macOS versions (at least macOS 13). `swift-tools-version` in `Package.swift` must be supported by the **older** Xcode/Swift of the two machines.
- Fallback if building on the iMac is awkward: build the client on the MacBook with `swift build --arch x86_64` (or `--arch arm64 --arch x86_64` for a universal binary with Xcode) and copy it over the link.
- If the host is later used on a second MacBook Pro that is Intel, build the host universal (`arm64` + `x86_64`).

## Phase 0: baseline check (30 min)

- Set up the direct Ethernet link with static IPs `10.77.0.1` / `10.77.0.2` (see `imac-mbp-agentic-build-plan.md`).
- Test with `iperf3` and `ping` over the link. Target: ~900+ Mbps, sub-millisecond ping, no loss.
- Compare with macOS Screen Sharing (Standard mode) to have a latency reference.
- Note `uname -m` and macOS/Xcode/Swift versions on both machines.

## Phase 1: video pipeline, host to client (the core)

**Host (Apple silicon)**
1. Request Screen Recording permission.
2. `SCShareableContent` -> pick the main display -> `SCContentFilter`.
3. `SCStreamConfiguration`:
   - `width/height`: iMac display size or MacBook point resolution (not full Retina pixels)
   - `minimumFrameInterval = CMTime(1, 30)`
   - `queueDepth = 3`
   - `showsCursor = false` (the client draws the cursor, see Phase 3)
   - `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
4. `VTCompressionSession` (hardware media engine; require it with `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`):
   - codec `kCMVideoCodecType_H264` (HEVC is an option to evaluate in M9)
   - `RealTime = true`, `AllowFrameReordering = false`
   - `AverageBitRate` ~ 25-40 Mbps (the cable has headroom; the limit is decoder load on the Intel iMac, tuned in M9), `DataRateLimits` ~ 1.5x
   - `MaxKeyFrameInterval` = 60, `ProfileLevel` = High auto
5. In the encoder callback: convert to Annex B (SPS/PPS before each keyframe), frame with a length prefix plus timestamp, write to the socket.
6. Backpressure: if the socket send queue is full, drop the frame and force a keyframe at the next opportunity. Never queue.

**Client (Intel iMac)**
1. `NWListener`/`NWConnection` (or host connects to a fixed client IP, simpler).
2. Parse the stream, build `CMSampleBuffer` from NAL units (`CMVideoFormatDescriptionCreateFromH264ParameterSets`).
3. Enqueue directly on `AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_DisplayImmediately = true`. No separate decoder needed; decoding uses the iMac's hardware decoder.
4. Full-screen borderless window, aspect-fit.

**Milestone:** MacBook screen visible on iMac, no input yet.

## Phase 2: input, client to host

**Client**
- Subclass `NSView`, `acceptsFirstResponder = true`, override `mouseMoved`, `mouseDown/Up`, `rightMouse*`, `otherMouse*`, `scrollWheel`, `keyDown/Up`, `flagsChanged`.
- Normalize pointer position to 0...1 in the video rect.
- Send small binary messages: `type (1B) | flags (4B) | keycode or button (2B) | x,y (2x Float32) | scroll dx,dy`, all little-endian.
- Send **hardware keycodes** (`event.keyCode`), not characters, so layouts don't matter.

**Host**
- Request Accessibility permission (`AXIsProcessTrustedWithOptions`).
- Map messages to `CGEvent`:
  - mouse: `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)`
  - keys: `CGEvent(keyboardEventSource:virtualKey:keyDown:)` + flags
  - scroll: `CGEvent(scrollWheelEvent2Source:...)`
- Post with `event.post(tap: .cghidEventTap)`.
- Scale normalized coordinates to the host display bounds.

**Milestone:** typing and clicking on the iMac controls the MacBook.

## Phase 3: polish

- **Cursor:** host sends cursor position and shape; client draws it locally as an overlay for zero-lag feel. Hide the iMac's own cursor over the view.
- **System shortcuts:** `CGEventTap` on the client (Accessibility permission) to capture Cmd-Tab, Cmd-Space, etc. while the window is focused and forward them instead of letting the iMac handle them.
- **Escape hatch:** a reserved key combo (e.g. Ctrl-Option-Cmd-Q) that releases capture and quits the client.
- **Clipboard sync:** poll `NSPasteboard.changeCount` on both sides, send text over the input channel.
- **Reconnect:** only with `--allow-reconnect` (a missed heartbeat otherwise stops everything, see the agentic plan); client requests a keyframe on connect.
- **Menu bar status item** on both sides: connected / disconnected, quit.

## Phase 4: tuning (wired link)

The network is no longer the bottleneck; encode on Apple silicon is cheap, so the **decoder and display path on the Intel iMac** and the buffers are the likely limits. If latency or stutter is noticeable:
- Set `TCP_NODELAY`; shrink `SO_SNDBUF` so backpressure is detected early, and drop frames instead of queueing.
- Adjust bitrate and resolution against decode time on the iMac (check the stats from the debug channel).
- Compare H.264 and HEVC: HEVC halves the bitrate for the same quality, but only helps if the iMac decodes it at least as fast.
- Review the frame rate cap (30 fps); try 60 if the iMac decoder keeps up.
- Shorter keyframe interval (30) if the client needs faster recovery after a dropped frame.
- Keep `queueDepth = 3` and no B-frames.

## Expected latency

Roughly 40-80 ms end to end on the wired link; measured properly in M4 and tuned in M9.

## Permissions checklist

| Machine | Permission |
|---------|------------|
| MacBook (Host) | Screen Recording, Accessibility |
| iMac (Client) | Accessibility (only if using the global `CGEventTap`) |

Unsigned local builds: allow in System Settings > Privacy & Security; re-grant permissions after rebuilds if the signature changes (use a stable development signing identity, the same certificate on both Macs).

## Project layout

```
RemoteMirror/
  Package.swift  (swift-tools-version supported by the older toolchain)
  Shared/      Protocol.swift (message types), Framing.swift
  Host/        Capture.swift, Encoder.swift, VideoServer.swift, InputInjector.swift, main.swift   (built on arm64)
  Client/      VideoClient.swift, DisplayView.swift, InputCapture.swift, main.swift              (built on x86_64)
```

## Suggested prompts for building it with Claude Code, in order

1. "Create the Swift package skeleton with Host and Client targets and the shared protocol; make sure it builds on arm64 (MacBook) and x86_64 (iMac)."
2. "Implement Host capture + H.264 hardware encode + TCP send (Phase 1 host)."
3. "Implement Client receive + AVSampleBufferDisplayLayer (Phase 1 client)."
4. "Add input capture and injection (Phase 2)."
5. Then Phase 3 items one at a time, then Phase 4 only if needed.

## Known risks

- Screen Recording permission re-prompts on macOS versions that periodically re-confirm it.
- Secure input fields (password prompts) and the login window can't be controlled via `CGEvent`.
- **Mixed architectures and macOS versions:** the iMac may run an older macOS and Xcode than the MacBook; APIs used by the client must exist on the iMac's macOS, and the package must build with the iMac's Swift toolchain. Preflight checks both.
- Decode load on the Intel iMac at high resolution or 60 fps; measure decode time before raising either.
- Security is handled from M1 in the agentic plan (link-only binding, peer pinning, TLS-PSK, handshake); there is no "add it later" step.
