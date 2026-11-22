import AppKit
import Shared

/// Shown on the iMac while no session is running: "Waiting for MacBook".
final class IdleWindow {
    let window: NSWindow
    private let title = NSTextField(labelWithString: "Waiting for MacBook…")
    private let detail = NSTextField(labelWithString: "")

    init() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 190)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RemoteMirror"
        window.isReleasedWhenClosed = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.frame = NSRect(x: 24, y: 100, width: 60, height: 60)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 100, y: 128, width: 340, height: 28)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 100, y: 20, width: 340, height: 104)
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        let v = NSView(frame: rect)
        [icon, title, detail].forEach(v.addSubview)
        window.contentView = v
        setDetail(nil)
        window.center()
    }

    func setDetail(_ lastSession: String?) {
        var lines = ["MacBook at \(WireProtocol.hostAddress) over the Ethernet cable.",
                     "Press Start Sharing in the MacBook's menu bar."]
        if let lastSession { lines.append("Last session ended: \(lastSession)") }
        lines.append("While mirroring: Ctrl-Option-Cmd-Z pause · Ctrl-Option-Cmd-Q end")
        detail.stringValue = lines.joined(separator: "\n")
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }
    var isVisible: Bool { window.isVisible }
}
