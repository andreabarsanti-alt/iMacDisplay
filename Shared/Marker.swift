import Foundation

/// On-screen latency marker: a row of black/white cells encoding a 24-bit counter
/// plus an 8-bit check byte. Robust to scaling and compression because each cell
/// is large and only its centre is sampled.
public enum Marker {
    public static let cells = 32
    public static let valueMask: UInt32 = 0x00ff_ffff

    /// Bit pattern (MSB first) for `value`: 24 value bits then 8 check bits.
    public static func bits(_ value: UInt32) -> [Bool] {
        let v = value & valueMask
        let word = (v << 8) | UInt32(check(v))
        return (0..<cells).map { word & (1 << UInt32(cells - 1 - $0)) != 0 }
    }

    public static func check(_ v: UInt32) -> UInt8 {
        let b0 = UInt8(v & 0xff), b1 = UInt8((v >> 8) & 0xff), b2 = UInt8((v >> 16) & 0xff)
        return (b0 &+ b1 &+ b2) ^ 0xa5
    }

    /// Decodes from a luma sampler. `luma(i)` returns the 0...255 brightness at
    /// the centre of cell i. Returns nil if the check byte doesn't match.
    public static func decode(luma: (Int) -> UInt8) -> UInt32? {
        var word: UInt32 = 0
        for i in 0..<cells { word = (word << 1) | (luma(i) >= 128 ? 1 : 0) }
        let v = word >> 8
        return UInt8(word & 0xff) == check(v) ? v : nil
    }
}
