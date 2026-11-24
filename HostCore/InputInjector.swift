import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// Turns InputEvents from the iMac into CGEvents on the MacBook.
/// Tracks held keys so everything can be released on stop (no stuck keys).
public final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var enabled = true
    private let lock = NSLock()
    /// Dead man's switch: if set, injection stops by itself at this uptime.
    private var deadline: UInt64?

    public var log: ((String) -> Void)?
    public private(set) var injectedCount = 0

    public init(deadManSeconds: Double? = nil) {
        if let s = deadManSeconds { deadline = DispatchTime.now().uptimeNanoseconds + UInt64(s * 1e9) }
    }

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func inject(_ e: InputEvent) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if let d = deadline, DispatchTime.now().uptimeNanoseconds > d {
            log?("{\"event\":\"dead_man_switch\",\"action\":\"injection stopped\"}")
            releaseAllLocked(); enabled = false; return
        }
        switch e.kind {
        case .keyDown, .keyUp:
            let down = e.kind == .keyDown
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.code, keyDown: down) else { return }
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            ev.post(tap: .cghidEventTap)
            if down { heldKeys.insert(e.code) } else { heldKeys.remove(e.code) }
        case .flagsChanged:
            // Modifier key press/release: a keyboard event carrying the new flag state.
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.code, keyDown: true) else { return }
            ev.type = .flagsChanged
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            ev.post(tap: .cghidEventTap)
        case .mouseMove, .mouseDown, .mouseUp:
            injectMouse(e)
        case .scroll:
            injectScroll(e)
        case .action:
            if let a = InputAction(rawValue: e.code) { performAction(a) }
        }
        injectedCount += 1
    }

    /// Test-only switch (RM_NO_MOUSE_DELTAS=1) to prove the screenshot test detects the bug.
    static let deltasDisabled = ProcessInfo.processInfo.environment["RM_NO_MOUSE_DELTAS"] != nil

    /// The display being shared; mouse coordinates are relative to it.
    public var displayID: CGDirectDisplayID = CGMainDisplayID()

    /// Normalized video coordinates (origin top-left) -> global display points.
    public func displayPoint(nx: Float32, ny: Float32) -> CGPoint { Self.displayPoint(nx: nx, ny: ny, display: displayID) }

    public static func displayPoint(nx: Float32, ny: Float32, display: CGDirectDisplayID = CGMainDisplayID()) -> CGPoint {
        let b = CGDisplayBounds(display)
        let x = b.minX + CGFloat(min(max(nx, 0), 1)) * b.width
        let y = b.minY + CGFloat(min(max(ny, 0), 1)) * b.height
        // Keep inside the display (the far edge itself is off-screen).
        return CGPoint(x: min(x, b.maxX - 1), y: min(y, b.maxY - 1))
    }

    private func injectMouse(_ e: InputEvent) {
        let p = displayPoint(nx: e.x, ny: e.y)
        let previousPoint = lastPoint == .zero ? p : lastPoint   // first event: no jump from (0,0)
        lastPoint = p
        let button = Int(e.code & 0xff), clicks = Int(e.code >> 8)
        let cgButton: CGMouseButton = button == 0 ? .left : button == 1 ? .right : .center
        let type: CGEventType
        switch e.kind {
        case .mouseDown:
            type = button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown
            heldButtons.insert(button)
        case .mouseUp:
            type = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            heldButtons.remove(button)
        default:
            if heldButtons.contains(0) { type = .leftMouseDragged }
            else if heldButtons.contains(1) { type = .rightMouseDragged }
            else if !heldButtons.isEmpty { type = .otherMouseDragged }
            else { type = .mouseMoved }
        }
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        // Movement since the previous event. Most apps only read the position, but some
        // (e.g. the screenshot toolbar's move/resize handles) only read these deltas:
        // without them a drag looks like no movement at all (feedback item 5).
        if !Self.deltasDisabled && (type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged) {
            ev.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - previousPoint.x).rounded()))
            ev.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - previousPoint.y).rounded()))
            ev.setDoubleValueField(.mouseEventDeltaX, value: Double(p.x - previousPoint.x))
            ev.setDoubleValueField(.mouseEventDeltaY, value: Double(p.y - previousPoint.y))
        }

        if button >= 2 { ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        if e.kind != .mouseMove { ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1))) }
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        ev.post(tap: .cghidEventTap)
    }

    /// Sub-pixel remainders carried between precise scroll events (AppKit reads whole
    /// pixels from injected events; slow Magic Mouse scrolls are often < 0.5 px per event).
    private var scrollRemainder = (x: Float32(0), y: Float32(0))

    /// Whole pixels to send now, keeping the fraction for the next event, so the total
    /// distance is exact. Pure, unit-tested.
    public static func carry(_ value: Float32, _ remainder: inout Float32) -> Int32 {
        let total = value + remainder
        let whole = total.rounded(.towardZero)
        remainder = total - whole
        return Int32(whole)
    }

    private func injectScroll(_ e: InputEvent) {
        let sc = ScrollCode(code: e.code)
        if sc.phase == 1 || sc.momentum == 1 { scrollRemainder = (0, 0) }     // new gesture or new momentum run
        let dyI = sc.precise ? Self.carry(e.dy, &scrollRemainder.y) : Int32(e.dy.rounded())
        let dxI = sc.precise ? Self.carry(e.dx, &scrollRemainder.x) : Int32(e.dx.rounded())
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: sc.precise ? .pixel : .line, wheelCount: 2,
                               wheel1: dyI, wheel2: dxI, wheel3: 0) else { return }
        ev.location = displayPoint(nx: e.x, ny: e.y)
        lastPoint = ev.location
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        if sc.precise {
            // Exact (fractional) pixel deltas: slow Magic Mouse movements are often < 0.5 px
            // per event and were lost by rounding.
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(e.dy))
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(e.dx))
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dyI))
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dxI))
        }
        if !Self.phasesDisabled {
            ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(sc.phase))
            ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(sc.momentum))
        }
        ev.post(tap: .cghidEventTap)
    }

    /// Test-only (RM_NO_SCROLL_PHASES=1): drop phases, to prove the swipe test detects it.
    static let phasesDisabled = ProcessInfo.processInfo.environment["RM_NO_SCROLL_PHASES"] != nil

    /// Re-posts a companion gesture event from the iMac at the current pointer position,
    /// so the following scroll events are treated like a real Magic Mouse gesture.
    public private(set) var gesturesInjected = 0
    public func injectGesture(_ g: GestureEvent) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !Self.gesturesDisabled, let ev = CGEvent(source: nil) else { return }
        // The event type (field 55) first: setting it later resets type-specific fields.
        for f in g.fields.sorted(by: { a, _ in a.index == 55 }) {
            guard let field = CGEventField(rawValue: UInt32(f.index)) else { continue }
            if f.isDouble { ev.setDoubleValueField(field, value: f.doubleValue) } else { ev.setIntegerValueField(field, value: f.intValue) }
        }
        ev.location = lastPoint == .zero ? (CGEvent(source: nil)?.location ?? .zero) : lastPoint
        ev.post(tap: .cghidEventTap)
        gesturesInjected += 1
    }

    /// Test-only (RM_NO_GESTURES=1): drop companion gestures, to prove the test detects it.
    static let gesturesDisabled = ProcessInfo.processInfo.environment["RM_NO_GESTURES"] != nil

    /// Gestures from the iMac as shortcuts on this Mac. Back/Forward are resolved for the
    /// current keyboard layout (localized Cmd-[ / Cmd-]); Spaces and Mission Control use the
    /// default Mission Control shortcuts (Ctrl-arrows), which are layout-independent.
    public private(set) var lastAction: String?

    private func performAction(_ a: InputAction) {
        var key: ShortcutResolver.Key?
        switch a {
        case .back, .forward:
            let ch = a == .back ? "[" : "]"
            if Thread.isMainThread { key = ShortcutResolver.key(forCommandCharacter: ch) }
            else { DispatchQueue.main.sync { key = ShortcutResolver.key(forCommandCharacter: ch) } }
            if key == nil { key = .init(code: a == .back ? 33 : 30, flags: .maskCommand) }   // US fallback
        case .nextSpace:
            key = SymbolicHotkeys.key(id: SymbolicHotkeys.moveRightSpace,
                                      fallback: .init(code: 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
        case .previousSpace:
            key = SymbolicHotkeys.key(id: SymbolicHotkeys.moveLeftSpace,
                                      fallback: .init(code: 123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
        case .missionControl:
            key = SymbolicHotkeys.key(id: SymbolicHotkeys.missionControl,
                                      fallback: .init(code: 126, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
        }
        guard let k = key else { return }
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: down)
            ev?.flags = k.flags
            ev?.post(tap: .cghidEventTap)
        }
        lastAction = "\(a) -> keycode \(k.code) flags \(k.flags.rawValue)"
        log?("{\"event\":\"action\",\"action\":\"\(a)\",\"keycode\":\(k.code),\"flags\":\(k.flags.rawValue)}")
    }

    /// Releases held keys/buttons but keeps injecting (client dropped, may reconnect).
    public func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        releaseAllLocked()
    }

    /// Releases held keys and clears modifiers; called on every stop path.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        releaseAllLocked()
        enabled = false
    }

    private func releaseAllLocked() {
        for k in heldKeys {
            CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap)
        }
        if !heldKeys.isEmpty { log?("{\"event\":\"released_keys\",\"count\":\(heldKeys.count)}") }
        for b in heldButtons {
            let type: CGEventType = b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp
            let btn: CGMouseButton = b == 0 ? .left : b == 1 ? .right : .center
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: btn)?.post(tap: .cghidEventTap)
        }
        if !heldButtons.isEmpty { log?("{\"event\":\"released_buttons\",\"count\":\(heldButtons.count)}") }
        heldButtons.removeAll()
        heldKeys.removeAll()
        if let ev = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false) {   // clear modifiers
            ev.type = .flagsChanged; ev.flags = []; ev.post(tap: .cghidEventTap)
        }
    }
}
