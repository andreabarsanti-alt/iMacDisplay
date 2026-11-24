import AppKit

/// Menu bar status item used by both apps: shows the session state and offers Quit.
public final class StatusItem {
    public enum State: String {
        case waiting = "Waiting"
        case connected = "Connected"
        case reconnecting = "Reconnecting"
        case paused = "Paused"
        case stopped = "Stopped"

        var symbol: String {
            switch self {
            case .waiting: return "display"
            case .connected: return "display.and.arrow.down"
            case .reconnecting: return "arrow.triangle.2.circlepath"
            case .paused: return "pause.rectangle"
            case .stopped: return "xmark.rectangle"
            }
        }
    }

    private let item: NSStatusItem
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let title: String
    public private(set) var state: State = .waiting
    /// Every state change, for logs and tests.
    public var onChange: ((State) -> Void)?

    /// Called when the user picks Quit.
    public var onQuit: (() -> Void)? { get { target.onQuit } set { target.onQuit = newValue } }

    public init(title: String) {
        self.title = title
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let header = NSMenuItem(title: "RemoteMirror: \(title)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(.separator())
        toggleAnchor = menu.items.count
        let quit = NSMenuItem(title: "Quit", action: #selector(Target.quit), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
        item.menu = menu
        set(.waiting)
    }

    public func set(_ s: State) {
        let run = {
            guard self.state != s || self.stateLine.title.isEmpty else { return }
            self.state = s
            self.stateLine.title = s.rawValue
            self.item.button?.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.rawValue)
            self.item.button?.toolTip = "RemoteMirror: \(s.rawValue)"
            self.onChange?(s)
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private var toggleAnchor = 0

    /// Adds an on/off menu item above Quit; `onChange` gets the new state.
    public func addToggle(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        let item = NSMenuItem(title: title, action: #selector(Target.toggle(_:)), keyEquivalent: "")
        item.target = target
        item.state = isOn ? .on : .off
        target.toggles[ObjectIdentifier(item)] = onChange
        self.item.menu?.insertItem(item, at: toggleAnchor)
        toggleAnchor += 1
    }

    /// Adds a plain menu item at the top (e.g. "Update available…").
    public func addAction(_ title: String, handler: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(Target.action(_:)), keyEquivalent: "")
        item.target = target
        target.actions[ObjectIdentifier(item)] = handler
        self.item.menu?.insertItem(item, at: 0)
        self.item.menu?.insertItem(.separator(), at: 1)
        toggleAnchor += 2
    }

    private let target = Target()
    private final class Target: NSObject {
        var onQuit: (() -> Void)?
        var actions: [ObjectIdentifier: () -> Void] = [:]
        @objc func action(_ sender: NSMenuItem) { actions[ObjectIdentifier(sender)]?() }
        var toggles: [ObjectIdentifier: (Bool) -> Void] = [:]
        @objc func quit() { onQuit?() }
        @objc func toggle(_ sender: NSMenuItem) {
            sender.state = sender.state == .on ? .off : .on
            toggles[ObjectIdentifier(sender)]?(sender.state == .on)
        }
    }
}
