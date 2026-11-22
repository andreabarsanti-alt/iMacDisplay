import AppKit

/// M6 test target: a window with target squares at known positions. Records every
/// click (global top-left points, button, click count) and scroll totals.
final class MouseTestWindow {
    struct Click { let point: CGPoint; let button: Int; let clicks: Int }

    final class TestView: NSView {
        var clicks: [Click] = []
        var scrollY: CGFloat = 0, scrollX: CGFloat = 0, scrollEvents = 0
        let targets: [CGRect]   // view coordinates

        init(frame: NSRect, targets: [CGRect]) {
            self.targets = targets
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            for t in targets {
                let l = CALayer(); l.frame = t; l.backgroundColor = NSColor.systemBlue.cgColor
                layer?.addSublayer(l)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func record(_ e: NSEvent) {
            let p = NSEvent.mouseLocation   // global, bottom-left origin
            let top = NSScreen.screens.first!.frame.maxY
            clicks.append(Click(point: CGPoint(x: p.x, y: top - p.y), button: e.buttonNumber, clicks: e.clickCount))
        }
        override func mouseDown(with e: NSEvent) { record(e) }
        override func rightMouseDown(with e: NSEvent) { record(e) }
        override func otherMouseDown(with e: NSEvent) { record(e) }
        override func scrollWheel(with e: NSEvent) { scrollX += e.scrollingDeltaX; scrollY += e.scrollingDeltaY; scrollEvents += 1 }
    }

    private let window: NSWindow
    let view: TestView

    init() {
        let size = NSSize(width: 700, height: 440)
        let t = CGSize(width: 40, height: 40)
        let rects = [CGPoint(x: 30, y: 30), CGPoint(x: 630, y: 30), CGPoint(x: 330, y: 200),
                     CGPoint(x: 30, y: 370), CGPoint(x: 630, y: 370)].map { CGRect(origin: $0, size: t) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RemoteMirror mouse test"
        window.level = .floating
        window.isReleasedWhenClosed = false
        view = TestView(frame: NSRect(origin: .zero, size: size), targets: rects)
        window.contentView = view
        window.center()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func close() { window.close() }

    /// Target centres in global display points (top-left origin).
    var targetCentres: [CGPoint] {
        let top = NSScreen.screens.first!.frame.maxY
        return view.targets.map { r in
            let c = window.convertPoint(toScreen: view.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
            return CGPoint(x: c.x, y: top - c.y)
        }
    }

    /// "nx,ny;nx,ny;..." normalized to the main display, for the client's script.
    var spec: String {
        let b = CGDisplayBounds(CGMainDisplayID())
        return targetCentres.map { String(format: "%.6f,%.6f", ($0.x - b.minX) / b.width, ($0.y - b.minY) / b.height) }
            .joined(separator: ";")
    }

    /// Checks the client's scripted sequence: one left click per target (±2 pt),
    /// a right click on target 0, a double click on target 1, and some scrolling.
    func evaluate() -> (json: String, failures: [String]) {
        let centres = targetCentres
        var failures: [String] = []
        var maxErr: CGFloat = 0
        func nearest(_ p: CGPoint) -> (Int, CGFloat) {
            centres.enumerated().map { ($0.offset, hypot($0.element.x - p.x, $0.element.y - p.y)) }.min { $0.1 < $1.1 }!
        }
        var leftHits = Set<Int>()
        var right0 = false, double1 = false
        for c in view.clicks {
            let (i, err) = nearest(c.point)
            maxErr = max(maxErr, err)
            if err > 2 { failures.append(String(format: "click at (%.1f,%.1f) is %.1f pt from target %d", c.point.x, c.point.y, err, i)) }
            if c.button == 0 { leftHits.insert(i) }
            if c.button == 1 && i == 0 { right0 = true }
            if c.button == 0 && c.clicks == 2 && i == 1 { double1 = true }
        }
        if leftHits.count != centres.count { failures.append("left clicks hit \(leftHits.count)/\(centres.count) targets") }
        if !right0 { failures.append("no right click on target 0") }
        if !double1 { failures.append("no double click on target 1") }
        if view.scrollEvents == 0 || view.scrollY == 0 { failures.append("no scrolling received") }
        let json = String(format: "{\"event\":\"mouse_test\",\"clicks\":%d,\"max_error_pt\":%.2f,\"scroll_events\":%d,\"scroll_y\":%.1f,\"scroll_x\":%.1f}",
                          view.clicks.count, maxErr, view.scrollEvents, view.scrollY, view.scrollX)
        return (json, failures)
    }
}
