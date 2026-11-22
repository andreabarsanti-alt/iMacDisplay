import Foundation

/// Wire framing: `length (u32 LE) | type (u8) | payload`, where `length`
/// counts the type byte plus the payload. Messages above `maxMessage` are
/// rejected before any allocation, so a bad peer cannot exhaust memory.
public enum Framing {
    public static func encode(_ message: Message) -> Data {
        let payload = message.encodePayload()
        var w = ByteWriter()
        w.u32(UInt32(1 + payload.count))
        w.u8(message.type.rawValue)
        w.bytes(payload)
        return w.data
    }
}

/// Incremental decoder: feed arbitrary chunks from a stream socket, get whole messages out.
public struct FrameDecoder {
    public let maxMessage: Int
    private var buffer = Data()

    public init(maxMessage: Int) {
        self.maxMessage = maxMessage
    }

    public var bufferedBytes: Int { buffer.count }

    /// Appends `chunk` and returns every complete message now available.
    /// Throws on an oversized or malformed frame; the connection should then be closed.
    public mutating func feed(_ chunk: Data) throws -> [Message] {
        buffer.append(chunk)
        var out: [Message] = []
        while true {
            guard buffer.count >= 4 else { break }
            var r = ByteReader(buffer.prefix(4))
            let length = Int(try r.u32())
            guard length >= 1 else { throw WireError.invalidValue("zero-length frame") }
            guard length <= maxMessage else { throw WireError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex
            let type = buffer[start + 4]
            let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
            buffer = Data(buffer[(start + 4 + length)...])
            out.append(try Message.decode(type: type, payload: payload))
        }
        return out
    }
}
