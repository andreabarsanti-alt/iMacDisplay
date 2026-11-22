import Foundation

/// Errors raised while decoding wire data. Decoding never traps on bad input.
public enum WireError: Error, Equatable {
    case truncated
    case unknownMessageType(UInt8)
    case invalidValue(String)
    case frameTooLarge(Int)
}

/// Appends fixed-size values in explicit little-endian order, so the bytes are
/// identical on arm64 and x86_64.
public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    public mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    public mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    public mutating func f32(_ v: Float32) { u32(v.bitPattern) }
    public mutating func bytes(_ d: Data) { data.append(d) }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

/// Reads little-endian values; every read is bounds-checked.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func u8() throws -> UInt8 { try read(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try read(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try read(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try read(UInt64.self) }
    public mutating func f32() throws -> Float32 { Float32(bitPattern: try u32()) }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset..<data.endIndex])
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var v: T = 0
        for i in 0..<size {   // assemble byte by byte: no alignment or endianness assumptions
            v |= T(data[offset + i]) << (8 * i)
        }
        offset += size
        return v
    }
}
