import Foundation

/// Wire protocol shared by Host (MacBook, arm64) and Client (iMac, x86_64).
/// All integers are little-endian; floats are IEEE-754 Float32 bit patterns.
public enum WireProtocol {
    public static let version: UInt16 = 1
    public static let magic: UInt32 = 0x5044_4D49   // "IMDP" in little-endian byte order
    public static let nonceLength = 16

    /// Fixed IPs and ports of the direct Ethernet link.
    public static let hostAddress = "10.77.0.1"
    public static let clientAddress = "10.77.0.2"
    public static let videoPort: UInt16 = 5001
    public static let inputPort: UInt16 = 5002

    /// Hard caps on a single framed message (type byte + payload).
    public static let maxVideoMessage = 8 * 1024 * 1024
    public static let maxControlMessage = 64 * 1024
}

public enum MessageType: UInt8, CaseIterable {
    case hello = 1
    case helloAck = 2
    case heartbeat = 3
    case bye = 4
    case videoFrame = 10
    case keyframeRequest = 11
    case input = 20
    case cursor = 21
    case clipboard = 22
    case latencyEcho = 40
}

public enum PeerRole: UInt8 {
    case host = 1
    case client = 2
}

public enum ByeReason: UInt8 {
    case normal = 0
    case escapeHatch = 1
    case heartbeatTimeout = 2
    case protocolError = 3
    case hostStopped = 4
}

public enum InputKind: UInt8 {
    case mouseMove = 1
    case mouseDown = 2
    case mouseUp = 3
    case scroll = 4
    case keyDown = 5
    case keyUp = 6
    case flagsChanged = 7
}

/// One input event: `kind (1) | flags (4) | code (2) | x, y (2×f32) | dx, dy (2×f32)`.
/// `code` is the hardware keycode for keys, the button number for mouse events.
/// `x`/`y` are normalized 0...1 in the video rect; `dx`/`dy` are scroll deltas.
public struct InputEvent: Equatable {
    public var kind: InputKind
    public var flags: UInt32
    public var code: UInt16
    public var x: Float32
    public var y: Float32
    public var dx: Float32
    public var dy: Float32

    public init(kind: InputKind, flags: UInt32 = 0, code: UInt16 = 0,
                x: Float32 = 0, y: Float32 = 0, dx: Float32 = 0, dy: Float32 = 0) {
        self.kind = kind; self.flags = flags; self.code = code
        self.x = x; self.y = y; self.dx = dx; self.dy = dy
    }
}

public struct VideoFrame: Equatable {
    public static let keyframeFlag: UInt8 = 0x01
    public var ptsNanos: UInt64
    public var flags: UInt8
    public var width: UInt16
    public var height: UInt16
    /// Annex B H.264/HEVC access unit (SPS/PPS precede each keyframe).
    public var payload: Data

    public var isKeyframe: Bool { flags & Self.keyframeFlag != 0 }

    public init(ptsNanos: UInt64, flags: UInt8, width: UInt16, height: UInt16, payload: Data) {
        self.ptsNanos = ptsNanos; self.flags = flags
        self.width = width; self.height = height; self.payload = payload
    }
}

public enum Message: Equatable {
    case hello(role: PeerRole, version: UInt16, nonce: Data)
    case helloAck(version: UInt16, nonce: Data, accepted: Bool)
    case heartbeat(seq: UInt32, timestampNanos: UInt64)
    case bye(ByeReason)
    case videoFrame(VideoFrame)
    case keyframeRequest
    case input(InputEvent)
    case cursor(x: Float32, y: Float32, visible: Bool)
    case clipboard(String)
    /// Client -> host: marker value read from a decoded frame (M4 latency harness).
    case latencyEcho(marker: UInt32)

    public var type: MessageType {
        switch self {
        case .hello: return .hello
        case .helloAck: return .helloAck
        case .heartbeat: return .heartbeat
        case .bye: return .bye
        case .videoFrame: return .videoFrame
        case .keyframeRequest: return .keyframeRequest
        case .input: return .input
        case .cursor: return .cursor
        case .clipboard: return .clipboard
        case .latencyEcho: return .latencyEcho
        }
    }

