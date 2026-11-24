import AppKit
import ApplicationServices
import Foundation
import Network
import Shared

// RemoteMirrorClient: runs on the iMac (x86_64).
//
//   --verify-vectors        check protocol vectors from the host (stdin)
//   --video-caps            hardware codec support as JSON
//   (no test flags)         waiting mode: idle window, mirror whenever the MacBook shares (M11)
//   --duration <s>          one session, quit after N seconds (test mode)
//   --once                  one session, quit when it ends
//   --stats                 JSON stats line every second
//   --dump-frame <path>     write the last displayed frame as PNG on exit
//   --windowed              960x600 window instead of full screen
//   --hevc                  force HEVC parsing (normally taken from each frame's flags)
//   --min-fps <n>           exit 1 if average displayed fps is below n (with --duration)
//   --marker <x,y,pitch>    read the M4 latency marker (cell centres in frame pixels) and echo it
//   --type-text <s>         after connecting, type this text on the host (M5 test)
//   --no-input              don't open the input connection
//   --allow-reconnect       on a drop, keep retrying for 30 s instead of quitting
//   --no-tap                don't capture system shortcuts (Cmd-Tab...) with the event tap
//   --test-shortcuts        post Cmd-Tab + Cmd-Space on the iMac after connecting (M7 test)
//   --test-escape <s>       post Ctrl-Option-Cmd-Q after N seconds (M7 test)
//   --test-screenshot       post Ctrl-Cmd-Shift-4 on the iMac, then drag a selection (feedback item 5)
//   --record-gestures       log every input event incl. undocumented gesture events (diagnostic)
//   --test-swipe            post two Magic-Mouse-like phased swipes on the iMac (feedback: swipes)
//   --test-drag x0,y0,x1,y1 drag through the mouse path 3 s after connecting (normalized coords)
//   --test-pause            post Ctrl-Option-Cmd-Z twice (pause, resume) after connecting
//   --mouse-script <spec>   click/scroll host targets "nx,ny;..." (M6 test)
//   --host <ip> --key <path>

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains(n) }
func str(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func num(_ n: String) -> Double? { str(n).flatMap(Double.init) }

if flag("--video-caps") { print(VideoCapabilities.json()); exit(0) }
if flag("--check-permissions") || flag("--request-permissions") {
    if flag("--request-permissions") {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
        // Touch the link address once so macOS shows the Local Network prompt.
        let c = NWConnection(host: NWEndpoint.Host(WireProtocol.hostAddress), port: 5001, using: .tcp)
        c.start(queue: .main)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        c.cancel()
    }
    print("{\"permission\":\"accessibility\",\"status\":\"\(AXIsProcessTrusted() ? "granted" : "denied")\"}")
    exit(0)
}
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
if num("--duration") == nil && !flag("--once") { FileLog.captureStdout(name: "iMac") }
print(BuildInfo.banner("RemoteMirrorClient"))

let key: Data
do { key = try LinkSecurity.loadKey(path: str("--key") ?? LinkSecurity.defaultKeyPath) } catch {
    print("FAIL: \(error)"); exit(1)
}

/// Waiting mode: the app stays up, shows "Waiting for MacBook" and mirrors whenever
/// the MacBook starts sharing. Test runs (--duration / --once) do one session and exit.
let waitingMode = num("--duration") == nil && !flag("--once")
let hostAddress = str("--host") ?? WireProtocol.hostAddress

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var stats = ClientStats()
let display = DisplayWindow(windowed: flag("--windowed"))
let idle = IdleWindow()
let hevc = flag("--hevc")
let status = StatusItem(title: "iMac ← MacBook")
status.onChange = { st in print("{\"event\":\"status\",\"state\":\"\(st.rawValue)\"}") }
let tap = ShortcutTap()
tap.isActive = { NSApp.isActive && display.window.isKeyWindow }

// Per-session objects (recreated for every session in waiting mode).
var client = VideoClient(key: key, host: hostAddress)
var inputClient: VideoClient? = nil
var decoder = VideoDecoder { _, _, _ in }
var keyframeRequested = false
var awaitingFirstFrame = true
var firstReady = true
var paused = false
var sessionActive = false
var sessions = 0
/// Keeps the iMac and its display awake while it shows the MacBook.
let power = PowerAssertion()

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

func makeDecoder() -> VideoDecoder {
    let d = VideoDecoder { pb, _, nanos in
        stats.frameDecoded(nanos: nanos)
        let marker = readMarker(pb)
        DispatchQueue.main.async {
            display.display(pb); stats.frameDisplayed()
            // Echo after the frame is handed to the display layer.
            if let marker, marker != lastMarker { lastMarker = marker; client.sendLatencyEcho(marker) }
            else if marker == nil && markerSpec != nil { markerMisses += 1 }
        }
    }
    d.onError = { e in stats.decodeError(); print("{\"event\":\"decode_error\",\"error\":\"\(e)\"}") }
    return d
}

/// Test runs: print the summary and exit.
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
    tap.stop()
    print("{\"event\":\"shortcuts\",\"forwarded\":\(tap.forwarded)}")
    print("{\"event\":\"cursor\",\"updates\":\(display.cursorUpdates),\"shape\":\(display.cursorLayer.contents != nil)}")
    if markerSpec != nil { print("{\"event\":\"marker_misses\",\"count\":\(markerMisses)}") }
    print("{\"event\":\"exit\",\"reason\":\"\(reason)\",\"hardware_decode\":\(decoder.usingHardware)}")
    if code == 0 && num("--min-fps") != nil { print("PASS") }
    exit(code)
}

