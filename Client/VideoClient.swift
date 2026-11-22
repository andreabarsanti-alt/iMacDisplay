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

    func connect() {
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
                self.log("{\"event\":\"connected\",\"host\":\"\(self.host)\",\"port\":\(self.port)}")
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
            self?.log("{\"event\":\"disconnected\",\"reason\":\"\(reason)\"}")
            self?.onClosed?(reason)
        }
        c.start()
    }

    func requestKeyframe() { conn?.send(.keyframeRequest) }
    func sendLatencyEcho(_ v: UInt32) { conn?.send(.latencyEcho(marker: v)) }
    func send(_ e: InputEvent) { if handshakeDone { conn?.send(.input(e)) } }

    func disconnect(_ reason: ByeReason, then: (() -> Void)? = nil) {
        guard let c = conn else { then?(); return }
        c.sayGoodbye(reason, then: then)
    }
}
