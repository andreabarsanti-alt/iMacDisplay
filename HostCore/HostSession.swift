import AppKit
import CoreMedia
import Foundation
import Shared

/// One sharing session on the MacBook: capture -> encode -> video server, input
/// server -> injector, cursor tracking. Used by the menu bar app and the CLI.
///
/// Start: check permissions and link, open listeners on the link address only,
/// start capture. Stop (also on any failure): input off + release held keys,
/// stop capture, `bye` to the iMac, close connections and listeners.
public final class HostSession {
    public struct Config {
        public var key: Data
        /// Explicit frame rate; nil = per display (60, or `fpsAbove4K` above 4K).
        public var fps: Int32? = nil
        public var fpsAbove4K: Int32 = 30
        public var bitrate = 12_000_000
        public var codec: CMVideoCodecType = kCMVideoCodecType_HEVC
        public var synthetic = false
        public var nativePixels = true
        public var videoCursor = false
        public var viewOnly = false
        public var allowReconnect = false
        public var deadManSeconds: Double?
        public var bindHost = WireProtocol.hostAddress
        public var allowedPeer = WireProtocol.clientAddress
        /// Which display to share; `automatic` follows the lid (external when present).
        public var displayChoice: DisplayChoice = .automatic
        /// Cap on the captured width in pixels (nil = native). Fewer pixels encode faster.
        public var maxCaptureWidth: Int?
        /// Switch an external display (HDMI dummy) to a 16:9 HiDPI mode that fills the iMac.
        public var fitExternalForIMac = true
        /// Test hook: pretend a permission is missing ("screen_recording" / "accessibility").
        public var simulateMissingPermission: String?
        public init(key: Data) { self.key = key }
    }

    public enum StartError: Error, CustomStringConvertible {
        case screenRecordingDenied, accessibilityDenied, linkDown(String), listener(String), capture(String)
        public var description: String {
            switch self {
            case .screenRecordingDenied: return "Screen Recording not granted"
            case .accessibilityDenied: return "Accessibility not granted (needed for keyboard & mouse control)"
            case let .linkDown(m): return "Cable link down: \(m)"
            case let .listener(m): return "Cannot listen: \(m)"
            case let .capture(m): return "Capture failed: \(m)"
            }
        }
    }

    public let config: Config
    public let stats = HostStats()
    public private(set) var state: HostState = .idle
    public private(set) var width: Int32 = 0, height: Int32 = 0
    public private(set) var injector: InputInjector
    public private(set) var encoder: VideoEncoder?
    /// True while a capture (screen or synthetic) is running.
    public var isCapturing: Bool { capturer != nil || synth != nil }

    public var onState: ((HostState) -> Void)?
    public var log: (String) -> Void = { print($0) }
    // Hooks for tests and the CLI.
    public var onLatencyEcho: ((UInt32) -> Void)?
    public var onInputEvent: ((InputEvent) -> Void)?
    public var onEscapeHatch: (() -> Void)?
    /// The iMac runs a RemoteMirror with another protocol version.
    public var onVersionMismatch: ((UInt16) -> Void)?

    private let server: VideoServer
    private let inputServer: VideoServer
    private var capturer: ScreenCapturer?
    private var synth: SyntheticSource?
    private var cursor: CursorTracker?
    private var needKeyframe = false
    private var escapeRequested = false
    private var stopCompletions: [() -> Void] = []
    private var nativePixels = true
    private var switching = false
    private var displayCheckPending = false
    private var reconfigRegistered = false
    /// Display currently shared (0 while synthetic).
    public var sharedDisplay: CGDirectDisplayID { capturer?.displayID ?? 0 }
    public private(set) var displaySwitches = 0
    /// Frame rate of the current capture.
    public private(set) var currentFps: Int32 = 60
    /// Why the last session ended (for the menu and the log).
    public private(set) var lastStopReason: String?
    /// Keeps the MacBook and its display from idling while sharing.
    public let power = PowerAssertion()

    public init(config: Config) {
        self.config = config
        var vc = VideoServer.Config(key: config.key)
        vc.bindHost = config.bindHost
        vc.allowedPeer = config.allowedPeer
        server = VideoServer(config: vc)
        var ic = vc
        ic.port = WireProtocol.inputPort
        inputServer = VideoServer(config: ic)
        injector = InputInjector(deadManSeconds: config.deadManSeconds)
    }

    private func transition(_ e: HostEvent) {
        let n = HostStateMachine.next(state, e)
        guard n != state else { return }
        state = n
        log("{\"event\":\"state\",\"state\":\"\(n.label)\"}")
        onState?(n)
    }

