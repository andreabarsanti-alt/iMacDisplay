import AppKit

/// A small always-on-top window with continuous motion, so ScreenCaptureKit
/// (which only delivers frames when the screen changes) produces a steady frame rate.
final class TestPatternWindow {
    private let window: NSWindow
    private let box = NSView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var frame = 0

    init() {
        let rect = NSRect(x: 0, y: 0, width: 360, height: 220)
        window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RemoteMirror test pattern"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let content = NSView(frame: rect)
        content.wantsLayer = true
        box.frame = NSRect(x: 0, y: 80, width: 60, height: 60)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemOrange.cgColor
        label.frame = NSRect(x: 10, y: 10, width: 340, height: 40)
        label.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        content.addSubview(box); content.addSubview(label)
        window.contentView = content
        window.center()
    }

    func show() {
        window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() { timer?.invalidate(); window.close() }

    private func tick() {
        frame += 1
        let x = CGFloat((frame * 5) % 300)
        box.frame.origin.x = x
        let hue = CGFloat(frame % 120) / 120
        window.contentView?.layer?.backgroundColor = NSColor(hue: hue, saturation: 0.4, brightness: 0.9, alpha: 1).cgColor
        label.stringValue = String(format: "frame %06d", frame)
    }
}