/// A session ended (host stopped, cable pulled, escape hatch...). Test runs exit;
/// waiting mode goes back to the idle window and waits for the next session.
func sessionEnded(code: Int32, reason: String) {
    guard waitingMode else { finish(code: code, reason: reason) }
    guard sessionActive else { return }   // video and input both report the end; handle once
    sessionActive = false
    power.release()
    client.onClosed = nil; inputClient?.onClosed = nil
    inputClient?.disconnect(.normal)
    client.disconnect(.normal)
    paused = false
    display.close()
    print("{\"event\":\"session_ended\",\"reason\":\"\(reason)\",\"display_fps\":\(String(format: "%.1f", stats.summary().displayFps))}")
    idle.setDetail(reason)
    goIdle()
}

func goIdle() {
    status.set(.waiting)
    NSApp.activate(ignoringOtherApps: true)
    idle.show()
    print("{\"event\":\"idle\",\"idle_window\":\(idle.isVisible),\"mirror_visible\":\(display.window.isVisible)}")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startSession() }
}

/// Creates fresh connections and waits (quietly, forever in waiting mode) for the host.
func startSession() {
    stats = ClientStats()
    decoder = makeDecoder()
    keyframeRequested = false; awaitingFirstFrame = true; firstReady = true
    client = VideoClient(key: key, host: hostAddress)
    inputClient = flag("--no-input") ? nil : VideoClient(key: key, host: hostAddress, port: WireProtocol.inputPort)
    if waitingMode { client.waitForever = true; client.retryInterval = 1 }
    let allowReconnect = flag("--allow-reconnect")
    client.allowReconnect = allowReconnect
    inputClient?.allowReconnect = allowReconnect
    client.log = { line in if !waitingMode || !line.contains("connect_retry") { print(line) } }

    client.onFrame = { f in
        stats.frameReceived(bytes: f.payload.count)
        if awaitingFirstFrame {
            awaitingFirstFrame = false
            print(String(format: "{\"event\":\"first_frame\",\"keyframe\":%@,\"ms_after_connect\":%.0f}",
                         f.isKeyframe ? "true" : "false", Date().timeIntervalSince(client.connectedAt) * 1000))
        }
        if !decoder.decode(annexB: f.payload, ptsNanos: f.ptsNanos, hevc: hevc || f.isHEVC) {
            if !keyframeRequested { keyframeRequested = true; client.requestKeyframe() }
        } else if f.isKeyframe { keyframeRequested = false }
    }
    client.onReady = { DispatchQueue.main.async {
        status.set(paused ? .paused : .connected)
        guard firstReady else { return }      // reconnects: window, input and tap already set up
        firstReady = false
        sessionActive = true
        sessions += 1
        power.hold(reason: "RemoteMirror: showing the MacBook", system: true)
        idle.hide()
        if !paused { display.show() }
        print("{\"event\":\"session_started\",\"n\":\(sessions),\"mirror_visible\":\(display.window.isVisible)}")
        inputClient?.connect()
        if !flag("--no-tap") && inputClient != nil && !tap.isRunning {
            let ok = tap.start()
            print("{\"event\":\"shortcut_tap\",\"running\":\(ok)}")
        }
    } }
    client.onReconnecting = { _ in awaitingFirstFrame = true; status.set(.reconnecting) }
    client.onCursor = { x, y, v in DispatchQueue.main.async { display.hostCursor(x, y, visible: v) } }
    client.onCursorShape = { c in DispatchQueue.main.async { display.setCursorShape(c) } }
    inputClient?.onReady = { runTestScripts() }
    let failCode: Int32 = num("--duration") == nil ? 0 : 1
    inputClient?.onClosed = { reason in DispatchQueue.main.async { sessionEnded(code: failCode, reason: "input: \(reason)") } }
    client.onClosed = { reason in DispatchQueue.main.async { sessionEnded(code: failCode, reason: reason) } }
    client.connect()
}

