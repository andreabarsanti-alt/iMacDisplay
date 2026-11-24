import Foundation
import Network
import Shared

/// Listens on the link address only, accepts a single authenticated client from
/// the pinned peer address and performs the handshake. Used twice: video
/// (port 5001, host -> client frames) and input (port 5002, client -> host events),
/// so input never waits behind video.
public final class VideoServer {
    public struct Config {
        public var bindHost = WireProtocol.hostAddress
        public var port = WireProtocol.videoPort
        public var allowedPeer = WireProtocol.clientAddress
        public var key: Data
        /// Drop frames while more than this many bytes are still queued for sending.
        public var maxInFlightBytes = 4 * 1024 * 1024
        public init(key: Data) { self.key = key }
    }

    private let config: Config
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var client: FramedConnection?
    private var streaming = false

    public var log: (String) -> Void = { print($0) }
    /// Client authenticated and handshake done.
    public var onClientReady: (() -> Void)?
    public var onClientGone: ((String) -> Void)?
    public var onKeyframeRequest: (() -> Void)?
    public var onRejected: ((String) -> Void)?
    public var onByeFromClient: ((ByeReason) -> Void)?
    public var onLatencyEcho: ((UInt32) -> Void)?

    public var onInput: ((InputEvent) -> Void)?
    public var onGesture: ((GestureEvent) -> Void)?
    /// The iMac app speaks another protocol version (update needed).
    public var onVersionMismatch: ((UInt16) -> Void)?

    public init(config: Config) {
        self.config = config
        queue = DispatchQueue(label: "server-\(config.port)", qos: .userInteractive)
    }

    public enum ListenError: Error, CustomStringConvertible {
        case failed(String), timeout
        public var description: String {
            switch self {
            case let .failed(m): return m
            case .timeout: return "listener did not become ready"
            }
        }
    }

