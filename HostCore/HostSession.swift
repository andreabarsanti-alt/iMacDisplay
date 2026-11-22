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
        public var fps: Int32 = 60
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

    private let server: VideoServer
    private let inputServer: VideoServer
    private var capturer: ScreenCapturer?
    private var synth: SyntheticSource?
    private var cursor: CursorTracker?
    private var needKeyframe = false
    private var escapeRequested = false
    private var stopCompletions: [() -> Void] = []

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
                let s = SyntheticSource(fps: config.fps)
                synth = s
                width = Int32(s.width); height = Int32(s.height)
            } else {
                let c = ScreenCapturer(onFrame: { [weak self] pb, pts in self?.onFrame(pb, pts) },
                                       onError: { [weak self] e in DispatchQueue.main.async { self?.fail(.capture(e)) } })
                capturer = c
                do {
                    try await c.start(fps: config.fps, nativePixels: config.nativePixels, showsCursor: config.videoCursor)
                } catch { throw StartError.capture(error.localizedDescription) }
                width = Int32(c.width); height = Int32(c.height)
            }
            encoder = try VideoEncoder(width: width, height: height, fps: config.fps, bitrate: config.bitrate,
                                       codec: config.codec) { [weak self] out in self?.onEncoded(out) }
            do {
                try server.start()
                try inputServer.start()
            } catch { throw StartError.listener("\(error)") }
            synth?.start { [weak self] pb, pts in self?.onFrame(pb, pts) }
            if !config.videoCursor {
                let t = CursorTracker()
                t.onPosition = { [weak self] x, y in self?.server.sendControl(.cursor(x: x, y: y, visible: true)) }
                t.onShape = { [weak self] s in self?.server.sendControl(.cursorShape(s)) }
                t.start()
                cursor = t
            }
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
        server.onLatencyEcho = { [weak self] v in self?.onLatencyEcho?(v) }
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