    /// Payload bytes only (without type byte or length prefix).
    public func encodePayload() -> Data {
        var w = ByteWriter()
        switch self {
        case let .hello(role, version, nonce):
            w.u32(WireProtocol.magic); w.u16(version); w.u8(role.rawValue)
            w.bytes(Self.fixedNonce(nonce))
        case let .helloAck(version, nonce, accepted):
            w.u32(WireProtocol.magic); w.u16(version)
            w.bytes(Self.fixedNonce(nonce)); w.u8(accepted ? 1 : 0)
        case let .heartbeat(seq, ts):
            w.u32(seq); w.u64(ts)
        case let .bye(reason):
            w.u8(reason.rawValue)
        case let .videoFrame(f):
            w.u64(f.ptsNanos); w.u8(f.flags); w.u16(f.width); w.u16(f.height); w.bytes(f.payload)
        case .keyframeRequest:
            break
        case let .input(e):
            w.u8(e.kind.rawValue); w.u32(e.flags); w.u16(e.code)
            w.f32(e.x); w.f32(e.y); w.f32(e.dx); w.f32(e.dy)
        case let .cursor(x, y, visible):
            w.f32(x); w.f32(y); w.u8(visible ? 1 : 0)
        case let .clipboard(text):
            w.bytes(Data(text.utf8))
        case let .latencyEcho(marker):
            w.u32(marker)
        }
        return w.data
    }

    public static func decode(type rawType: UInt8, payload: Data) throws -> Message {
        guard let type = MessageType(rawValue: rawType) else {
            throw WireError.unknownMessageType(rawType)
        }
        var r = ByteReader(payload)
        let msg: Message
        switch type {
        case .hello:
            try expectMagic(&r)
            let version = try r.u16()
            guard let role = PeerRole(rawValue: try r.u8()) else { throw WireError.invalidValue("role") }
            msg = .hello(role: role, version: version, nonce: try r.bytes(WireProtocol.nonceLength))
        case .helloAck:
            try expectMagic(&r)
            let version = try r.u16()
            let nonce = try r.bytes(WireProtocol.nonceLength)
            msg = .helloAck(version: version, nonce: nonce, accepted: try bool(&r))
        case .heartbeat:
            msg = .heartbeat(seq: try r.u32(), timestampNanos: try r.u64())
        case .bye:
            guard let reason = ByeReason(rawValue: try r.u8()) else { throw WireError.invalidValue("bye reason") }
            msg = .bye(reason)
        case .videoFrame:
            let pts = try r.u64(), flags = try r.u8(), w = try r.u16(), h = try r.u16()
            msg = .videoFrame(VideoFrame(ptsNanos: pts, flags: flags, width: w, height: h, payload: r.rest()))
        case .keyframeRequest:
            msg = .keyframeRequest
        case .input:
            guard let kind = InputKind(rawValue: try r.u8()) else { throw WireError.invalidValue("input kind") }
            msg = .input(InputEvent(kind: kind, flags: try r.u32(), code: try r.u16(),
                                    x: try r.f32(), y: try r.f32(), dx: try r.f32(), dy: try r.f32()))
        case .cursor:
            msg = .cursor(x: try r.f32(), y: try r.f32(), visible: try bool(&r))
        case .clipboard:
            guard let s = String(data: r.rest(), encoding: .utf8) else { throw WireError.invalidValue("utf8") }
            msg = .clipboard(s)
        case .latencyEcho:
            msg = .latencyEcho(marker: try r.u32())
        }
        // Fixed-size messages must not carry trailing bytes.
        if r.remaining != 0 { throw WireError.invalidValue("trailing bytes in \(type)") }
        return msg
    }

    private static func expectMagic(_ r: inout ByteReader) throws {
        guard try r.u32() == WireProtocol.magic else { throw WireError.invalidValue("magic") }
    }

    private static func bool(_ r: inout ByteReader) throws -> Bool {
        switch try r.u8() {
        case 0: return false
        case 1: return true
        default: throw WireError.invalidValue("bool")
        }
    }

    /// Nonces are exactly 16 bytes on the wire (zero-padded / truncated).
    private static func fixedNonce(_ n: Data) -> Data {
        var d = Data(n.prefix(WireProtocol.nonceLength))
        if d.count < WireProtocol.nonceLength {
            d.append(Data(count: WireProtocol.nonceLength - d.count))
        }
        return d
    }
}
