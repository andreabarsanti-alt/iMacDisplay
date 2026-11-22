import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// Turns InputEvents from the iMac into CGEvents on the MacBook.
/// Tracks held keys so everything can be released on stop (no stuck keys).
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldKeys = Set<UInt16>()
    private var enabled = true
    private let lock = NSLock()
    /// Dead man's switch: if set, injection stops by itself at this uptime.
    private var deadline: UInt64?

    var log: ((String) -> Void)?
    private(set) var injectedCount = 0

    init(deadManSeconds: Double? = nil) {
        if let s = deadManSeconds { deadline = DispatchTime.now().uptimeNanoseconds + UInt64(s * 1e9) }
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func inject(_ e: InputEvent) {
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
        case .mouseMove, .mouseDown, .mouseUp, .scroll:
            return   // M6
        }
        injectedCount += 1
    }

    /// Releases held keys and clears modifiers; called on every stop path.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        releaseAllLocked()
        enabled = false
    }

    private func releaseAllLocked() {
        for k in heldKeys {
            CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap)
        }
        if !heldKeys.isEmpty { log?("{\"event\":\"released_keys\",\"count\":\(heldKeys.count)}") }
        heldKeys.removeAll()
        if let ev = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false) {   // clear modifiers
            ev.type = .flagsChanged; ev.flags = []; ev.post(tap: .cghidEventTap)
        }
    }
}
