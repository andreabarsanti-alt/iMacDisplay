import AppKit
import CoreMedia
import Foundation
import Shared
import HostCore

// RemoteMirrorHost: runs on the MacBook (arm64).
//
//   --emit-vectors                 print protocol test vectors (M1 cross-machine check)
//   --video-caps                   print hardware codec support as JSON
//   --check-permissions            print Screen Recording / Accessibility status as JSON lines
//   --request-permissions          show the system permission prompts, then print status
//   --encoder-test                 encode synthetic frames (no permissions needed)
//   --capture-test                 capture the main display + encode (M2 acceptance test)
//     --duration <s>  (10)  --fps <n> (60)  --bitrate <Mbps> (12)  --h264 (default HEVC)
//     --stats         print a JSON stats line every second
//     --no-pattern    don't open the animated test-pattern window (capture-test)
//   --compare <a.png> <b.png>      print image similarity 0...1
//   --gen-key                      create ~/.imacdisplay/psk if missing (then scripts/install-key.sh)
//   --serve                        listen on 10.77.0.1:5001 (TLS-PSK) and stream the screen to the iMac
//     --synthetic     stream generated frames instead of the screen (no permission needed)
//     --duration <s>  stop after N seconds (default: until the client disconnects)
//     --pattern       also show the animated test-pattern window
//     --points        capture at point size instead of native Retina pixels
//     --video-cursor  draw the cursor into the video instead of the client overlay
//     --latency       show the M4 latency marker; print median/p95 on exit
//     --view-only     don't inject keyboard/mouse events from the iMac
//     --display auto|builtin|external   which display to share (default auto)
//     --no-fit        don't switch an external display to 16:9 for the iMac
//     --test-resize-after <s>  switch capture size mid-session (M13 test)
//     --log-input     print every input event received (JSON)
//     --allow-reconnect  keep listening when the client drops (escape hatch still stops)
//     --dead-man <s>  stop injecting input after N seconds (tests)
//     --input-test    show a focused text field; print its content on exit
//     --expect-text <s>  with --input-test: PASS only if the field equals this
//     --mouse-test    show click targets; check the client's scripted clicks/scroll on exit
//     --mouse-spec-out <path>  write target positions for the client
//     --marker-spec-out <path>  write the marker position for the client
//     --allow-peer <ip>  override the pinned client address (tests only)

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String, _ def: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return def }
    return v
}

if flag("--emit-vectors") { print(TestVectors.emit()); exit(0) }
if flag("--video-caps") { print(VideoCapabilities.json()); exit(0) }
if flag("--check-permissions") { HostPermissions.report().forEach { print($0) }; exit(0) }
if let i = args.firstIndex(of: "--compare"), i + 2 < args.count {
    guard let sim = ImageCompare.similarity(args[i + 1], args[i + 2]) else { print("FAIL: cannot read images"); exit(1) }
    print(String(format: "{\"similarity\":%.4f}", sim)); exit(0)
}
if flag("--gen-key") {
    do { print("key: \(try LinkSecurity.generateKey())"); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
}
if flag("--request-permissions") {
    HostPermissions.request()
    HostPermissions.report().forEach { print($0) }
    exit(0)
}

let duration = value("--duration", 10)
// Defaults from M9 tuning (docs/tuning.md): HEVC, 60 fps, 12 Mbps.
let fps = Int32(value("--fps", 60))
let bitrate = Int(value("--bitrate", 12) * 1_000_000)
let useHEVC = !flag("--h264")
let codec = useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
let codecName = useHEVC ? "hevc" : "h264"
let printStats = flag("--stats")

/// Pass/fail criteria shared by both tests (plan M2): >= 25 fps, hardware, bytes > 0, no errors.
func finish(_ stats: HostStats, encoder: VideoEncoder?, extra: [(String, String)]) -> Never {
    let hw = encoder?.usingHardware ?? false
    let s = stats.summary(extra: extra + [("hardware", "\(hw)"), ("codec", "\"\(codecName)\"")])
    print(s.json)
    var failures: [String] = []
    if s.encodeFps < 25 { failures.append(String(format: "average encode fps %.1f < 25", s.encodeFps)) }
    if !hw { failures.append("encoder is not hardware accelerated") }
    if s.bytes == 0 { failures.append("no encoded bytes") }
    failures += s.errors
    if failures.isEmpty { print("PASS"); exit(0) }
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}

func startStatsTimer(_ stats: HostStats) {
    guard printStats else { return }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in print(stats.intervalJSON(seconds: 1)) }
}

