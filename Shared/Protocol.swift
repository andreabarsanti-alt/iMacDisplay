import Foundation

/// Wire protocol shared by Host (MacBook, arm64) and Client (iMac, x86_64).
/// All integers are little-endian; floats are IEEE-754 Float32 bit patterns.
public enum WireProtocol {
    /// 2: gesture companions, actions and scroll phases (v1.2). Peers must match.
    public static let version: UInt16 = 2
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
    case cursorShape = 23
    case gesture = 24
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
    /// A gesture translated into a MacBook action; `code` = InputAction raw value.
    case action = 8
}

/// Magic Mouse gestures recognised on the iMac, performed on the MacBook as the
/// matching shortcut (resolved there for its keyboard layout).
public enum InputAction: UInt16, CaseIterable {
    case back = 1             // one-finger swipe right  -> Cmd-[ (localized)
    case forward = 2          // one-finger swipe left   -> Cmd-] (localized)
    case nextSpace = 3        // two-finger swipe left   -> Ctrl-Right
    case previousSpace = 4    // two-finger swipe right  -> Ctrl-Left
    case missionControl = 5   // two-finger double tap   -> Ctrl-Up
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

/// Raw fields of a companion gesture event: (field index, integer or double, value bits).
public struct GestureEvent: Equatable {
    public struct Field: Equatable {
        public var index: UInt8, isDouble: Bool, bits: UInt64
        public init(index: UInt8, isDouble: Bool, bits: UInt64) { self.index = index; self.isDouble = isDouble; self.bits = bits }
        public static func int(_ i: UInt8, _ v: Int64) -> Field { .init(index: i, isDouble: false, bits: UInt64(bitPattern: v)) }
        public static func double(_ i: UInt8, _ v: Double) -> Field { .init(index: i, isDouble: true, bits: v.bitPattern) }
        public var intValue: Int64 { Int64(bitPattern: bits) }
        public var doubleValue: Double { Double(bitPattern: bits) }
    }
    public var fields: [Field]
    public init(fields: [Field]) { self.fields = fields }
}

public struct CursorShape: Equatable {
    public var width: Float32, height: Float32   // fraction of host display width (both)
    public var hotX: Float32, hotY: Float32      // fraction of the cursor image, origin top-left
    public var png: Data
    public init(width: Float32, height: Float32, hotX: Float32, hotY: Float32, png: Data) {
        self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY; self.png = png
    }
}

public enum GestureRules {
    /// A finished two-finger (dock) swipe -> action, or nil if it was too small.
    /// Positive progress = fingers moving left = next desktop (to the right); recorded
    /// from a real Magic Mouse: progress 0.51 / velocity 6.6 vs -0.47 / -6.3.
    public static func dockAction(progress: Double, velocity: Double) -> InputAction? {
        guard abs(progress) >= 0.2 || abs(velocity) >= 1.0 else { return nil }
        let dir = abs(progress) >= 0.2 ? progress : velocity
        return dir > 0 ? .nextSpace : .previousSpace
    }
}

/// Packs a scroll event's extras into InputEvent.code (16 bits):
/// bit 0 = precise (pixel) deltas, bits 1-8 = CGScrollPhase raw value
/// (began 1, changed 2, ended 4, cancelled 8, mayBegin 128), bits 9-10 =
/// CGMomentumScrollPhase (none 0, begin 1, continue 2, end 3).
/// Older peers only knew bit 0 (code 0/1), so precise-without-phases stays 1.
public struct ScrollCode: Equatable {
    public var precise: Bool
    public var phase: UInt8
    public var momentum: UInt8

    public init(precise: Bool, phase: UInt8 = 0, momentum: UInt8 = 0) {
        self.precise = precise; self.phase = phase; self.momentum = momentum & 0x3
    }

    public init(code: UInt16) {
        precise = code & 1 != 0
        phase = UInt8((code >> 1) & 0xff)
        momentum = UInt8((code >> 9) & 0x3)
    }

    public var code: UInt16 { (precise ? 1 : 0) | UInt16(phase) << 1 | UInt16(momentum & 0x3) << 9 }
}

public struct VideoFrame: Equatable {
    public static let keyframeFlag: UInt8 = 0x01
    public static let hevcFlag: UInt8 = 0x02
    public var ptsNanos: UInt64
    public var flags: UInt8
    public var width: UInt16
    public var height: UInt16
    /// Annex B H.264/HEVC access unit (SPS/PPS precede each keyframe).
    public var payload: Data

    public var isKeyframe: Bool { flags & Self.keyframeFlag != 0 }
    public var isHEVC: Bool { flags & Self.hevcFlag != 0 }

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
    /// Host cursor image. Sizes are normalized to the host display width so the client
    /// can scale with the video; hotspot is normalized to the cursor image (0...1).
    case cursorShape(CursorShape)
    /// Client -> host: an undocumented companion gesture event (CGEvent type 29) that
    /// accompanies real Magic Mouse/trackpad scrolls; re-posted on the MacBook so swipes
    /// there are recognised natively (e.g. Safari back/forward).
    case gesture(GestureEvent)
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
        case .cursorShape: return .cursorShape
        case .gesture: return .gesture
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
        case let .cursorShape(c):
            w.f32(c.width); w.f32(c.height); w.f32(c.hotX); w.f32(c.hotY); w.bytes(c.png)
        case let .gesture(g):
            w.u8(UInt8(min(g.fields.count, 255)))
            for f in g.fields.prefix(255) { w.u8(f.index); w.u8(f.isDouble ? 1 : 0); w.u64(f.bits) }
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
        case .gesture:
            let n = Int(try r.u8())
            var fields: [GestureEvent.Field] = []
            for _ in 0..<n {
                let i = try r.u8(), kind = try r.u8(), bits = try r.u64()
                guard kind <= 1 else { throw WireError.invalidValue("gesture field kind") }
                fields.append(.init(index: i, isDouble: kind == 1, bits: bits))
            }
            msg = .gesture(GestureEvent(fields: fields))
        case .cursorShape:
            msg = .cursorShape(CursorShape(width: try r.f32(), height: try r.f32(), hotX: try r.f32(), hotY: try r.f32(),
                                           png: r.rest()))
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
