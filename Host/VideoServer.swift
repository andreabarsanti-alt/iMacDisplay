import Foundation
import Network
import Shared

/// Listens on the link address only, accepts a single authenticated client from
/// the pinned peer address and performs the handshake. Used twice: video
/// (port 5001, host -> client frames) and input (port 5002, client -> host events),
/// so input never waits behind video.
final class VideoServer {
    struct Config {
        var bindHost = WireProtocol.hostAddress
        var port = WireProtocol.videoPort
        var allowedPeer = WireProtocol.clientAddress
        var key: Data
        /// Drop frames while more than this many bytes are still queued for sending.
        var maxInFlightBytes = 4 * 1024 * 1024
    }

    private let config: Config
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var client: FramedConnection?
    private var streaming = false

    var log: (String) -> Void = { print($0) }
    /// Client authenticated and handshake done.
    var onClientReady: (() -> Void)?
    var onClientGone: ((String) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onRejected: ((String) -> Void)?
    var onByeFromClient: ((ByeReason) -> Void)?
    var onLatencyEcho: ((UInt32) -> Void)?

    var onInput: ((InputEvent) -> Void)?

    init(config: Config) {
        self.config = config
        queue = DispatchQueue(label: "server-\(config.port)", qos: .userInteractive)
    }

    func start() throws {
        let local = NWEndpoint.hostPort(host: NWEndpoint.Host(config.bindHost),
                                        port: NWEndpoint.Port(rawValue: config.port)!)
        let params = LinkSecurity.parameters(key: config.key, local: local)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.log("{\"event\":\"listening\",\"address\":\"\(self?.config.bindHost ?? "")\",\"port\":\(self?.config.port ?? 0)}")
            case let .failed(e): self?.log("{\"event\":\"listener_failed\",\"error\":\"\(e)\"}")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    func stop(reason: ByeReason = .hostStopped, then: (() -> Void)? = nil) {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.streaming = false
            if let c = self.client { c.sayGoodbye(reason) { then?() } } else { then?() }
            self.client = nil
        }
    }

    var isStreaming: Bool { queue.sync { streaming } }

    /// Sends one encoded frame, or drops it if the socket is backed up.
    /// Returns false if dropped (caller should then force a keyframe).
    @discardableResult
    func send(_ frame: VideoFrame) -> Bool {
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
                guard ok else { c.sayGoodbye(.protocolError); return }
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