if flag("--encoder-test") {
    // Synthetic NV12 frames with moving content; exercises the hardware encoder without capture.
    let w = 1440, h = 900
    let stats = HostStats()
    let encoder: VideoEncoder
    do {
        encoder = try VideoEncoder(width: Int32(w), height: Int32(h), fps: fps, bitrate: bitrate, codec: codec) { out in
            stats.frameEncoded(bytes: out.annexB.count, keyframe: out.isKeyframe, encodeNanos: out.encodeNanos)
        }
    } catch {
        print("FAIL: \(error)"); exit(1)
    }
    var pool: CVPixelBufferPool?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    var n: Int64 = 0
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "synthetic"))
    timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
    timer.setEventHandler {
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else {
            stats.error("pixel buffer allocation failed"); return
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        // Horizontal bands that scroll every frame: cheap to generate, never static.
        for row in 0..<h { memset(y + row * stride, Int32(truncatingIfNeeded: (row / 8 + Int(n) * 3) & 0xff), w) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(pb, [])
        stats.frameCaptured()
        encoder.encode(pb, pts: CMTime(value: n, timescale: fps))
        n += 1
    }
    timer.resume()
    startStatsTimer(stats)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        timer.cancel()
        encoder.invalidate()
        finish(stats, encoder: encoder, extra: [("mode", "\"encoder-test\""), ("width", "\(w)"), ("height", "\(h)")])
    }
    RunLoop.main.run()
}

