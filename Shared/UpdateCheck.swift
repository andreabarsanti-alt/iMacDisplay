import Foundation

/// Checks GitHub (public repo) for a newer RemoteMirror release. Nothing is downloaded or
/// installed: the apps only tell the user and link to the release page.
public enum UpdateCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/andreabarsanti-alt/iMacDisplay/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/andreabarsanti-alt/iMacDisplay/releases/latest")!

    public struct Update: Equatable {
        public let version: String
        public let page: URL
    }

    /// Numeric parts of a version like "v1.2", "1.2.3" or a dev build "v1.1-4-gabc123"
    /// (dev builds count as their release; nil if there is no leading version).
    public static func parts(_ v: String) -> [Int]? {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let core = s.split(separator: "-").first.map(String.init) ?? s
        let p = core.split(separator: ".").map { Int($0) }
        guard !p.isEmpty, p.allSatisfy({ $0 != nil }) else { return nil }
        return p.compactMap { $0 }
    }

    /// True if `latest` is a higher version than `current`. Pure, unit-tested.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = parts(latest), let c = parts(current) else { return false }
        for i in 0..<max(l.count, c.count) {
            let a = i < l.count ? l[i] : 0, b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Calls back on the main thread with an update, or nil (none, offline, or a dev build).
    public static func check(current: String = currentVersion, completion: @escaping (Update?) -> Void) {
        var req = URLRequest(url: latestURL, timeoutInterval: 10)
        req.setValue("RemoteMirror-update-check", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var result: Update?
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String, isNewer(tag, than: current) {
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
                result = Update(version: tag, page: page)
            }
            DispatchQueue.main.async {
                print("{\"event\":\"update_check\",\"current\":\"\(current)\",\"update\":\"\(result?.version ?? "none")\"}")
                completion(result)
            }
        }.resume()
    }
}
