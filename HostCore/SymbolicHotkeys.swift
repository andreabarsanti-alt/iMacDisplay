import CoreGraphics
import Foundation

/// Reads the system-wide shortcuts the user has configured (System Settings > Keyboard >
/// Keyboard Shortcuts > Mission Control) so gestures press *this* Mac's shortcut.
public enum SymbolicHotkeys {
    public static let missionControl = 32, moveLeftSpace = 79, moveRightSpace = 81

    /// Pure: (enabled, keycode, modifier mask) from the preference entry -> key to press.
    /// The modifier mask uses the same bits as CGEventFlags. Arrow and function keys get
    /// the fn / numeric-pad flags real keyboards set, or WindowServer won't match them.
    public static func key(enabled: Bool, keycode: Int, modifiers: Int) -> ShortcutResolver.Key? {
        guard enabled, keycode >= 0, keycode < 0xFFFF else { return nil }
        var flags = CGEventFlags(rawValue: UInt64(modifiers) & 0x00FF_0000)
        if (123...126).contains(keycode) { flags.insert([.maskSecondaryFn, .maskNumericPad]) }
        if [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 160, 131].contains(keycode) {
            flags.insert(.maskSecondaryFn)
        }
        return .init(code: CGKeyCode(keycode), flags: flags)
    }

    /// The configured shortcut for a symbolic hotkey id, or nil if it is disabled.
    /// `fallback` is used when the user never changed it (no entry in the preferences).
    public static func key(id: Int, fallback: ShortcutResolver.Key) -> ShortcutResolver.Key? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all["\(id)"] as? [String: Any] else { return fallback }
        let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
        guard let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count >= 3 else {
            return enabled ? fallback : nil
        }
        return key(enabled: enabled, keycode: p[1], modifiers: p[2])
    }
}
