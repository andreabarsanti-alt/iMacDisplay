import Foundation
import Network

/// A framed, message-oriented wrapper around NWConnection with send-queue
/// accounting (for backpressure) and an app-level heartbeat.
public final class FramedConnection {
    public let connection: NWConnection
    public let queue: DispatchQueue
    private var decoder: FrameDecoder
    private var closed = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastReceive = DispatchTime.now()
    private var heartbeatSeq: UInt32 = 0
    private let inFlightLock = NSLock()
    private var _inFlightBytes = 0

    public var onMessage: ((Message) -> Void)?
    /// Called once, with a reason, when the connection ends for any reason.
    public var onClose: ((String) -> Void)?
    public var onReady: (() -> Void)?

    public static let heartbeatInterval = 0.5
    public static let heartbeatTimeout = 2.0

    public init(_ connection: NWConnection, maxMessage: Int, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.decoder = FrameDecoder(maxMessage: maxMessage)
    }

    public var inFlightBytes: Int { inFlightLock.lock(); defer { inFlightLock.unlock() }; return _inFlightBytes }

    public var remoteHost: String? {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case let .ipv4(a): return "\(a)"
            case let .ipv6(a): return "\(a)"
            case let .name(n, _): return n
            @unknown default: return nil
            }
        }
        return nil
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lastReceive = .now()
                self.receive()
                self.onReady?()
            case let .failed(e): self.close("failed: \(e)")
            case let .waiting(e): self.close("waiting: \(e)")
            case .cancelled: self.close("cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends a message; `completion` runs when the bytes are handed to the network.
    public func send(_ m: Message, completion: ((Bool) -> Void)? = nil) {
        guard !closed else { completion?(false); return }
        let data = Framing.encode(m)
        inFlightLock.lock(); _inFlightBytes += data.count; inFlightLock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.inFlightLock.lock(); self._inFlightBytes -= data.count; self.inFlightLock.unlock()
            if let err { self.queue.async { self.close("send error: \(err)") } }
            completion?(err == nil)
        })
    }

    /// Starts sending heartbeats and closes the connection if the peer goes silent.
    public func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let silent = Double(DispatchTime.now().uptimeNanoseconds - self.lastReceive.uptimeNanoseconds) / 1e9
            if silent > Self.heartbeatTimeout {
                self.close("heartbeat timeout (\(String(format: "%.1f", silent)) s)")
                return
            }
            self.heartbeatSeq &+= 1
            self.send(.heartbeat(seq: self.heartbeatSeq, timestampNanos: DispatchTime.now().uptimeNanoseconds))
        }
        heartbeatTimer = t
        t.resume()
    }

    public func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        connection.cancel()
        onClose?(reason)
    }

    /// Sends `bye` and closes shortly after, so the peer learns the reason.
    public func sayGoodbye(_ reason: ByeReason, then: (() -> Void)? = nil) {
        guard !closed else { then?(); return }
        var finished = false
        // Strong reference on purpose: the owner usually drops the connection right
        // after asking for a goodbye; it must stay alive until it is closed.
        let me = self
        let finish = { (why: String) in
            guard !finished else { return }
            finished = true
            me.close(why)
            then?()
        }
        send(.bye(reason)) { _ in me.queue.async { finish("sent bye \(reason)") } }
        queue.asyncAfter(deadline: .now() + 0.5) { finish("bye timeout") }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceive = .now()
                do {
                    for m in try self.decoder.feed(data) {
                        if case .heartbeat = m { continue }
                        self.onMessage?(m)
                    }
                } catch {
                    self.close("protocol error: \(error)")
                    return
                }
            }
            if isComplete { self.close("peer closed"); return }
            if let error { self.close("receive error: \(error)"); return }
            self.receive()
        }
    }
}
