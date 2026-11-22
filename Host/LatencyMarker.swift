import AppKit
import QuartzCore
import Shared

/// Borderless window near the top-left of the main screen showing the marker
/// counter, updated every display refresh. Records when each value was drawn.
final class LatencyMarkerWindow {
    static let cellPoints: CGFloat = 24

    private let window: NSWindow
    private var cellLayers: [CALayer] = []
    private var timer: Timer?
    private var counter: UInt32 = 0
    private let lock = NSLock()
    private var drawnAt: [UInt32: UInt64] = [:]   // value -> uptime nanos when set

    init() {
        let screen = NSScreen.main!
        let size = NSSize(width: CGFloat(Marker.cells) * Self.cellPoints, height: Self.cellPoints)
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.minX + 40, y: vf.maxY - 40 - size.height)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false, screen: screen)
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        for i in 0..<Marker.cells {
            let l = CALayer()
            l.frame = CGRect(x: CGFloat(i) * Self.cellPoints, y: 0, width: Self.cellPoints, height: Self.cellPoints)
            l.actions = ["backgroundColor": NSNull()]
            view.layer?.addSublayer(l)
            cellLayers.append(l)
        }
        window.contentView = view
    }

    /// Centre of each cell and cell size, in pixels of a full-display capture
    /// (`scale` = capture pixels per point; origin top-left).
    func markerSpec(captureWidth: Int, captureHeight: Int) -> String {
        let screen = NSScreen.main!
        let scale = CGFloat(captureWidth) / screen.frame.width
        let f = window.frame
        let x0 = (f.minX - screen.frame.minX) * scale
        let yTop = (screen.frame.maxY - f.maxY) * scale
        let cell = Self.cellPoints * scale
        // x of first cell centre, y of centre row, cell pitch (pixels)
        return String(format: "%.1f,%.1f,%.2f", x0 + cell / 2, yTop + cell / 2, cell)
    }

    func show() {
        window.orderFrontRegardless()
        set(0)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.counter = (self.counter + 1) & Marker.valueMask
            self.set(self.counter)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func close() { timer?.invalidate(); window.close() }

    /// Uptime nanos when `value` was drawn, if still remembered.
    func drawTime(_ value: UInt32) -> UInt64? { lock.lock(); defer { lock.unlock() }; return drawnAt[value] }

    private func set(_ value: UInt32) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bit) in Marker.bits(value).enumerated() {
            cellLayers[i].backgroundColor = bit ? CGColor.white : CGColor.black
        }
        CATransaction.commit()
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        drawnAt[value] = now
        if drawnAt.count > 600 { drawnAt = drawnAt.filter { now - $0.value < 5_000_000_000 } }
        lock.unlock()
    }
}

/// Collects latency samples and reports median / p95.
final class LatencyStats {
    private var samples: [Double] = []   // ms
    private let lock = NSLock()
    func add(_ ms: Double) { lock.lock(); samples.append(ms); lock.unlock() }

    func summary() -> (json: String, count: Int, median: Double, p95: Double) {
        lock.lock(); let s = samples.sorted(); lock.unlock()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        let j = String(format: "{\"event\":\"latency\",\"samples\":%d,\"min_ms\":%.1f,\"median_ms\":%.1f,\"p95_ms\":%.1f,\"max_ms\":%.1f}",
                       s.count, s.first ?? 0, pct(0.5), pct(0.95), s.last ?? 0)
        return (j, s.count, pct(0.5), pct(0.95))
    }
}
