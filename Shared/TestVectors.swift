import Foundation

/// A fixed set of messages covering every type, used by unit tests and by the
/// cross-machine check (Host emits them as hex on arm64, Client verifies on x86_64).
public enum TestVectors {
    public static let messages: [Message] = [
        .hello(role: .client, version: WireProtocol.version, nonce: Data(0..<16)),
        .helloAck(version: WireProtocol.version, nonce: Data((0..<16).reversed()), accepted: true),
        .heartbeat(seq: 0x0102_0304, timestampNanos: 0x1122_3344_5566_7788),
        .bye(.escapeHatch),
        .videoFrame(VideoFrame(ptsNanos: 33_333_333, flags: VideoFrame.keyframeFlag, width: 1920, height: 1080,
                               payload: Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28]))),
        .keyframeRequest,
        .input(InputEvent(kind: .keyDown, flags: 0x0010_0000, code: 36, x: 0.5, y: 0.25, dx: 1, dy: -1)),
        .input(InputEvent(kind: .scroll, dx: -3.5, dy: 12.25)),
        .input(InputEvent(kind: .action, code: InputAction.back.rawValue)),
        .cursor(x: 0.125, y: 0.875, visible: true),
        .clipboard("ciao, perché? ✓"),
        .latencyEcho(marker: 0x00ab_cdef),
        .gesture(GestureEvent(fields: [.int(55, 29), .int(110, 6), .double(113, -42.5), .int(132, 2)])),
        .cursorShape(CursorShape(width: 0.0125, height: 0.02, hotX: 0.25, hotY: 0.125, png: Data([0x89, 0x50, 0x4e, 0x47]))),
    ]

    public static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    public static func data(hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b); i += 2
        }
        return out
    }

    /// Hex lines, one framed message per line.
    public static func emit() -> String {
        messages.map { hex(Framing.encode($0)) }.joined(separator: "\n")
    }

    /// Checks hex lines produced by `emit()` on another machine: each must decode
    /// to the expected message and re-encode to the same bytes. Returns failures.
    public static func verify(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var failures: [String] = []
        if lines.count != messages.count {
            failures.append("expected \(messages.count) lines, got \(lines.count)")
        }
        for (i, line) in lines.prefix(messages.count).enumerated() {
            guard let bytes = data(hex: line) else { failures.append("line \(i): bad hex"); continue }
            var dec = FrameDecoder(maxMessage: WireProtocol.maxVideoMessage)
            do {
                let got = try dec.feed(bytes)
                if got != [messages[i]] { failures.append("line \(i): decoded \(got), expected \(messages[i])") }
                if Framing.encode(messages[i]) != bytes { failures.append("line \(i): local encoding differs") }
            } catch {
                failures.append("line \(i): \(error)")
            }
        }
        return failures
    }
}
