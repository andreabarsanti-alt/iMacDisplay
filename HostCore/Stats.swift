import Foundation

/// Rolling counters printed as one JSON line per interval (`--stats`) and as a final summary.
public final class HostStats {
    private let lock = NSLock()
    private var captured = 0, encoded = 0, dropped = 0, keyframes = 0
    private var bytes = 0
    private var encodeNanosTotal: UInt64 = 0, encodeNanosMax: UInt64 = 0
    private var totalCaptured = 0, totalEncoded = 0, totalDropped = 0, totalKeyframes = 0, totalBytes = 0
    private var totalEncodeNanos: UInt64 = 0
    private let start = Date()
    public var errors: [String] = []

    public init() {}

    public func frameCaptured() { lock.lock(); captured += 1; totalCaptured += 1; lock.unlock() }
    public func frameDropped() { lock.lock(); dropped += 1; totalDropped += 1; lock.unlock() }
    public func frameEncoded(bytes n: Int, keyframe: Bool, encodeNanos: UInt64) {
        lock.lock()
        encoded += 1; totalEncoded += 1; bytes += n; totalBytes += n
        if keyframe { keyframes += 1; totalKeyframes += 1 }
        encodeNanosTotal += encodeNanos; totalEncodeNanos += encodeNanos
        encodeNanosMax = max(encodeNanosMax, encodeNanos)
        lock.unlock()
    }
    public func error(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }

    /// Frames sent and megabits since the last call (resets interval counters).
    public func snapshot(seconds: Double) -> (fps: Double, mbps: Double, dropped: Int) {
        lock.lock(); defer {
            captured = 0; encoded = 0; dropped = 0; keyframes = 0; bytes = 0
            encodeNanosTotal = 0; encodeNanosMax = 0; lock.unlock()
        }
        return (Double(encoded) / seconds, Double(bytes) * 8 / seconds / 1e6, dropped)
    }

    /// Interval line; resets interval counters.
    public func intervalJSON(seconds: Double) -> String {
        lock.lock(); defer {
            captured = 0; encoded = 0; dropped = 0; keyframes = 0; bytes = 0
            encodeNanosTotal = 0; encodeNanosMax = 0; lock.unlock()
        }
        let avgMs = encoded > 0 ? Double(encodeNanosTotal) / Double(encoded) / 1e6 : 0
        return json([
            ("event", "\"stats\""),
            ("capture_fps", fmt(Double(captured) / seconds)),
            ("encode_fps", fmt(Double(encoded) / seconds)),
            ("dropped", "\(dropped)"), ("keyframes", "\(keyframes)"),
            ("mbps", fmt(Double(bytes) * 8 / seconds / 1e6)),
            ("encode_ms_avg", fmt(avgMs)), ("encode_ms_max", fmt(Double(encodeNanosMax) / 1e6)),
        ])
    }

    public func summary(extra: [(String, String)]) -> (json: String, encodeFps: Double, bytes: Int, errors: [String]) {
        lock.lock(); defer { lock.unlock() }
        let secs = Date().timeIntervalSince(start)
        let fps = Double(totalEncoded) / secs
        let avgMs = totalEncoded > 0 ? Double(totalEncodeNanos) / Double(totalEncoded) / 1e6 : 0
        let j = json([("event", "\"summary\""), ("seconds", fmt(secs)),
                      ("captured", "\(totalCaptured)"), ("encoded", "\(totalEncoded)"),
                      ("dropped", "\(totalDropped)"), ("keyframes", "\(totalKeyframes)"),
                      ("bytes", "\(totalBytes)"), ("avg_encode_fps", fmt(fps)),
                      ("avg_mbps", fmt(Double(totalBytes) * 8 / secs / 1e6)),
                      ("encode_ms_avg", fmt(avgMs)), ("errors", "\(errors.count)")] + extra)
        return (j, fps, totalBytes, errors)
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
    private func json(_ kv: [(String, String)]) -> String {
        "{" + kv.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}
