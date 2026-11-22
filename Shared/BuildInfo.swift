import Foundation

public enum BuildInfo {
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static func banner(_ name: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(name) protocol=v\(WireProtocol.version) arch=\(architecture) macOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
