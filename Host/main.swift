import AppKit
import CoreMedia
import Foundation
import Shared

// RemoteMirrorHost: runs on the MacBook (arm64).
//
//   --emit-vectors                 print protocol test vectors (M1 cross-machine check)
//   --video-caps                   print hardware codec support as JSON
//   --check-permissions            print Screen Recording / Accessibility status as JSON lines
//   --request-permissions          show the system permission prompts, then print status
//   --encoder-test                 encode synthetic frames (no permissions needed)
//   --capture-test                 capture the main display + encode (M2 acceptance test)
//     --duration <s>  (10)  --fps <n> (30)  --bitrate <Mbps> (20)  --hevc
//     --stats         print a JSON stats line every second
//     --no-pattern    don't open the animated test-pattern window (capture-test)

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String, _ def: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return def }
    return v
}

if flag("--emit-vectors") { print(TestVectors.emit()); exit(0) }
if flag("--video-caps") { print(VideoCapabilities.json()); exit(0) }
if flag("--check-permissions") { HostPermissions.report().forEach { print($0) }; exit(0) }
if flag("--request-permissions") {
    HostPermissions.request()
    HostPermissions.report().forEach { print($0) }
    exit(0)
}

let duration = value("--duration", 10)
let fps = Int32(value("--fps", 30))
let bitrate = Int(value("--bitrate", 20) * 1_000_000)
let codec = flag("--hevc") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
let codecName = flag("--hevc") ? "hevc" : "h264"
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

print(BuildInfo.banner("RemoteMirrorHost"))