    /// Opens the listener and returns once macOS confirms it is listening; throws if
    /// it can't (e.g. the port is taken by another RemoteMirror), instead of
    /// pretending to wait for the iMac.
    public func start() async throws {
        let local = NWEndpoint.hostPort(host: NWEndpoint.Host(config.bindHost),
                                        port: NWEndpoint.Port(rawValue: config.port)!)
        let params = LinkSecurity.parameters(key: config.key, local: local)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Result<Void, Error>) -> Void = { r in
                guard !done else { return }
                done = true
                k.resume(with: r)
            }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    self?.log("{\"event\":\"listening\",\"address\":\"\(self?.config.bindHost ?? "")\",\"port\":\(self?.config.port ?? 0)}")
                    finish(.success(()))
                case let .failed(e):
                    self?.log("{\"event\":\"listener_failed\",\"port\":\(self?.config.port ?? 0),\"error\":\"\(e)\"}")
                    finish(.failure(ListenError.failed("port \(self?.config.port ?? 0): \(e)")))
                case let .waiting(e):
                    finish(.failure(ListenError.failed("port \(self?.config.port ?? 0): \(e)")))
                default: break
                }
            }
            l.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(.failure(ListenError.timeout)) }
        }
    }

    public func stop(reason: ByeReason = .hostStopped, then: (() -> Void)? = nil) {
        queue.async {
            self.streaming = false
            // Completes when the client got its bye (or timed out) AND the listener is
            // really cancelled, so the port is released when `then` runs.
            var pending = 2
            var finished = false
            let step = {
                pending -= 1
                if pending == 0 && !finished { finished = true; then?() }
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let ms = { String(format: "%.0f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
            if let l = self.listener {
                l.stateUpdateHandler = { st in
                    if case .cancelled = st { self.log("{\"event\":\"stop_trace\",\"port\":\(self.config.port),\"what\":\"listener_cancelled\",\"ms\":\(ms())}"); self.queue.async(execute: step) }
                }
                l.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) { if pending > 0 { self.log("{\"event\":\"stop_trace\",\"port\":\(self.config.port),\"what\":\"timeout\",\"pending\":\(pending)}"); pending = 1; step() } }
            } else { step() }
            self.listener = nil
            if let c = self.client { c.sayGoodbye(reason) { self.log("{\"event\":\"stop_trace\",\"port\":\(self.config.port),\"what\":\"bye_done\",\"ms\":\(ms())}"); self.queue.async(execute: step) } } else { step() }
            self.client = nil
        }
    }

    public var isStreaming: Bool { queue.sync { streaming } }

    /// Sends a small control message (cursor etc.) if a client is streaming.
    public func sendControl(_ m: Message) {
        guard let c = queue.sync(execute: { streaming ? client : nil }) else { return }
        c.send(m)
    }

    /// Sends one encoded frame, or drops it if the socket is backed up.
    /// Returns false if dropped (caller should then force a keyframe).
    @discardableResult
    public func send(_ frame: VideoFrame) -> Bool {
        guard let c = queue.sync(execute: { streaming ? client : nil }) else { return false }
        if c.inFlightBytes > config.maxInFlightBytes { return false }
        c.send(.videoFrame(frame))
        return true
    }

    private func accept(_ nw: NWConnection) {
        let c = FramedConnection(nw, maxMessage: WireProtocol.maxControlMessage, queue: queue)
        let peer = c.remoteHost ?? "?"
        guard peer == config.allowedPeer else {
            reject(c, "peer \(peer) is not \(config.allowedPeer)")
            return
        }
        guard client == nil else {
            reject(c, "already serving a client")
            return
        }
        client = c
        var handshakeDone = false
        c.onMessage = { [weak self, weak c] m in
            guard let self, let c else { return }
            if !handshakeDone {
                guard case let .hello(role, version, nonce) = m, role == .client else {
                    c.close("expected hello"); return
                }
                let ok = version == WireProtocol.version
                c.send(.helloAck(version: WireProtocol.version, nonce: nonce, accepted: ok))
                guard ok else {
                    self.log("{\"event\":\"version_mismatch\",\"imac_protocol\":\(version),\"macbook_protocol\":\(WireProtocol.version)}")
                    self.onVersionMismatch?(version)
                    c.sayGoodbye(.protocolError); return
                }
                handshakeDone = true
                c.startHeartbeat()
                self.streaming = true
                self.log("{\"event\":\"client_ready\",\"peer\":\"\(peer)\",\"port\":\(self.config.port)}")
                self.onClientReady?()
                return
            }
            switch m {
            case .keyframeRequest: self.onKeyframeRequest?()
            case let .latencyEcho(v): self.onLatencyEcho?(v)
            case let .input(e): self.onInput?(e)
            case let .gesture(g): self.onGesture?(g)
            case let .bye(r):
                self.onByeFromClient?(r)
                c.close("client said bye: \(r)")
            default: break
            }
        }
        c.onClose = { [weak self, weak c] reason in
            guard let self else { return }
            if self.client === c { self.client = nil; self.streaming = false }
            if handshakeDone {
                self.log("{\"event\":\"client_gone\",\"reason\":\"\(reason)\",\"port\":\(self.config.port)}")
                self.onClientGone?(reason)
            } else {
                self.log("{\"event\":\"rejected\",\"peer\":\"\(peer)\",\"reason\":\"\(reason)\"}")
                self.onRejected?(reason)
            }
        }
        // Handshake must complete quickly.
        queue.asyncAfter(deadline: .now() + 3) { [weak c] in if !handshakeDone { c?.close("handshake timeout") } }
        c.start()
    }

    private func reject(_ c: FramedConnection, _ reason: String) {
        log("{\"event\":\"rejected\",\"peer\":\"\(c.remoteHost ?? "?")\",\"reason\":\"\(reason)\"}")
        onRejected?(reason)
        c.connection.cancel()
    }
}