    // MARK: Start

    /// Must be called on the main thread. Throws (and ends in `.error`) on failure.
    @MainActor
    public func start() async throws {
        transition(.start)
        do {
            try preflight()
            wire()
            if config.synthetic {
                currentFps = config.fps ?? 60
                let s = SyntheticSource(fps: currentFps)
                synth = s
                width = Int32(s.width); height = Int32(s.height)
            } else {
                nativePixels = config.nativePixels
                do { try await startCapture(on: pickDisplay()) } catch { throw StartError.capture(error.localizedDescription) }
                registerDisplayWatch()
            }
            encoder = try VideoEncoder(width: width, height: height, fps: currentFps, bitrate: config.bitrate,
                                       codec: config.codec) { [weak self] out in self?.onEncoded(out) }
            do {
                try await server.start()
                try await inputServer.start()
            } catch {
                let inUse = "\(error)".contains("Address already in use")
                throw StartError.listener(inUse ? "port already in use (is another RemoteMirror sharing?)" : "\(error)")
            }
            synth?.start { [weak self] pb, pts in self?.onFrame(pb, pts) }
            if !config.videoCursor {
                let t = CursorTracker()
                t.displayID = sharedDisplay == 0 ? CGMainDisplayID() : sharedDisplay
                t.onVisibility = { [weak self] x, y, v in self?.server.sendControl(.cursor(x: x, y: y, visible: v)) }
                t.onPosition = { [weak self] x, y in self?.server.sendControl(.cursor(x: x, y: y, visible: true)) }
                t.onShape = { [weak self] s in self?.server.sendControl(.cursorShape(s)) }
                t.start()
                cursor = t
            }
            power.hold(reason: "RemoteMirror: sharing this screen with the iMac", system: true)
            log("{\"event\":\"power\",\"keep_awake\":\(power.isHeld)}")
            transition(.listening)
        } catch let e as StartError {
            await teardown()
            transition(.failed(e.description))
            throw e
        } catch {
            await teardown()
            transition(.failed("\(error)"))
            throw error
        }
    }

    private func preflight() throws {
        let sim = config.simulateMissingPermission
        if !config.synthetic && (sim == "screen_recording" || !HostPermissions.screenRecording()) {
            throw StartError.screenRecordingDenied
        }
        if !config.viewOnly && (sim == "accessibility" || !HostPermissions.accessibility()) {
            throw StartError.accessibilityDenied
        }
        if let problem = LinkCheck.localAddressProblem(config.bindHost) { throw StartError.linkDown(problem) }
    }

    private func wire() {
        server.log = log
        inputServer.log = log
        injector.log = log
        server.onKeyframeRequest = { [weak self] in self?.encoder?.requestKeyframe() }
        server.onVersionMismatch = { [weak self] v in DispatchQueue.main.async { self?.onVersionMismatch?(v) } }
        server.onLatencyEcho = { [weak self] v in self?.onLatencyEcho?(v) }
        inputServer.onGesture = { [weak self] g in
            guard let self, !self.config.viewOnly else { return }
            self.injector.injectGesture(g)
        }
        inputServer.onInput = { [weak self] e in
            guard let self else { return }
            self.onInputEvent?(e)
            if !self.config.viewOnly { self.injector.inject(e) }
        }
        server.onClientReady = { [weak self] in
            DispatchQueue.main.async { self?.cursor?.resend(); self?.transition(.clientConnected) }
        }
        let bye: (ByeReason) -> Void = { [weak self] r in
            guard r == .escapeHatch else { return }
            self?.escapeRequested = true   // the iMac user ended the session: stop even with reconnect
            self?.log("{\"event\":\"escape_hatch\"}")
            DispatchQueue.main.async { self?.onEscapeHatch?() }
        }
        server.onByeFromClient = bye
        inputServer.onByeFromClient = bye
        server.onClientGone = { [weak self] why in self?.clientGone("video", why) }
        inputServer.onClientGone = { [weak self] why in self?.clientGone("input", why) }
    }

    private func clientGone(_ which: String, _ why: String) {
        DispatchQueue.main.async {
            guard self.state.isActive else { return }
            if self.config.allowReconnect && !self.escapeRequested {
                self.injector.releaseAll()
                self.log("{\"event\":\"waiting_for_client\",\"which\":\"\(which)\",\"reason\":\"\(why)\"}")
                self.transition(.clientLost(reconnect: true))
            } else {
                self.stop(reason: "\(which) client gone: \(why)")
            }
        }
    }

