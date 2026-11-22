import Foundation
import Network
import Security

/// TLS-PSK parameters for the direct link. The 32-byte key lives outside the repo
/// in `~/.imacdisplay/psk` (hex, mode 600) on both Macs during development.
public enum LinkSecurity {
    public static let pskIdentity = "remotemirror-v1"
    public static var defaultKeyPath: String { NSHomeDirectory() + "/.imacdisplay/psk" }

    public enum KeyError: Error, CustomStringConvertible {
        case missing(String), invalid(String), insecurePermissions(String)
        public var description: String {
            switch self {
            case let .missing(p): return "no key at \(p) (create with: RemoteMirrorHost --gen-key, then scripts/install-key.sh)"
            case let .invalid(p): return "key at \(p) is not 64 hex characters"
            case let .insecurePermissions(p): return "key at \(p) is readable by others (chmod 600)"
            }
        }
    }

    public static func loadKey(path: String = defaultKeyPath) throws -> Data {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw KeyError.missing(path) }
        if let perms = attrs[.posixPermissions] as? NSNumber, perms.intValue & 0o077 != 0 {
            throw KeyError.insecurePermissions(path)
        }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64, let key = TestVectors.data(hex: hex) else { throw KeyError.invalid(path) }
        return key
    }

    /// Creates a new random key file (refuses to overwrite).
    public static func generateKey(path: String = defaultKeyPath) throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyError.invalid("random generation failed")
        }
        let hex = TestVectors.hex(Data(bytes)) + "\n"
        guard fm.createFile(atPath: path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw KeyError.missing(path)
        }
        return path
    }

    /// TCP + TLS 1.2 with a pre-shared key; Nagle off. `local` pins the local address
    /// (listener bind address on the host, source address on the client).
    public static func parameters(key: Data, local: NWEndpoint? = nil) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, idData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = false   // liveness comes from the app heartbeat
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false
        if let local { params.requiredLocalEndpoint = local }
        return params
    }
}