display.inputView.onEvent = { e in inputClient?.send(e) }
tap.onEvent = { e in inputClient?.send(e) }

// Escape hatch: Ctrl-Option-Cmd-Q always ends the session from the iMac side
// (test runs exit; waiting mode returns to the idle window).
func escapeHatch() {
    guard sessionActive || !waitingMode else { return }
    print("{\"event\":\"escape_hatch\"}")
    client.onClosed = nil; inputClient?.onClosed = nil
    inputClient?.disconnect(.escapeHatch)
    client.disconnect(.escapeHatch) { DispatchQueue.main.async {
        if waitingMode { sessionEnded(code: 0, reason: "escape hatch") }
        else { finish(code: 0, reason: "escape hatch") }
    } }
}
// Pause: Ctrl-Option-Cmd-Z hides the mirror (iMac usable), pressing it again brings it back.
func togglePause() {
    guard sessionActive || !waitingMode else { return }
    paused.toggle()
    if paused {
        // The combo's modifiers were already forwarded: clear them on the host.
        inputClient?.send(InputEvent(kind: .flagsChanged, flags: 0, code: 0x37))
        display.hide()
    } else {
        display.show()
        client.requestKeyframe()
    }
    status.set(paused ? .paused : .connected)
    print("{\"event\":\"\(paused ? "paused" : "resumed")\"}")
}
display.inputView.onPauseToggle = togglePause
tap.onPauseToggle = { DispatchQueue.main.async { togglePause() } }
display.inputView.onEscape = escapeHatch
tap.onEscape = { DispatchQueue.main.async { escapeHatch() } }
func quitApp() {
    print("{\"event\":\"quit\"}")
    client.onClosed = nil; inputClient?.onClosed = nil
    inputClient?.disconnect(.normal)
    client.disconnect(.normal) { DispatchQueue.main.async { tap.stop(); display.close(); exit(0) } }
}
status.onQuit = { waitingMode ? quitApp() : escapeHatch() }

