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
    /// Ctrl-Option-Cmd-Z: hide/show the mirror without disconnecting. Seen even while hidden.
    var onPauseToggle: (() -> Void)?
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
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let escape: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if code == UInt16(kVK_ANSI_Z), flags.contains(escape), type == .keyDown || type == .keyUp {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onPauseToggle?() }
            return nil
        }
        guard isActive() else { return Unmanaged.passUnretained(event) }
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

    /// Self-test: posts Ctrl-Cmd-Shift-4 (screenshot of a selection, to the clipboard).
    static func postScreenshotShortcut() {
        let src = CGEventSource(stateID: .hidSystemState)
        let f: CGEventFlags = [.maskControl, .maskCommand, .maskShift]
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_4), keyDown: true); d?.flags = f; d?.post(tap: .cghidEventTap)
        usleep(30_000)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_4), keyDown: false); u?.flags = f; u?.post(tap: .cghidEventTap)
    }

    /// Self-test: a Magic-Mouse-like horizontal swipe (continuous scroll with gesture
    /// phases, then momentum) at the centre of the iMac's screen, over the mirror.
    /// Where test scrolls are posted, as a fraction of the iMac screen (RM_SCROLL_AT="0.3,0.3").
    static var testPoint: CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        let f = (ProcessInfo.processInfo.environment["RM_SCROLL_AT"] ?? CommandLine.arguments.firstIndex(of: "--scroll-at")
            .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "0.5,0.5")
            .split(separator: ",").compactMap { Double($0) }
        return CGPoint(x: b.minX + b.width * (f.first ?? 0.5), y: b.minY + b.height * (f.count > 1 ? f[1] : 0.5))
    }

    /// Diagnostic: a left click at `testPoint`.
    static func postTestClick() {
        let p = testPoint
        let src = CGEventSource(stateID: .hidSystemState)
        for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
        }
    }

    static func postSyntheticSwipe(right: Bool) {
        let p = testPoint
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        let sign: Double = right ? 1 : -1
        func scroll(_ dx: Double, _ phase: Int64, _ momentum: Int64) {
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0,
                                  wheel2: Int32((dx * sign).rounded()), wheel3: 0) else { return }
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx * sign)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            e.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        scroll(0.4, 1, 0)                                                          // began (sub-pixel!)
        for d in [6.0, 10, 14, 18, 22, 24, 24, 22, 20, 18] { scroll(d, 2, 0) }     // changed
        scroll(0, 4, 0)                                                            // ended
        scroll(16, 0, 1)                                                           // momentum begin
        for d in [14.0, 11, 8, 6, 4, 2, 1] { scroll(d, 0, 2) }                     // momentum continue
        scroll(0, 0, 3)                                                            // momentum end
    }

    /// Diagnostic: three scroll variants over the mirror, tagged by their horizontal size:
    /// 3 lines (wheel), 7 px continuous without phases, 11 px continuous with phases.
    static func postScrollVariants() {
        let p = testPoint
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: 0, wheel2: 3, wheel3: 0) {
            e.location = p; e.post(tap: .cghidEventTap)
        }
        usleep(300_000)
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 7, wheel3: 0) {
            e.location = p; e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1); e.post(tap: .cghidEventTap)
        }
        usleep(300_000)
        for (dx, ph) in [(Int32(11), Int64(1)), (11, 2), (0, 4)] {
            if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0) {
                e.location = p; e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: ph); e.post(tap: .cghidEventTap)
            }
            usleep(20_000)
        }
    }

    /// Self-test: posts the pause combination.
    static func postPause() {
        let src = CGEventSource(stateID: .hidSystemState)
        let f: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true); d?.flags = f; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: false); u?.flags = f; u?.post(tap: .cghidEventTap)
    }

    /// Self-test: posts the escape combination.
    static func postEscape() {
        let src = CGEventSource(stateID: .hidSystemState)
        let f: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true); d?.flags = f; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false); u?.flags = f; u?.post(tap: .cghidEventTap)
    }
}
