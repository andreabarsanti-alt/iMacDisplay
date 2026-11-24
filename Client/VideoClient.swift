import Foundation
import Network
import Shared

/// Connects to the host over the link (TLS-PSK) and handshakes. One instance
/// receives video (port 5001); a second sends input (port 5002).
final class VideoClient {
    private let queue = DispatchQueue(label: "video-client", qos: .userInteractive)
    private var conn: FramedConnection?
    private let key: Data
    private let host: String
    private let port: UInt16
    private var nonce = Data()
    private(set) var handshakeDone = false

    var log: (String) -> Void = { print($0) }
    var onReady: (() -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    var onClosed: ((String) -> Void)?
    var onBye: ((ByeReason) -> Void)?
    var onCursor: ((Float32, Float32, Bool) -> Void)?
    var onCursorShape: ((CursorShape) -> Void)?

    init(key: Data, host: String = WireProtocol.hostAddress, port: UInt16 = WireProtocol.videoPort) {
        self.key = key; self.host = host; self.port = port
    }

    /// Before the first handshake, failed attempts are retried until this deadline
    /// (macOS may briefly report "Network is down" while it re-checks a rebuilt app).
    var retryUntil: Date?
    private(set) var attempts = 0
    /// After a successful session, a drop starts a new retry window instead of ending.
    var allowReconnect = false
    var reconnectWindow: TimeInterval = 30
    var onReconnecting: ((String) -> Void)?
    private(set) var reconnects = 0
    private var reconnectStarted: Date?
    /// When the latest handshake completed (for time-to-first-frame).
    private(set) var connectedAt = Date()

    /// Waiting mode (M11): keep trying quietly every `retryInterval` until the host appears.
    var waitForever = false
    var retryInterval: TimeInterval = 0.5

    func connect() {
        if retryUntil == nil { retryUntil = waitForever ? .distantFuture : Date().addingTimeInterval(8) }
        attempts += 1
        let params = LinkSecurity.parameters(key: key)
        let nw = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let c = FramedConnection(nw, maxMessage: WireProtocol.maxVideoMessage, queue: queue)
        conn = c
        var bytes = [UInt8](repeating: 0, count: WireProtocol.nonceLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        nonce = Data(bytes)
        c.onReady = { [weak self, weak c] in
            guard let self, let c else { return }
            c.send(.hello(role: .client, version: WireProtocol.version, nonce: self.nonce))
            self.queue.asyncAfter(deadline: .now() + 3) { [weak c] in
                if !self.handshakeDone { c?.close("handshake timeout") }
            }
        }
        c.onMessage = { [weak self, weak c] m in
            guard let self, let c else { return }
            if !self.handshakeDone {
                guard case let .helloAck(version, echoed, accepted) = m, echoed == self.nonce else {
                    c.close("bad helloAck"); return
                }
                guard accepted, version == WireProtocol.version else {
                    c.close("host rejected protocol v\(WireProtocol.version) (host v\(version))"); return
                }
                self.handshakeDone = true
                c.startHeartbeat()
                if self.port == WireProtocol.videoPort { c.send(.keyframeRequest) }
                self.connectedAt = Date()
                let gap = self.reconnectStarted.map { String(format: ",\"reconnect_ms\":%.0f", Date().timeIntervalSince($0) * 1000) } ?? ""
                self.reconnectStarted = nil
                self.log("{\"event\":\"connected\",\"host\":\"\(self.host)\",\"port\":\(self.port),\"attempts\":\(self.attempts)\(gap)}")
                self.onReady?()
                return
            }
            switch m {
            case let .videoFrame(f): self.onFrame?(f)
            case let .cursor(x, y, visible): self.onCursor?(x, y, visible)
            case let .cursorShape(c): self.onCursorShape?(c)
            case let .bye(r): self.onBye?(r); c.close("host said bye: \(r)")
            default: break
            }
        }
        c.onClose = { [weak self] reason in
            guard let self else { return }
            if self.handshakeDone, self.allowReconnect, !reason.contains("escapeHatch") {
                self.handshakeDone = false
                self.reconnects += 1
                self.retryUntil = Date().addingTimeInterval(self.reconnectWindow)
                self.log("{\"event\":\"reconnecting\",\"port\":\(self.port),\"reason\":\"\(reason)\"}")
                self.reconnectStarted = Date()
                self.onReconnecting?(reason)
                self.queue.asyncAfter(deadline: .now() + 0.3) { self.connect() }
                return
            }
            let mayRetry = !reason.contains("bye") || (self.allowReconnect && self.reconnects > 0 && !reason.contains("escapeHatch"))
            if !self.handshakeDone, let until = self.retryUntil, Date() < until, mayRetry || self.waitForever {
                if !self.waitForever { self.log("{\"event\":\"connect_retry\",\"attempt\":\(self.attempts),\"reason\":\"\(reason)\"}") }
                self.queue.asyncAfter(deadline: .now() + self.retryInterval) { self.connect() }
                return
            }
            self.log("{\"event\":\"disconnected\",\"reason\":\"\(reason)\"}")
            self.onClosed?(reason)
        }
        c.start()
    }

    func requestKeyframe() { conn?.send(.keyframeRequest) }
    func sendLatencyEcho(_ v: UInt32) { conn?.send(.latencyEcho(marker: v)) }
    func send(_ e: InputEvent) { if handshakeDone { conn?.send(.input(e)) } }
    func send(_ m: Message) { if handshakeDone { conn?.send(m) } }

    func disconnect(_ reason: ByeReason, then: (() -> Void)? = nil) {
        guard let c = conn else { then?(); return }
        c.sayGoodbye(reason, then: then)
    }
}