/// Standard app menu so ⌘Q and the window's close button behave like a normal Mac app.
final class AppActions: NSObject, NSWindowDelegate {
    @objc func quit(_ sender: Any?) { waitingMode ? quitApp() : escapeHatch() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { quitApp(); return false }
}
let appActions = AppActions()
do {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    let quitItem = NSMenuItem(title: "Quit RemoteMirror", action: #selector(AppActions.quit(_:)), keyEquivalent: "q")
    quitItem.target = appActions
    appMenu.addItem(quitItem)
    appItem.submenu = appMenu
    NSApp.mainMenu = main
    idle.window.delegate = appActions
}

/// M6: scripted clicks through the same view <-> video mapping as real mouse events.
func runMouseScript(_ spec: String) {
    let pts = spec.split(separator: ";").compactMap { pair -> (Double, Double)? in
        let p = pair.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
    let v = display.inputView!
    var steps: [InputEvent] = []
    func at(_ i: Int) -> (Float32, Float32) { v.normalize(v.viewPoint(nx: pts[i].0, ny: pts[i].1)) }
    func click(_ i: Int, button: Int = 0, clicks: Int = 1) {
        let (x, y) = at(i)
        steps.append(InputEvent(kind: .mouseDown, code: InputView.mouseCode(button: button, clicks: clicks), x: x, y: y))
        steps.append(InputEvent(kind: .mouseUp, code: InputView.mouseCode(button: button, clicks: clicks), x: x, y: y))
    }
    for i in pts.indices {
        let (x, y) = at(i)
        steps.append(InputEvent(kind: .mouseMove, x: x, y: y))
        click(i)
        if i == 1 { click(i, clicks: 2) }          // double click
        if i == 0 { click(i, button: 1) }          // right click
    }
    if pts.count > 2 {
        let (x, y) = at(2)
        steps.append(InputEvent(kind: .mouseMove, x: x, y: y))
        for _ in 0..<5 { steps.append(InputEvent(kind: .scroll, code: 1, x: x, y: y, dx: 0, dy: -30)) }
    }
    for (i, e) in steps.enumerated() {
        // Double-click halves must be close together; everything else is spaced out.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) { inputClient?.send(e) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps.count) * 0.08 + 0.2) {
        print("{\"event\":\"mouse_script\",\"events\":\(steps.count)}")
    }
}

/// M-feedback item 5: screenshot shortcut on the iMac keyboard, then a drag through the
/// normal mouse path (normalized video coords).
func runScreenshotTest() {
    ShortcutTap.postScreenshotShortcut()
    print("{\"event\":\"screenshot_shortcut_posted\"}")
    let v = display.inputView!
    func at(_ x: Double, _ y: Double) -> (Float32, Float32) { v.normalize(v.viewPoint(nx: x, ny: y)) }
    var steps: [InputEvent] = []
    let (ax, ay) = at(0.40, 0.30), (bx, by) = at(0.47, 0.38)
    steps.append(InputEvent(kind: .mouseMove, x: ax - 0.005, y: ay))
    steps.append(InputEvent(kind: .mouseMove, x: ax, y: ay))
    steps.append(InputEvent(kind: .mouseDown, code: InputView.mouseCode(button: 0, clicks: 1), x: ax, y: ay))
    for i in 1...10 {
        let f = Float32(i) / 10
        steps.append(InputEvent(kind: .mouseMove, x: ax + (bx - ax) * f, y: ay + (by - ay) * f))
    }
    steps.append(InputEvent(kind: .mouseUp, code: InputView.mouseCode(button: 0, clicks: 1), x: bx, y: by))
    for (i, e) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.05) { inputClient?.send(e) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(steps.count) * 0.05 + 0.2) {
        print("{\"event\":\"screenshot_drag_sent\",\"events\":\(steps.count)}")
    }
}

/// Drags from (x0,y0) to (x1,y1) in normalized video coordinates through the normal mouse path.
func runTestDrag(_ spec: String) {
    let p = spec.split(separator: ",").compactMap { Double($0) }
    guard p.count == 4 else { print("FAIL: --test-drag x0,y0,x1,y1"); return }
    let v = display.inputView!
    func at(_ x: Double, _ y: Double) -> (Float32, Float32) { v.normalize(v.viewPoint(nx: x, ny: y)) }
    let (ax, ay) = at(p[0], p[1]), (bx, by) = at(p[2], p[3])
    var steps = [InputEvent(kind: .mouseMove, x: ax - 0.002, y: ay), InputEvent(kind: .mouseMove, x: ax, y: ay),
                 InputEvent(kind: .mouseDown, code: InputView.mouseCode(button: 0, clicks: 1), x: ax, y: ay)]
    for i in 1...20 { let f = Float32(i) / 20; steps.append(InputEvent(kind: .mouseMove, x: ax + (bx - ax) * f, y: ay + (by - ay) * f)) }
    steps.append(InputEvent(kind: .mouseUp, code: InputView.mouseCode(button: 0, clicks: 1), x: bx, y: by))
    for (i, e) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.03) { inputClient?.send(e) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps.count) * 0.03 + 0.2) {
        print("{\"event\":\"test_drag_sent\",\"events\":\(steps.count)}")
    }
}