    // MARK: Display selection and live switching (M13)

    private func pickDisplay() -> DisplayInfo? { Displays.choose(Displays.current(), config.displayChoice) }

    /// Starts capture on `display` (fitting an external one to 16:9 first) and points
    /// input, cursor and size at it. Caller must have stopped any previous capture.
    @MainActor
    private func startCapture(on display: DisplayInfo?) async throws {
        if config.fitExternalForIMac, let d = display, !d.isBuiltin, let changed = Displays.fitForIMac(d.id) {
            log("{\"event\":\"display_mode\",\"display\":\(d.id),\"mode\":\"\(changed)\"}")
            try? await Task.sleep(nanoseconds: 800_000_000)   // let the mode change settle
        }
        let c = ScreenCapturer(onFrame: { [weak self] pb, pts in self?.onFrame(pb, pts) },
                               onError: { [weak self] e in
                                   // The display may have gone away (lid closed): try another before failing.
                                   DispatchQueue.main.async { self?.captureLost(e) }
                               })
        currentFps = config.fps ?? display.map { d -> Int32 in
            var w = nativePixels ? d.pixelWidth : d.width, h = nativePixels ? d.pixelHeight : d.height
            if let m = config.maxCaptureWidth, w > m { h = h * m / w; w = m }
            return Displays.defaultFps(pixelWidth: w, pixelHeight: h, fpsAbove4K: config.fpsAbove4K)
        } ?? 60
        try await c.start(fps: currentFps, displayID: display?.id, nativePixels: nativePixels, showsCursor: config.videoCursor,
                          maxWidth: config.maxCaptureWidth)
        capturer = c
        width = Int32(c.width); height = Int32(c.height)
        injector.displayID = c.displayID
        cursor?.displayID = c.displayID
        let label = Displays.current().first { $0.id == c.displayID }?.label ?? "display \(c.displayID)"
        log("{\"event\":\"capturing\",\"display\":\(c.displayID),\"label\":\"\(label)\",\"width\":\(width),\"height\":\(height),\"fps\":\(currentFps)}")
    }

    /// Restarts capture (new display or new size) without ending the session: the iMac
    /// gets a keyframe at the new size and simply continues.
    @MainActor
    private func restartCapture(on display: DisplayInfo?, reason: String) async {
        guard state.isActive, !config.synthetic, !switching else { return }
        switching = true
        defer { switching = false }
        let t0 = Date()
        let old = capturer
        capturer = nil
        let oldEncoder = encoder
        encoder = nil                       // frames arriving meanwhile are dropped
        if let old { await old.stop() }
        oldEncoder?.invalidate()
        do {
            try await startCapture(on: display)
            encoder = try VideoEncoder(width: width, height: height, fps: currentFps, bitrate: config.bitrate,
                                       codec: config.codec) { [weak self] out in self?.onEncoded(out) }
            displaySwitches += 1
            log(String(format: "{\"event\":\"display_switched\",\"reason\":\"%@\",\"width\":%d,\"height\":%d,\"ms\":%.0f}",
                       reason, width, height, Date().timeIntervalSince(t0) * 1000))
            cursor?.resend()
        } catch {
            fail(.capture("could not restart capture: \(error.localizedDescription)"))
        }
    }

    private func captureLost(_ e: String) {
        guard state.isActive, !switching else { return }
        log("{\"event\":\"capture_lost\",\"reason\":\"\(e)\"}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.state.isActive else { return }
            guard let d = self.pickDisplay() else { self.fail(.capture("no display left to share")); return }
            Task { @MainActor in await self.restartCapture(on: d, reason: "capture lost") }
        }
    }

    /// Called (debounced) when displays are added/removed/reconfigured.
    private func checkDisplays() {
        displayCheckPending = false
        guard state.isActive, !config.synthetic, !switching, let c = capturer else { return }
        guard let want = pickDisplay() else { return }
        var px = nativePixels ? (want.pixelWidth, want.pixelHeight) : (want.width, want.height)
        if let m = config.maxCaptureWidth, px.0 > m { px = (m, px.1 * m / px.0) }
        px = (px.0 & ~1, px.1 & ~1)
        if want.id != c.displayID || px.0 != c.width || px.1 != c.height {
            Task { @MainActor in await self.restartCapture(on: want, reason: want.id != c.displayID ? "display changed" : "resolution changed") }
        }
    }

