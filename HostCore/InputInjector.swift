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
        }
        injectedCount += 1
    }

    /// Normalized video coordinates (origin top-left) -> global display points.
    public static func displayPoint(nx: Float32, ny: Float32) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        let x = b.minX + CGFloat(min(max(nx, 0), 1)) * b.width
        let y = b.minY + CGFloat(min(max(ny, 0), 1)) * b.height
        // Keep inside the display (the far edge itself is off-screen).
        return CGPoint(x: min(x, b.maxX - 1), y: min(y, b.maxY - 1))
    }

    private func injectMouse(_ e: InputEvent) {
        let p = Self.displayPoint(nx: e.x, ny: e.y)
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
        if button >= 2 { ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        if e.kind != .mouseMove { ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1))) }
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        ev.post(tap: .cghidEventTap)
    }

    private func injectScroll(_ e: InputEvent) {
        let precise = e.code == 1
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line, wheelCount: 2,
                               wheel1: Int32(e.dy.rounded()), wheel2: Int32(e.dx.rounded()), wheel3: 0) else { return }
        ev.location = Self.displayPoint(nx: e.x, ny: e.y)
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        ev.post(tap: .cghidEventTap)
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
