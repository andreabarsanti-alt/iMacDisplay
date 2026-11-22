import AppKit
import Carbon.HIToolbox
import Shared

/// Full-window view that captures keyboard input and forwards hardware keycodes.
/// Ctrl-Option-Cmd-Q is the escape hatch: never forwarded, ends the session.
final class InputView: NSView {
    var onEvent: ((InputEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private static let escapeFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    private func flags(_ e: NSEvent) -> UInt32 {
        UInt32(truncatingIfNeeded: e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue))
    }

    private func isEscape(_ e: NSEvent) -> Bool {
        e.keyCode == UInt16(kVK_ANSI_Q) &&
            e.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: Self.escapeFlags)
    }

    override func keyDown(with e: NSEvent) {
        if isEscape(e) { onEscape?(); return }
        onEvent?(InputEvent(kind: .keyDown, flags: flags(e), code: e.keyCode))
    }

    override func keyUp(with e: NSEvent) {
        if isEscape(e) { return }
        onEvent?(InputEvent(kind: .keyUp, flags: flags(e), code: e.keyCode))
    }

    override func flagsChanged(with e: NSEvent) {
        onEvent?(InputEvent(kind: .flagsChanged, flags: flags(e), code: e.keyCode))
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
