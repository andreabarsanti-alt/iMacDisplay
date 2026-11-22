import AppKit
import Foundation
import Shared

// RemoteMirrorClient: runs on the iMac (x86_64).
//
//   --verify-vectors        check protocol vectors from the host (stdin)
//   --video-caps            hardware codec support as JSON
//   --duration <s>          quit after N seconds (test mode); default: run until disconnected
//   --stats                 JSON stats line every second
//   --dump-frame <path>     write the last displayed frame as PNG on exit
//   --windowed              960x600 window instead of full screen
//   --hevc                  expect HEVC instead of H.264
//   --min-fps <n>           exit 1 if average displayed fps is below n (with --duration)
//   --marker <x,y,pitch>    read the M4 latency marker (cell centres in frame pixels) and echo it
//   --host <ip> --key <path>

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains(n) }
func str(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func num(_ n: String) -> Double? { str(n).flatMap(Double.init) }

if flag("--video-caps") { print(VideoCapabilities.json()); exit(0) }
if flag("--verify-vectors") {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let failures = TestVectors.verify(input)
    if failures.isEmpty {
        print("PASS: \(TestVectors.messages.count) vectors decoded identically on \(BuildInfo.architecture)")
        exit(0)
    }
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
print(BuildInfo.banner("RemoteMirrorClient"))

let key: Data
do { key = try LinkSecurity.loadKey(path: str("--key") ?? LinkSecurity.defaultKeyPath) } catch {
    print("FAIL: \(error)"); exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let stats = ClientStats()
let display = DisplayWindow(windowed: flag("--windowed"))
let hevc = flag("--hevc")
let client = VideoClient(key: key, host: str("--host") ?? WireProtocol.hostAddress)
var keyframeRequested = false
let markerSpec: (x: Double, y: Double, pitch: Double)? = str("--marker").flatMap { s in
    let p = s.split(separator: ",").compactMap { Double($0) }
    return p.count == 3 ? (p[0], p[1], p[2]) : nil
}
var lastMarker: UInt32?
var markerMisses = 0

/// Reads the marker from the luma plane of a decoded frame.
func readMarker(_ pb: CVPixelBuffer) -> UInt32? {
    guard let m = markerSpec else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let y = Int(m.y.rounded())
    guard y >= 0, y < h else { return nil }
    let row = base.assumingMemoryBound(to: UInt8.self) + y * stride
    return Marker.decode { i in
        let x = Int((m.x + Double(i) * m.pitch).rounded())
        return x >= 0 && x < w ? row[x] : 0
    }
}

let decoder = VideoDecoder { pb, _, nanos in
    stats.frameDecoded(nanos: nanos)
    let marker = readMarker(pb)
    DispatchQueue.main.async {
        display.display(pb); stats.frameDisplayed()
        // Echo after the frame is handed to the display layer.
        if let marker, marker != lastMarker { lastMarker = marker; client.sendLatencyEcho(marker) }
        else if marker == nil && markerSpec != nil { markerMisses += 1 }
    }
}
decoder.onError = { e in stats.decodeError(); print("{\"event\":\"decode_error\",\"error\":\"\(e)\"}") }

func finish(code: Int32, reason: String) -> Never {
    if let path = str("--dump-frame") {
        print(display.dumpFrame(to: path) ? "{\"event\":\"dumped\",\"path\":\"\(path)\"}"
                                          : "{\"event\":\"dump_failed\",\"reason\":\"no frame\"}")
    }
    display.close()
    let s = stats.summary()
    print(s.json)
    var code = code
    if let minFps = num("--min-fps"), s.displayFps < minFps {
        print(String(format: "FAIL: average display fps %.1f < %.0f", s.displayFps, minFps)); code = 1
    }
    if markerSpec != nil { print("{\"event\":\"marker_misses\",\"count\":\(markerMisses)}") }
    print("{\"event\":\"exit\",\"reason\":\"\(reason)\",\"hardware_decode\":\(decoder.usingHardware)}")
    if code == 0 && num("--min-fps") != nil { print("PASS") }
    exit(code)
}

client.onFrame = { f in
    stats.frameReceived(bytes: f.payload.count)
    if !decoder.decode(annexB: f.payload, ptsNanos: f.ptsNanos, hevc: hevc) {
        if !keyframeRequested { keyframeRequested = true; client.requestKeyframe() }
    } else if f.isKeyframe { keyframeRequested = false }
}
client.onReady = { DispatchQueue.main.async { display.show() } }
// Mutual kill: any disconnect ends the client (no auto-reconnect until M8's --allow-reconnect).
client.onClosed = { reason in DispatchQueue.main.async { finish(code: num("--duration") == nil ? 0 : 1, reason: reason) } }

if flag("--stats") {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in print(stats.intervalJSON(seconds: 1)) }
}
if let d = num("--duration") {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
        client.onClosed = nil
        client.disconnect(.normal) { DispatchQueue.main.async { finish(code: 0, reason: "duration elapsed") } }
    }
}
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { client.onClosed = nil; client.disconnect(.normal) { DispatchQueue.main.async { finish(code: 0, reason: "SIGTERM") } } }
sigterm.resume()

client.connect()
app.run()
