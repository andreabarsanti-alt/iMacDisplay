import AppKit
import Carbon.HIToolbox
import Shared

/// Full-window view that captures keyboard input and forwards hardware keycodes.
/// Ctrl-Option-Cmd-Q is the escape hatch: never forwarded, ends the session.
final class InputView: NSView {
    var onEvent: ((InputEvent) -> Void)?
    var onEscape: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    /// Local pointer moved (normalized video coords): drives the zero-lag cursor overlay.
    var onLocalMove: ((Float32, Float32) -> Void)?
    /// Diagnostic (--log-scroll): print every scroll event the iMac delivers to the mirror.
    static let logScroll = CommandLine.arguments.contains("--log-scroll")

    override var acceptsFirstResponder: Bool { true }

    private static let escapeFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    private func flags(_ e: NSEvent) -> UInt32 {
        UInt32(truncatingIfNeeded: e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue))
    }

    private func isEscape(_ e: NSEvent) -> Bool {
        e.keyCode == UInt16(kVK_ANSI_Q) &&
            e.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: Self.escapeFlags)
    }

    private func isPause(_ e: NSEvent) -> Bool {
        e.keyCode == UInt16(kVK_ANSI_Z) &&
            e.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: Self.escapeFlags)
    }

    override func keyDown(with e: NSEvent) {
        if isEscape(e) { onEscape?(); return }
        if isPause(e) { if !e.isARepeat { onPauseToggle?() }; return }
        onEvent?(InputEvent(kind: .keyDown, flags: flags(e), code: e.keyCode))
    }

    override func keyUp(with e: NSEvent) {
        if isEscape(e) || isPause(e) { return }
        onEvent?(InputEvent(kind: .keyUp, flags: flags(e), code: e.keyCode))
    }

    override func flagsChanged(with e: NSEvent) {
        onEvent?(InputEvent(kind: .flagsChanged, flags: flags(e), code: e.keyCode))
    }

    // MARK: Mouse

    /// Size of the decoded video in pixels; set by the display when frames arrive.
    var videoSize = CGSize(width: 16, height: 10)

    /// The aspect-fit rect the video occupies inside this view (view coordinates).
    var videoRect: CGRect {
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0, b.width > 0, b.height > 0 else { return b }
        let scale = min(b.width / videoSize.width, b.height / videoSize.height)
        let w = videoSize.width * scale, h = videoSize.height * scale
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    /// View point -> normalized 0...1 in the video, origin top-left (clamped).
    func normalize(_ p: CGPoint) -> (Float32, Float32) {
        let r = videoRect
        let x = (p.x - r.minX) / r.width
        let y = 1 - (p.y - r.minY) / r.height        // AppKit views are bottom-up
        return (Float32(min(max(x, 0), 1)), Float32(min(max(y, 0), 1)))
    }

    /// Normalized video coordinates -> view point (inverse of `normalize`).
    func viewPoint(nx: Double, ny: Double) -> CGPoint {
        let r = videoRect
        return CGPoint(x: r.minX + nx * r.width, y: r.minY + (1 - ny) * r.height)
    }

    /// `code` packs the button number (low byte) and click count (high byte).
    static func mouseCode(button: Int, clicks: Int) -> UInt16 {
        UInt16(min(max(button, 0), 255)) | UInt16(min(max(clicks, 0), 255)) << 8
    }

    private func mouse(_ e: NSEvent, _ kind: InputKind) {
        let (x, y) = normalize(convert(e.locationInWindow, from: nil))
        onLocalMove?(x, y)
        onEvent?(InputEvent(kind: kind, flags: flags(e), code: Self.mouseCode(button: e.buttonNumber, clicks: e.clickCount),
                            x: x, y: y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with e: NSEvent) { mouse(e, .mouseMove) }
    override func mouseDragged(with e: NSEvent) { mouse(e, .mouseMove) }
    override func rightMouseDragged(with e: NSEvent) { mouse(e, .mouseMove) }
    override func otherMouseDragged(with e: NSEvent) { mouse(e, .mouseMove) }
    override func mouseDown(with e: NSEvent) { mouse(e, .mouseDown) }
    override func mouseUp(with e: NSEvent) { mouse(e, .mouseUp) }
    override func rightMouseDown(with e: NSEvent) { mouse(e, .mouseDown) }
    override func rightMouseUp(with e: NSEvent) { mouse(e, .mouseUp) }
    override func otherMouseDown(with e: NSEvent) { mouse(e, .mouseDown) }
    override func otherMouseUp(with e: NSEvent) { mouse(e, .mouseUp) }

    /// Scroll: dx/dy carry the deltas; code 1 = precise (pixel) deltas, 0 = line deltas.
    override func scrollWheel(with e: NSEvent) {
        if Self.logScroll {
            print(String(format: "{\"event\":\"client_scroll\",\"phase\":%lu,\"momentum\":%lu,\"dx\":%.2f,\"dy\":%.2f,\"precise\":%@}",
                         e.phase.rawValue, e.momentumPhase.rawValue, e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas ? "true" : "false"))
        }
        let (x, y) = normalize(convert(e.locationInWindow, from: nil))
        // Keep the gesture phase and momentum phase (Magic Mouse / trackpad): apps on the
        // MacBook use them for swipes, rubber-banding and inertia.
        let cg = e.cgEvent
        let sc = ScrollCode(precise: e.hasPreciseScrollingDeltas,
                            phase: UInt8(truncatingIfNeeded: cg?.getIntegerValueField(.scrollWheelEventScrollPhase) ?? 0),
                            momentum: UInt8(truncatingIfNeeded: cg?.getIntegerValueField(.scrollWheelEventMomentumPhase) ?? 0))
        onEvent?(InputEvent(kind: .scroll, flags: flags(e), code: sc.code,
                            x: x, y: y, dx: Float32(e.scrollingDeltaX), dy: Float32(e.scrollingDeltaY)))
    }

    /// Cmd-key combinations arrive here (menu key equivalents) instead of keyDown.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        keyDown(with: e)
        return true
    }
}

/// Scripted typing for the M5 test: maps characters to ANSI hardware keycodes.
/// Letters, digits and space sit on the same keys on US and Italian layouts.
enum KeyScript {
    static let shiftFlag: UInt32 = 0x0002_0000     // kCGEventFlagMaskShift
    static let map: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        " ": kVK_Space,
    ]

    /// Events to type `text`; returns nil if it contains an unsupported character.
    static func events(for text: String) -> [InputEvent]? {
        var out: [InputEvent] = []
        for ch in text {
            let lower = Character(ch.lowercased())
            guard let code = map[lower].map({ UInt16($0) }) else { return nil }
            let shift = ch.isUppercase
            if shift { out.append(InputEvent(kind: .flagsChanged, flags: shiftFlag, code: UInt16(kVK_Shift))) }
            let f = shift ? shiftFlag : 0
            out.append(InputEvent(kind: .keyDown, flags: f, code: code))
            out.append(InputEvent(kind: .keyUp, flags: f, code: code))
            if shift { out.append(InputEvent(kind: .flagsChanged, flags: 0, code: UInt16(kVK_Shift))) }
        }
        return out
    }
}
