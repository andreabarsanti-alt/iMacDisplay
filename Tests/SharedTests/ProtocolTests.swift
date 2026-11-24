import Foundation
import Testing
@testable import Shared

private func bytes(_ hex: String) -> Data {
    TestVectors.data(hex: hex.replacingOccurrences(of: " ", with: ""))!
}

@Suite struct GoldenBytes {
    // Hand-computed expected bytes: prove explicit little-endian on every architecture.
    @Test func heartbeat() {
        let m = Message.heartbeat(seq: 0x0102_0304, timestampNanos: 0x1122_3344_5566_7788)
        #expect(Framing.encode(m) == bytes("0d000000 03 04030201 8877665544332211"))
    }

    @Test func input() {
        let m = Message.input(InputEvent(kind: .keyDown, flags: 0x0010_0000, code: 36,
                                         x: 0.5, y: 0.25, dx: 1, dy: -1))
        #expect(Framing.encode(m) == bytes("18000000 14 05 00001000 2400 0000003f 0000803e 0000803f 000080bf"))
    }

    @Test func hello() {
        let m = Message.hello(role: .client, version: 1, nonce: Data(0..<16))
        #expect(Framing.encode(m) == bytes("18000000 01 494d4450 0100 02 000102030405060708090a0b0c0d0e0f"))
    }
}

@Suite struct RoundTrip {
    @Test(arguments: TestVectors.messages)
    func roundTrip(_ m: Message) throws {
        var dec = FrameDecoder(maxMessage: WireProtocol.maxVideoMessage)
        #expect(try dec.feed(Framing.encode(m)) == [m])
        #expect(dec.bufferedBytes == 0)
    }

    @Test func allTypesCovered() {
        let covered = Set(TestVectors.messages.map(\.type))
        #expect(covered == Set(MessageType.allCases))
    }

    @Test func emitVerifySelfConsistent() {
        #expect(TestVectors.verify(TestVectors.emit()) == [])
    }
}

@Suite struct StreamFraming {
    @Test func byteByByte() throws {
        let stream = TestVectors.messages.reduce(into: Data()) { $0.append(Framing.encode($1)) }
        var dec = FrameDecoder(maxMessage: WireProtocol.maxVideoMessage)
        var got: [Message] = []
        for b in stream { got += try dec.feed(Data([b])) }
        #expect(got == TestVectors.messages)
    }

    @Test func irregularChunks() throws {
        let stream = TestVectors.messages.reduce(into: Data()) { $0.append(Framing.encode($1)) }
        var dec = FrameDecoder(maxMessage: WireProtocol.maxVideoMessage)
        var got: [Message] = []
        var i = 0, step = 1
        while i < stream.count {
            let end = min(i + step, stream.count)
            got += try dec.feed(stream.subdata(in: i..<end))
            i = end; step = step % 7 + 3
        }
        #expect(got == TestVectors.messages)
    }

    @Test func rejectsOversizedBeforeBuffering() {
        var dec = FrameDecoder(maxMessage: WireProtocol.maxControlMessage)
        let header = bytes("01000100")   // claims 65537 bytes
        #expect(throws: WireError.frameTooLarge(65537)) { try dec.feed(header) }
    }

    @Test func rejectsZeroLength() {
        var dec = FrameDecoder(maxMessage: 1024)
        #expect(throws: WireError.invalidValue("zero-length frame")) { try dec.feed(bytes("00000000")) }
    }
}

@Suite struct Malformed {
    @Test func unknownType() {
        #expect(throws: WireError.unknownMessageType(99)) { try Message.decode(type: 99, payload: Data()) }
    }

    @Test func truncatedHeartbeat() {
        #expect(throws: WireError.truncated) { try Message.decode(type: 3, payload: Data([1, 2, 3])) }
    }

    @Test func badMagic() {
        var p = Message.hello(role: .host, version: 1, nonce: Data(count: 16)).encodePayload()
        p[0] ^= 0xff
        #expect(throws: WireError.invalidValue("magic")) { try Message.decode(type: 1, payload: p) }
    }

    @Test func trailingBytes() {
        var p = Message.bye(.normal).encodePayload()
        p.append(0)
        #expect(throws: (any Error).self) { try Message.decode(type: 4, payload: p) }
    }

    @Test func invalidEnum() {
        #expect(throws: WireError.invalidValue("input kind")) {
            try Message.decode(type: 20, payload: Data(count: 23))
        }
    }

    @Test func invalidBool() {
        var p = Message.cursor(x: 0, y: 0, visible: true).encodePayload()
        p[p.count - 1] = 7
        #expect(throws: WireError.invalidValue("bool")) { try Message.decode(type: 21, payload: p) }
    }
}

@Suite struct MarkerCoding {
    @Test(arguments: [UInt32(0), 1, 0x00ab_cdef, 0x00ff_ffff, 123_456])
    func roundTrip(_ v: UInt32) {
        let bits = Marker.bits(v)
        #expect(bits.count == Marker.cells)
        #expect(Marker.decode { bits[$0] ? 235 : 20 } == v)
    }

    @Test func detectsCorruption() {
        var bits = Marker.bits(4242)
        bits[5].toggle()
        #expect(Marker.decode { bits[$0] ? 255 : 0 } == nil)
    }

    @Test func allBlackIsRejected() {
        // A blank or missing marker must not decode as a value.
        #expect(Marker.decode { _ in 0 } == nil)
    }
}

@Suite struct ScrollCodeTests {
    @Test(arguments: [(true, UInt8(1), UInt8(0)), (true, 2, 0), (true, 4, 0), (true, 8, 0), (true, 128, 0),
                      (true, 0, 1), (true, 0, 2), (true, 0, 3), (false, 0, 0), (true, 0, 0)])
    func roundTrip(_ c: (Bool, UInt8, UInt8)) {
        let s = ScrollCode(precise: c.0, phase: c.1, momentum: c.2)
        #expect(ScrollCode(code: s.code) == s)
    }
    @Test func compatibleWithOldPeers() {
        #expect(ScrollCode(precise: true).code == 1)     // old "precise" value
        #expect(ScrollCode(precise: false).code == 0)    // old "line" value
        #expect(ScrollCode(code: 1).precise && ScrollCode(code: 1).phase == 0)
    }
}
