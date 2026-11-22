import Foundation

final class ClientStats {
    private let lock = NSLock()
    private var received = 0, decoded = 0, displayed = 0, bytes = 0, decodeErrors = 0
    private var decodeNanos: UInt64 = 0, decodeMax: UInt64 = 0
    private var lastArrival: UInt64 = 0, jitterSum = 0.0, jitterN = 0
    private var tReceived = 0, tDisplayed = 0, tBytes = 0, tDecodeNanos: UInt64 = 0, tDecoded = 0
    private var firstDisplay: Date?
    private var lastDisplay: Date?

    func frameReceived(bytes n: Int) {
        lock.lock(); defer { lock.unlock() }
        received += 1; tReceived += 1; bytes += n; tBytes += n
        let now = DispatchTime.now().uptimeNanoseconds
        if lastArrival > 0 {
            let gapMs = Double(now - lastArrival) / 1e6
            jitterSum += abs(gapMs - 1000.0 / 30.0); jitterN += 1
        }
        lastArrival = now
    }
    func frameDecoded(nanos: UInt64) {
        lock.lock(); decoded += 1; tDecoded += 1; decodeNanos += nanos; tDecodeNanos += nanos
        decodeMax = max(decodeMax, nanos); lock.unlock()
    }
    func frameDisplayed() {
        lock.lock(); displayed += 1; tDisplayed += 1
        let now = Date(); if firstDisplay == nil { firstDisplay = now }; lastDisplay = now
        lock.unlock()
    }
    func decodeError() { lock.lock(); decodeErrors += 1; lock.unlock() }

    func intervalJSON(seconds: Double) -> String {
        lock.lock(); defer {
            received = 0; decoded = 0; displayed = 0; bytes = 0; decodeNanos = 0; decodeMax = 0
            jitterSum = 0; jitterN = 0; lock.unlock()
        }
        return String(format: "{\"event\":\"stats\",\"recv_fps\":%.2f,\"decode_fps\":%.2f,\"display_fps\":%.2f,\"mbps\":%.2f,\"decode_ms_avg\":%.2f,\"decode_ms_max\":%.2f,\"jitter_ms\":%.2f,\"decode_errors\":%d}",
                      Double(received) / seconds, Double(decoded) / seconds, Double(displayed) / seconds,
                      Double(bytes) * 8 / seconds / 1e6,
                      decoded > 0 ? Double(decodeNanos) / Double(decoded) / 1e6 : 0, Double(decodeMax) / 1e6,
                      jitterN > 0 ? jitterSum / Double(jitterN) : 0, decodeErrors)
    }

    /// Average displayed fps between first and last displayed frame.
    func summary() -> (json: String, displayFps: Double) {
        lock.lock(); defer { lock.unlock() }
        let span = (firstDisplay.flatMap { f in lastDisplay.map { $0.timeIntervalSince(f) } }) ?? 0
        let fps = span > 0 ? Double(tDisplayed - 1) / span : 0
        let j = String(format: "{\"event\":\"summary\",\"received\":%d,\"decoded\":%d,\"displayed\":%d,\"seconds\":%.2f,\"avg_display_fps\":%.2f,\"avg_mbps\":%.2f,\"decode_ms_avg\":%.2f,\"decode_errors\":%d}",
                       tReceived, tDecoded, tDisplayed, span, fps, span > 0 ? Double(tBytes) * 8 / span / 1e6 : 0,
                       tDecoded > 0 ? Double(tDecodeNanos) / Double(tDecoded) / 1e6 : 0, decodeErrors)
        return (j, fps)
    }
}
