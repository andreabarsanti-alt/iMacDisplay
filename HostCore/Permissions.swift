import ApplicationServices
import CoreGraphics
import Foundation

/// Permission probe (Gate 2): prints one JSON line per permission.
/// When launched from Terminal, macOS attributes these to Terminal.app.
public enum HostPermissions {
    public static func screenRecording() -> Bool { CGPreflightScreenCaptureAccess() }
    public static func accessibility() -> Bool { AXIsProcessTrusted() }

    public static func report() -> [String] {
        [
            "{\"permission\":\"screen_recording\",\"status\":\"\(screenRecording() ? "granted" : "denied")\"}",
            "{\"permission\":\"accessibility\",\"status\":\"\(accessibility() ? "granted" : "denied")\"}",
        ]
    }

    /// Shows the system prompts (only the first time; afterwards the user must use System Settings).
    public static func request() {
        if !screenRecording() { _ = CGRequestScreenCaptureAccess() }
        if !accessibility() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }
}