if flag("--capture-test") {
    guard HostPermissions.screenRecording() else {
        print("{\"event\":\"error\",\"reason\":\"screen_recording_denied\"}")
        print("FAIL: Screen Recording permission not granted (Gate 2)")
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let stats = HostStats()
    var encoder: VideoEncoder?
    let pattern = flag("--no-pattern") ? nil : TestPatternWindow()
    let capturer = ScreenCapturer(
        onFrame: { pb, pts in
            stats.frameCaptured()
            if let encoder { encoder.encode(pb, pts: pts) } else { stats.frameDropped() }
        },
        onError: { stats.error($0) })

    Task { @MainActor in
        pattern?.show()
        do {
            try await capturer.start(fps: fps)
            encoder = try VideoEncoder(width: Int32(capturer.width), height: Int32(capturer.height),
                                       fps: fps, bitrate: bitrate, codec: codec) { out in
                stats.frameEncoded(bytes: out.annexB.count, keyframe: out.isKeyframe, encodeNanos: out.encodeNanos)
            }
        } catch {
            print("FAIL: \(error.localizedDescription)"); exit(1)
        }
        startStatsTimer(stats)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
        await capturer.stop()
        encoder?.invalidate()
        pattern?.close()
        finish(stats, encoder: encoder, extra: [("mode", "\"capture-test\""),
                                                ("width", "\(capturer.width)"), ("height", "\(capturer.height)")])
    }
    app.run()
}

if flag("--serve") {
    setvbuf(stdout, nil, _IOLBF, 0)
    print(BuildInfo.banner("RemoteMirrorHost"))
    let key: Data
    do { key = try LinkSecurity.loadKey() } catch { print("FAIL: \(error)"); exit(1) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    var cfg = HostSession.Config(key: key)
    cfg.fps = fps; cfg.bitrate = bitrate; cfg.codec = codec
    cfg.synthetic = flag("--synthetic")
    cfg.nativePixels = !flag("--points")
    cfg.videoCursor = flag("--video-cursor")
    cfg.viewOnly = flag("--view-only")
    cfg.allowReconnect = flag("--allow-reconnect")
    cfg.deadManSeconds = args.firstIndex(of: "--dead-man").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil }
    if let i = args.firstIndex(of: "--allow-peer"), i + 1 < args.count { cfg.allowedPeer = args[i + 1] }
    if let i = args.firstIndex(of: "--bind"), i + 1 < args.count { cfg.bindHost = args[i + 1] }
    if let i = args.firstIndex(of: "--simulate-missing"), i + 1 < args.count { cfg.simulateMissingPermission = args[i + 1] }
    if let i = args.firstIndex(of: "--display"), i + 1 < args.count {
        cfg.displayChoice = ["builtin": .builtin, "external": .external][args[i + 1]] ?? .automatic
    }
    cfg.fitExternalForIMac = !flag("--no-fit")
    let session = HostSession(config: cfg)

    // Test windows and hooks (CLI only).
    let pattern = flag("--pattern") ? TestPatternWindow() : nil
    let marker = flag("--latency") ? LatencyMarkerWindow() : nil
    let inputTest = flag("--input-test") ? InputTestWindow() : nil
    let mouseTest = flag("--mouse-test") ? MouseTestWindow() : nil
    let latency = LatencyStats()
    let status = StatusItem(title: "MacBook → iMac")
    session.onLatencyEcho = { v in
        guard let t = marker?.drawTime(v) else { return }
        latency.add(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }
    if flag("--log-input") {
        session.onInputEvent = { e in print("{\"event\":\"input_event\",\"kind\":\(e.kind.rawValue),\"code\":\(e.code),\"flags\":\(e.flags)}") }
    }
    if !cfg.viewOnly && !HostPermissions.accessibility() {
        print("{\"event\":\"warning\",\"reason\":\"accessibility_denied\"}")
    }

    func report(code: Int32) -> Never {
        let enc = session.encoder
        print(session.stats.summary(extra: [("mode", "\"serve\""), ("hardware", "\(enc?.usingHardware ?? false)")]).json)
        var code = code
        if marker != nil {
            let l = latency.summary()
            print(l.json)
            let minSamples = Int(value("--min-samples", 300))
            if l.count < minSamples { print("FAIL: only \(l.count) latency samples (< \(minSamples))"); code = 1 }
            else { print("PASS") }
        }
        print("{\"event\":\"input\",\"injected\":\(session.injector.injectedCount),\"trusted\":\(session.injector.isTrusted)}")
        if let inputTest {
            let got = inputTest.text
            let esc = got.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            print("{\"event\":\"input_test\",\"text\":\"\(esc)\"}")
            if let i = args.firstIndex(of: "--expect-text"), i + 1 < args.count {
                if got == args[i + 1] { print("PASS") } else { print("FAIL: field is \"\(got)\", expected \"\(args[i + 1])\""); code = 1 }
            }
            inputTest.close()
        }
        if let mouseTest {
            let r = mouseTest.evaluate()
            print(r.json)
            if r.failures.isEmpty { print("PASS") } else { r.failures.forEach { print("FAIL: \($0)") }; code = 1 }
            mouseTest.close()
        }
        exit(code)
    }
    func stopAll(_ why: String, code: Int32) {
        session.stop(reason: why) { report(code: code) }
    }
    // The session stops itself (client gone without reconnect, capture error...): exit then.
    session.onState = { st in
        switch st {
        case .waiting: status.set(.waiting)
        case .sharing: status.set(.connected)
        case .idle: status.set(.stopped); report(code: 0)
        case .error: status.set(.stopped); report(code: 1)
        default: break
        }
    }
    status.onQuit = { stopAll("quit from menu", code: 0) }
    status.onChange = { st in print("{\"event\":\"status\",\"state\":\"\(st.rawValue)\"}") }

    Task { @MainActor in
        pattern?.show()
        do {
            try await session.start()
        } catch {
            print("FAIL: \(error)"); exit(cfg.simulateMissingPermission != nil || "\(error)".contains("Screen Recording") ? 2 : 1)
        }
        if let marker {
            marker.show()
            let spec = marker.markerSpec(captureWidth: Int(session.width), captureHeight: Int(session.height))
            print("{\"event\":\"marker\",\"spec\":\"\(spec)\"}")
            if let i = args.firstIndex(of: "--marker-spec-out"), i + 1 < args.count {
                try? spec.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            }
        }
        inputTest?.show()
        if let mouseTest {
            mouseTest.show()
            if let i = args.firstIndex(of: "--mouse-spec-out"), i + 1 < args.count {
                try? mouseTest.spec.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            }
        }
    }
    if printStats { startStatsTimer(session.stats) }
    if let i = args.firstIndex(of: "--test-resize-after"), i + 1 < args.count, let d = Double(args[i + 1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { Task { @MainActor in await session.debugToggleCaptureSize() } }
    }
    if let i = args.firstIndex(of: "--duration"), i + 1 < args.count, let d = Double(args[i + 1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { stopAll("duration elapsed", code: 0) }
    }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let sigs = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { stopAll("signal \(sig)", code: 0) }
        src.resume()
        return src
    }
    _ = sigs
    app.run()
}

print(BuildInfo.banner("RemoteMirrorHost"))
