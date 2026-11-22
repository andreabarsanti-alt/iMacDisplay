import AppKit
import Darwin
import HostCore
import Shared

/// M10 acceptance tests run inside the app (launch arguments):
///   --self-test-cycles <n> [--synthetic] [--with-client]   n start/stop cycles
///   --self-test-error permission|unplug [--synthetic]      error paths
/// Prints JSON lines and PASS/FAIL, then quits.
@MainActor
enum SelfTest {
    static func runIfRequested(_ m: HostAppModel) {
        let args = CommandLine.arguments
        func value(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        m.synthetic = args.contains("--synthetic")
        m.log = { line in if args.contains("--verbose") { print(line) } }
        setvbuf(stdout, nil, _IOLBF, 0)
        if let n = value("--self-test-cycles").flatMap(Int.init) {
            Task { await cycles(m, n: n, withClient: args.contains("--with-client")) }
        } else if let kind = value("--self-test-error") {
            Task { await errorPath(m, kind: kind) }
        }
    }

    static func waitFor(_ m: HostAppModel, timeout: Double, _ cond: @escaping (HostState) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond(m.state) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond(m.state)
    }

    static func stop(_ m: HostAppModel) async -> Double {
        let t0 = Date()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in m.stop(reason: "self-test") { k.resume() } }
        return Date().timeIntervalSince(t0) * 1000
    }

    /// True if nothing accepts connections on the port (connect is refused).
    /// Closed connections may linger in TIME_WAIT; that doesn't count as "left behind".
    static func nothingListening(_ port: UInt16, host: String = WireProtocol.hostAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r != 0 && errno == ECONNREFUSED
    }

    /// True if nothing is listening on the port (we can bind it ourselves).
    static func portFree(_ port: UInt16, host: String = WireProtocol.hostAddress) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r == 0
    }

    /// Polls until nothing listens on either port any more (max 2 s).
    static func portsFreed() async -> (Bool, Double) {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 2 {
            if nothingListening(WireProtocol.videoPort) && nothingListening(WireProtocol.inputPort) { return (true, Date().timeIntervalSince(t0) * 1000) }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return (false, 2000)
    }

    static func cycles(_ m: HostAppModel, n: Int, withClient: Bool) async {
        var failures: [String] = []
        var stopTimes: [Double] = []
        for i in 1...n {
            m.start()
            let target: (HostState) -> Bool = withClient ? { $0 == .sharing } : { $0 == .waiting }
            let reached = await waitFor(m, timeout: withClient ? 15 : 5, target)
            if !reached { failures.append("cycle \(i): did not reach \(withClient ? "Sharing" : "Waiting") (state \(m.state.label))") }
            if withClient && reached { try? await Task.sleep(nanoseconds: 500_000_000) }   // stream a little
            let ms = await stop(m)
            stopTimes.append(ms)
            let idle = m.state == .idle
            let (free, freeMs) = await portsFreed()
            let capturing = m.session?.isCapturing ?? false
            print(String(format: "{\"event\":\"cycle\",\"n\":%d,\"reached\":%@,\"stop_ms\":%.0f,\"idle\":%@,\"ports_free\":%@,\"ports_free_after_ms\":%.0f,\"capturing\":%@}",
                         i, reached ? "true" : "false", ms, idle ? "true" : "false", free ? "true" : "false", freeMs, capturing ? "true" : "false"))
            if ms >= 1000 { failures.append(String(format: "cycle %d: stop took %.0f ms", i, ms)) }
            if !idle { failures.append("cycle \(i): state after stop is \(m.state.label)") }
            if !free { failures.append("cycle \(i): a port is still in use 2 s after stop") }
            if capturing { failures.append("cycle \(i): capture still running") }
        }
        let maxStop = stopTimes.max() ?? 0
        print(String(format: "{\"event\":\"cycles_summary\",\"cycles\":%d,\"max_stop_ms\":%.0f,\"avg_stop_ms\":%.0f}",
                     n, maxStop, stopTimes.reduce(0, +) / Double(max(stopTimes.count, 1))))
        finish(failures)
    }

    static func errorPath(_ m: HostAppModel, kind: String) async {
        var failures: [String] = []
        switch kind {
        case "permission":
            m.simulateMissingPermission = "screen_recording"
            m.synthetic = false
            m.start()
            let ok = await waitFor(m, timeout: 5) { if case .error = $0 { return true }; return false }
            print("{\"event\":\"error_path\",\"kind\":\"permission\",\"state\":\"\(m.state.label)\"}")
            if !ok || !m.state.label.contains("Screen Recording") { failures.append("expected a Screen Recording error, got \(m.state.label)") }
        case "unplug":
            m.start()
            if !(await waitFor(m, timeout: 5) { $0 == .waiting }) { failures.append("did not start (state \(m.state.label))") }
            m.linkCheckAddress = "10.255.255.254"     // as if 10.77.0.1 disappeared
            let t0 = Date()
            let ok = await waitFor(m, timeout: 5) { if case .error = $0 { return true }; return false }
            print(String(format: "{\"event\":\"error_path\",\"kind\":\"unplug\",\"state\":\"%@\",\"detect_ms\":%.0f}", m.state.label, Date().timeIntervalSince(t0) * 1000))
            if !ok || !m.state.label.contains("cable") { failures.append("expected a cable error, got \(m.state.label)") }
        default:
            failures.append("unknown error path \(kind)")
        }
        let (free, freeMs) = await portsFreed()
        print("{\"event\":\"after_error\",\"ports_free\":\(free),\"ports_free_after_ms\":\(Int(freeMs)),\"capturing\":\(m.session?.isCapturing ?? false)}")
        if !free { failures.append("a port is still in use after the error") }
        if m.session?.isCapturing ?? false { failures.append("capture still running after the error") }
        finish(failures)
    }

    static func finish(_ failures: [String]) {
        if failures.isEmpty { print("PASS") } else { failures.forEach { print("FAIL: \($0)") } }
        exit(failures.isEmpty ? 0 : 1)
    }
}
