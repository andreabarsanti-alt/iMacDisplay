import AppKit

/// M5 test target: a focused window with a text field. Its content is printed
/// on exit and compared with what the client typed.
final class InputTestWindow: NSObject, NSTextFieldDelegate {
    private let window: NSWindow
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 460, height: 32))

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 72), styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "RemoteMirror input test"
        window.isReleasedWhenClosed = false
        field.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        window.contentView?.addSubview(field)
        window.center()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    var text: String { field.stringValue }
    func close() { window.close() }
}