    /// One C callback for register and remove (removal needs the identical pointer).
    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, ctx in
        guard let ctx, !flags.contains(.beginConfigurationFlag) else { return }
        let session = Unmanaged<HostSession>.fromOpaque(ctx).takeUnretainedValue()
        DispatchQueue.main.async {
            guard !session.displayCheckPending else { return }
            session.displayCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { session.checkDisplays() }
        }
    }

    private func registerDisplayWatch() {
        guard !reconfigRegistered else { return }
        reconfigRegistered = true
        CGDisplayRegisterReconfigurationCallback(Self.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func unregisterDisplayWatch() {
        guard reconfigRegistered else { return }
        reconfigRegistered = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Test hook: switch capture size mid-session (native pixels <-> points) through the
    /// same path as a display change.
    @MainActor
    public func debugToggleCaptureSize() async {
        nativePixels.toggle()
        await restartCapture(on: Displays.current().first { $0.id == sharedDisplay } ?? pickDisplay(), reason: "test resize")
    }

    // MARK: Frames

    private func onFrame(_ pb: CVPixelBuffer, _ pts: CMTime) {
        guard server.isStreaming, let encoder else { return }
        stats.frameCaptured()
        if needKeyframe { needKeyframe = false; encoder.requestKeyframe() }
        encoder.encode(pb, pts: pts)
    }

    private func onEncoded(_ out: VideoEncoder.Output) {
        let flags = (out.isKeyframe ? VideoFrame.keyframeFlag : 0) | (config.codec == kCMVideoCodecType_HEVC ? VideoFrame.hevcFlag : 0)
        let frame = VideoFrame(ptsNanos: out.ptsNanos, flags: flags, width: UInt16(width), height: UInt16(height), payload: out.annexB)
        if server.send(frame) {
            stats.frameEncoded(bytes: out.annexB.count, keyframe: out.isKeyframe, encodeNanos: out.encodeNanos)
        } else {
            stats.frameDropped()
            needKeyframe = true   // never queue: drop and recover with a keyframe
        }
    }

    // MARK: Stop

    /// Stops everything; `completion` runs on the main thread once nothing is left running.
    public func stop(reason: String, completion: (() -> Void)? = nil) {
        let run = {
            if let completion { self.stopCompletions.append(completion) }
            guard self.state.isActive else {
                if self.state != .stopping { self.flushCompletions() }
                return
            }
            self.log("{\"event\":\"stopping\",\"reason\":\"\(reason)\"}")
            self.lastStopReason = reason
            self.transition(.stopRequested)
            Task { @MainActor in
                await self.teardown()
                self.transition(.stopped)
                self.flushCompletions()
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private func flushCompletions() {
        let c = stopCompletions; stopCompletions = []
        c.forEach { $0() }
    }

    /// Order matters: input first (no stuck keys), then capture, then say bye and close.
    @MainActor
    private func teardown() async {
        unregisterDisplayWatch()
        power.release()
        injector.stop()
        cursor?.stop(); cursor = nil
        synth?.stop(); synth = nil
        if let c = capturer { await c.stop() }
        capturer = nil
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            var pending = 2
            let done = { DispatchQueue.main.async { pending -= 1; if pending == 0 { k.resume() } } }
            inputServer.stop(then: done)
            server.stop(then: done)
        }
        encoder?.invalidate()
    }

    /// Stops the session and ends in `.error(reason)` (e.g. cable unplugged, sleep).
    public func fail(reason: String) {
        DispatchQueue.main.async { self.fail(.linkDown(reason), raw: reason) }
    }

    private func fail(_ e: StartError, raw: String? = nil) {
        guard state.isActive else { return }
        let msg = raw ?? e.description
        lastStopReason = msg
        log("{\"event\":\"error\",\"reason\":\"\(msg)\"}")
        Task { @MainActor in
            transition(.stopRequested)
            await teardown()
            transition(.failed(msg))
            flushCompletions()
        }
    }
}

/// Checks that the link address is configured on this Mac (cable plugged, IP set).
public enum LinkCheck {
    /// nil if `address` is assigned to an interface that is up; otherwise a reason.
    public static func localAddressProblem(_ address: String) -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return "cannot list interfaces" }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if String(cString: host) == address {
                    let up = (ifa.ifa_flags & UInt32(IFF_UP)) != 0 && (ifa.ifa_flags & UInt32(IFF_RUNNING)) != 0
                    return up ? nil : "interface \(String(cString: ifa.ifa_name)) is down"
                }
            }
            p = ifa.ifa_next
        }
        return "no interface has \(address) (cable unplugged or IP not set)"
    }
}
