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
    /// Gesture -> MacBook action (two-finger swipe -> next/previous desktop).
    var onAction: ((InputAction) -> Void)?
    private(set) var forwarded = 0
    private var dockProgress: Double = 0, dockVelocity: Double = 0
    static let debug = CommandLine.arguments.contains("--log-scroll")
    var forwardGestures = true
    var onGesture: ((GestureEvent) -> Void)?

    /// Ids, process and window numbers and timestamps are machine-specific: not copied.
    static let skipFields: Set<Int> = [39, 40, 41, 43, 44, 45, 50, 53, 58, 85, 87, 169]

    static func capture(_ e: CGEvent) -> GestureEvent {
        var fields: [GestureEvent.Field] = []
        for i in 0...255 where !skipFields.contains(i) {
            guard let f = CGEventField(rawValue: UInt32(i)) else { continue }
            let iv = e.getIntegerValueField(f), dv = e.getDoubleValueField(f)
            if iv == 0 && dv == 0 { continue }
            fields.append(Double(iv) == dv ? .int(UInt8(i), iv) : .double(UInt8(i), dv))
        }
        return GestureEvent(fields: fields)
    }

    var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        // 30 = Dock control (undocumented): two-finger swipes between desktops.
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << 30) | (1 << 29)   // 29 = gesture companions of Magic Mouse scrolls
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
        if type.rawValue == 30 { return handleDock(event) }
        if type.rawValue == 29 {
            // Companion gesture events: left untouched here, copied to the MacBook so its
            // apps recognise swipes natively (Safari back/forward with its animation).
            if forwardGestures && isActive() { onGesture?(Self.capture(event)) }
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

    /// Dock control events while the mirror is in front: swallowed, so the iMac doesn't
    /// switch its own desktops; a completed two-finger swipe becomes a MacBook action.
    /// Fields (recorded from a Magic Mouse): 110 = 23 dock swipe, 132 = phase
    /// (1 began, 2 changed, 4 ended, 8 cancelled), 124 = progress, 129 = end velocity.
    private func handleDock(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        func f(_ i: UInt32) -> CGEventField { CGEventField(rawValue: i)! }
        if Self.debug {
            print("{\"event\":\"dock_event\",\"active\":\(isActive()),\"t110\":\(event.getIntegerValueField(f(110))),\"phase\":\(event.getIntegerValueField(f(132))),\"progress\":\(event.getDoubleValueField(f(124)))}")
        }
        guard isActive() else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(f(110)) == 23 else { return nil }   // other dock gestures: swallow
        let phase = event.getIntegerValueField(f(132))
        if phase == 1 { dockProgress = 0; dockVelocity = 0 }
        dockProgress = event.getDoubleValueField(f(124))
        let v = event.getDoubleValueField(f(129)); if v != 0 { dockVelocity = v }
        if phase == 4, let a = GestureRules.dockAction(progress: dockProgress, velocity: dockVelocity) {
            print("{\"event\":\"dock_swipe\",\"action\":\"\(a)\",\"progress\":\(dockProgress)}")
            onAction?(a)
        }
        return nil
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

    /// Self-test: replays a recorded one-finger scroll gesture (scrolls + companion gesture
    /// events, from --record-gestures output) over the mirror at `testPoint`.
    static func replayScrollGesture(from path: String, index: Int) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let recs = text.split(separator: "\n").compactMap { l -> [String: Any]? in
            guard l.hasPrefix("{\"event\":\"rec\"") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any]
        }
        var n = 0, start = -1, end = recs.count
        for (i, r) in recs.enumerated() where (r["type"] as? Double) == 22 && (r["phase"] as? Double) == 1 {
            n += 1
            if n == index { start = i } else if n == index + 1 { end = i; break }
        }
        guard start >= 0 else { return 0 }
        var s = start; while s > 0 && (recs[s - 1]["type"] as? Double) == 29 { s -= 1 }
        let p = testPoint, src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(150_000)
        var posted = 0
        for r in recs[s..<end] {
            if (r["type"] as? Double) == 29, let f = r["fields"] as? [String: [Double]], let e = CGEvent(source: nil) {
                for (k, v) in f.sorted(by: { a, _ in a.key == "55" }) {
                    guard let i = Int(k), !skipFields.contains(i), let field = CGEventField(rawValue: UInt32(i)) else { continue }
                    if v[0] == v[1] { e.setIntegerValueField(field, value: Int64(v[0])) } else { e.setDoubleValueField(field, value: v[1]) }
                }
                e.location = p; e.post(tap: .cghidEventTap)
            } else if (r["type"] as? Double) == 22 {
                let px = Int32(r["px"] as? Double ?? 0), py = Int32(r["py"] as? Double ?? 0)
                guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: py, wheel2: px, wheel3: 0) else { continue }
                e.location = p
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: Int64(r["continuous"] as? Double ?? 1))
                e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: r["fx"] as? Double ?? 0)
                e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: r["fy"] as? Double ?? 0)
                e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(px))
                e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(py))
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(r["phase"] as? Double ?? 0))
                e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(r["momentum"] as? Double ?? 0))
                e.post(tap: .cghidEventTap); posted += 1
                usleep(8_000)
            }
        }
        return posted
    }

    /// Self-test: replays the first recorded dock swipe (from --record-gestures output) here.
    static func replayDockSwipe(from path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let skip: Set<Int> = [39, 40, 45, 50, 58, 85, 87, 169]
        var n = 0, started = false
        for line in text.split(separator: "\n") where line.contains("\"type\":30") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let f = d["fields"] as? [String: [Double]], let e = CGEvent(source: nil) else { continue }
            if f["132"]?[0] == 1 { if started { break }; started = true }
            // The event type (field 55) first: setting it later resets type-specific fields.
            for (k, v) in f.sorted(by: { a, _ in a.key == "55" }) {
                guard let i = Int(k), !skip.contains(i), let field = CGEventField(rawValue: UInt32(i)) else { continue }
                if v[0] == v[1] { e.setIntegerValueField(field, value: Int64(v[0])) } else { e.setDoubleValueField(field, value: v[1]) }
            }
            e.post(tap: .cghidEventTap); n += 1
            usleep(16_000)
        }
        return n
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