func runTestScripts() {
    if flag("--test-click") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { DispatchQueue.global().async { ShortcutTap.postTestClick() } }
    }
    if flag("--test-scroll-variants") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            DispatchQueue.global().async { ShortcutTap.postScrollVariants(); DispatchQueue.main.async { print("{\"event\":\"scroll_variants_posted\"}") } }
        }
    }
    if flag("--test-swipe") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            DispatchQueue.global().async {
                ShortcutTap.postSyntheticSwipe(right: true)
                usleep(800_000)
                ShortcutTap.postSyntheticSwipe(right: false)
                DispatchQueue.main.async { print("{\"event\":\"test_swipe_posted\"}") }
            }
        }
    }
    if let spec = str("--test-drag") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { runTestDrag(spec) }
    }
    if flag("--test-screenshot") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runScreenshotTest() }
    }
    if flag("--test-shortcuts") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ShortcutTap.postTestShortcuts() }
    }
    if flag("--test-pause") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ShortcutTap.postPause() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print("{\"event\":\"pause_check\",\"window_visible\":\(display.window.isVisible)}")
            ShortcutTap.postPause()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            print("{\"event\":\"resume_check\",\"window_visible\":\(display.window.isVisible)}")
        }
    }
    if let d = num("--test-escape") {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { ShortcutTap.postEscape() }
    }
    if let spec = str("--mouse-script") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { runMouseScript(spec) }
    }
    guard let text = str("--type-text") else { return }
    guard let events = KeyScript.events(for: text) else { print("FAIL: unsupported character in --type-text"); return }
    // Give the host's test window a moment to take focus, then type at ~30 keys/s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        for (i, e) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.015) { inputClient?.send(e) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(events.count) * 0.015 + 0.2) {
            print("{\"event\":\"typed\",\"events\":\(events.count)}")
        }
    }
}

let gestureRecorder = GestureRecorder()
if flag("--record-gestures") {
    print("{\"event\":\"recorder\",\"running\":\(gestureRecorder.start())}")
}

if flag("--log-scroll") {
    // Diagnostic: does the app get scroll events at all, and which window do they target?
    NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { e in
        print(String(format: "{\"event\":\"app_scroll\",\"window\":\"%@\",\"key\":%@,\"dx\":%.2f}",
                     e.window?.title ?? "nil", (e.window?.isKeyWindow ?? false) ? "true" : "false", e.scrollingDeltaX))
        return e
    }
    NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { e in
        print(String(format: "{\"event\":\"other_app_scroll\",\"dx\":%.2f,\"frontmost\":\"%@\"}",
                     e.scrollingDeltaX, NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))
    }
}

if flag("--stats") {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in print(stats.intervalJSON(seconds: 1)) }
}
if let d = num("--duration") {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
        client.onClosed = nil; inputClient?.onClosed = nil
        inputClient?.disconnect(.normal)
        client.disconnect(.normal) { DispatchQueue.main.async { finish(code: 0, reason: "duration elapsed") } }
    }
}
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    if waitingMode { quitApp() }
    else { client.onClosed = nil; inputClient?.onClosed = nil; inputClient?.disconnect(.normal); client.disconnect(.normal) { DispatchQueue.main.async { finish(code: 0, reason: "SIGTERM") } } }
}
sigterm.resume()

if waitingMode { goIdle() } else { startSession() }
app.run()
