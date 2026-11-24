import AppKit
import Carbon

/// Finds which physical key performs a Cmd-<character> menu shortcut on this Mac, for its
/// current keyboard layout. macOS localizes shortcuts per layout (e.g. on Italian, Cmd-[
/// becomes Cmd-ò), so the key can't be hard-coded. The probe asks AppKit directly by
/// testing each key against a temporary main menu in memory: nothing is pressed.
public enum ShortcutResolver {
    public struct Key: Equatable { public let code: CGKeyCode; public let flags: CGEventFlags }

    private final class Target: NSObject { var hit = false; @objc func act(_ s: Any?) { hit = true } }
    private static var cache: [String: Key] = [:]

    /// Must run on the main thread (it briefly swaps NSApp.mainMenu).
    public static func key(forCommandCharacter ch: String) -> Key? {
        let layout = currentLayoutID()
        if let k = cache[layout + ch] { return k }
        guard let data = layoutData() else { return nil }
        let app = NSApplication.shared
        let saved = app.mainMenu
        let target = Target()
        let main = NSMenu(); let holder = NSMenuItem(); main.addItem(holder)
        let sub = NSMenu(); holder.submenu = sub
        let item = NSMenuItem(title: "probe", action: #selector(Target.act(_:)), keyEquivalent: ch)
        item.target = target
        sub.addItem(item)
        app.mainMenu = main
        defer { app.mainMenu = saved }
        // AppKit applies shortcut localization to a newly installed main menu on the next
        // run-loop pass; without it the probe sees the unlocalized key equivalents.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        for code in 0..<128 {
            for (flags, carbon, cg) in [(NSEvent.ModifierFlags.command, UInt32(cmdKey), CGEventFlags.maskCommand),
                                        ([.command, .option], UInt32(cmdKey | optionKey), [.maskCommand, .maskAlternate]),
                                        ([.command, .shift], UInt32(cmdKey | shiftKey), [.maskCommand, .maskShift])] {
                let c = chars(data, UInt16(code), carbon), ci = chars(data, UInt16(code), 0)
                guard !ci.isEmpty,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                               context: nil, characters: c, charactersIgnoringModifiers: ci, isARepeat: false,
                                               keyCode: UInt16(code)) else { continue }
                target.hit = false
                if main.performKeyEquivalent(with: e), target.hit {
                    let k = Key(code: CGKeyCode(code), flags: cg)
                    cache[layout + ch] = k
                    return k
                }
            }
        }
        return nil
    }

    public static func currentLayoutID() -> String {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
        return unsafeBitCast(p, to: CFString.self) as String
    }

    private static func layoutData() -> Data? {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return unsafeBitCast(p, to: CFData.self) as Data
    }

    private static func chars(_ data: Data, _ code: UInt16, _ mods: UInt32) -> String {
        data.withUnsafeBytes { raw -> String in
            var dead: UInt32 = 0, len = 0
            var c = [UniChar](repeating: 0, count: 4)
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, code, UInt16(kUCKeyActionDown),
                           (mods >> 8) & 0xff, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &c)
            return String(utf16CodeUnits: c, count: len)
        }
    }
}
