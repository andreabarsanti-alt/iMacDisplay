import AppKit
import WebKit

/// Swipe/scroll test target (feedback: Magic Mouse swipes). Logs every scroll event the
/// MacBook delivers (phase, momentum, deltas) and recognises "swipe between pages" the
/// way Safari/Finder do: NSEvent.trackSwipeEvent on a horizontal scroll that *begins*.
final class ScrollTestWindow {
    final class SwipeView: NSView {
        var events: [String] = []
        var phases = Set<UInt>(), momentum = Set<UInt>()
        var swipesLeft = 0, swipesRight = 0, swipeAttempts = 0
        var totalX: CGFloat = 0, totalY: CGFloat = 0
        var maxAmount: CGFloat = 0
        var endPhases: [String] = []

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool { axis == .horizontal }

        override func scrollWheel(with e: NSEvent) {
            phases.insert(e.phase.rawValue); momentum.insert(e.momentumPhase.rawValue)
            totalX += e.scrollingDeltaX; totalY += e.scrollingDeltaY
            if events.count < 400 {
                events.append(String(format: "{\"phase\":%lu,\"momentum\":%lu,\"dx\":%.1f,\"dy\":%.1f,\"precise\":%@}",
                                     e.phase.rawValue, e.momentumPhase.rawValue, e.scrollingDeltaX, e.scrollingDeltaY,
                                     e.hasPreciseScrollingDeltas ? "true" : "false"))
            }
            guard e.phase == .began, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY),
                  NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }
            swipeAttempts += 1
            e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: -1, max: 1) {
                [weak self] amount, phase, complete, _ in
                guard let self else { return }
                self.maxAmount = max(self.maxAmount, abs(amount))
                if complete { self.endPhases.append(phase == .ended ? "ended" : phase == .cancelled ? "cancelled" : "\(phase.rawValue)") }
                guard complete else { return }
                // A completed swipe: AppKit reports it when the gesture ends past the threshold.
                if phase == .ended {
                    if amount > 0 { self.swipesRight += 1 } else if amount < 0 { self.swipesLeft += 1 }
                }
            }
        }
    }

    private let window: NSWindow
    let view = SwipeView(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
    /// WebKit with back/forward swipe gestures, like Safari: page A then page B.
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 440))
    let useWeb = CommandLine.arguments.contains("--swipe-web")
    var appWasActive = false

    init() {
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RemoteMirror swipe test"
        window.level = .floating
        window.isReleasedWhenClosed = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.3).cgColor
        if useWeb {
            web.allowsBackForwardNavigationGestures = true
            window.contentView = web
            // Real navigations (file URLs) so the web view has a back entry, like Safari.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rm-swipe-\(getpid())")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["A", "B"] { try? Self.page(n).write(to: dir.appendingPathComponent("\(n).html"), atomically: true, encoding: .utf8) }
            web.loadFileURL(dir.appendingPathComponent("A.html"), allowingReadAccessTo: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.web.loadFileURL(dir.appendingPathComponent("B.html"), allowingReadAccessTo: dir)
            }
        } else {
            window.contentView = view
        }
        window.center()
    }

    static func page(_ n: String) -> String {
        "<html><body style='font:80px -apple-system;background:\(n == "A" ? "#cde" : "#edc")'>Page \(n)</body></html>"
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(useWeb ? web : view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.appWasActive = NSApp.isActive }
    }
    func close() { window.close() }

    /// Window centre, normalized to the main display (for the client's swipe script).
    var spec: String {
        let c = window.convertPoint(toScreen: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        let top = NSScreen.screens.first!.frame.maxY
        let b = CGDisplayBounds(CGMainDisplayID())
        return String(format: "%.5f,%.5f", (c.x - b.minX) / b.width, (top - c.y - b.minY) / b.height)
    }

    func summaryJSON() -> String {
        let v = view
        return "{\"event\":\"swipe_test\",\"scroll_events\":\(v.events.count),\"phases\":\(v.phases.sorted()),\"momentum\":\(v.momentum.sorted()),"
            + "\"swipe_attempts\":\(v.swipeAttempts),\"swipes_left\":\(v.swipesLeft),\"swipes_right\":\(v.swipesRight),"
            + String(format: "\"total_dx\":%.1f,\"total_dy\":%.1f,", v.totalX, v.totalY)
            + String(format: "\"max_amount\":%.2f,", v.maxAmount) + "\"end_phases\":\(v.endPhases),"
            + "\"app_active\":\(appWasActive),\"web_page\":\"\(useWeb ? (web.url?.host ?? "?") : "-")\",\"web_can_go_back\":\(web.canGoBack),"
            + "\"swipe_tracking_enabled\":\(NSEvent.isSwipeTrackingFromScrollEventsEnabled)}"
    }
}
