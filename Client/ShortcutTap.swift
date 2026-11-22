import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Shared

/// Global keyboard event tap (needs Accessibility on the iMac). While the mirror
/// window is active, it takes every key event before macOS acts on it, so system
/// shortcuts (Cmd-Tab, Cmd-Space, Mission Control...) go to the MacBook instead of
/// the iMac. Ctrl-Option-Cmd-Q is the escape hatch and always ends the session.
final class ShortcutTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isActive: () -> Bool = { false }
    var onEvent: ((InputEvent) -> Void)?
    var onEscape: (() -> Void)?
    private(set) var forwarded = 0

    var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: { _, type, event, refcon in
                                            let me = Unmanaged<ShortcutTap>.fromOpaque(refcon!).takeUnretainedValue()
                                            return me.handle(type, event)
                                        }, userInfo: refcon) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow taps; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isActive() else { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let escape: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if type == .keyDown, code == UInt16(kVK_ANSI_Q), flags.contains(escape) {
            onEscape?()
            return nil
        }
        if type == .keyUp, code == UInt16(kVK_ANSI_Q), flags.contains(escape) { return nil }
        let kind: InputKind = type == .keyDown ? .keyDown : type == .keyUp ? .keyUp : .flagsChanged
        onEvent?(InputEvent(kind: kind, flags: UInt32(truncatingIfNeeded: flags.rawValue), code: code))
        forwarded += 1
        return nil   // swallowed: the iMac never sees it
    }

    /// Self-test: posts Cmd-Tab and Cmd-Space as if typed on the iMac keyboard.
    static func postTestShortcuts() {
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: Int, _ down: Bool, _ flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags; e?.post(tap: .cghidEventTap)
        }
        for k in [kVK_Tab, kVK_Space] {
            key(kVK_Command, true, .maskCommand)
            key(k, true, .maskCommand); key(k, false, .maskCommand)
            key(kVK_Command, false, [])
        }
    }

    /// Self-test: posts the escape combination.
    static func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        let f: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true); d?.flags = f; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false); u?.flags = f; u?.post(tap: .cghidEventTap)
    }
}
