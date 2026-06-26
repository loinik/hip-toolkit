// Strings.swift — runtime loader for Sources/Strings/en.json (and future language files).
// Usage: S.get("key")  or  S.fmt("key_with_{0}", arg)

import Foundation

enum S {
    private static let _dict: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }()

    static func get(_ key: String) -> String { _dict[key] ?? key }

    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        var s = get(key)
        for (i, arg) in args.enumerated() {
            s = s.replacingOccurrences(of: "{\(i)}", with: "\(arg)")
        }
        return s
    }
}

// MARK: - Update checker

/// Checks the repository's `main` branch for a newer version once per launch.
/// Network failures are swallowed silently — the check must never block or
/// disrupt startup.
enum UpdateChecker {
    static let versionURL  = URL(string: "https://raw.githubusercontent.com/loinik/hip-toolkit/main/VERSION")!
    static let releasesURL = URL(string: "https://github.com/loinik/hip-toolkit/releases/latest")!

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Outcome of an update check. `.failed` (network/HTTP error) is kept distinct
    /// from `.upToDate` so a manual check can tell the user the check itself failed
    /// rather than wrongly claiming they're current.
    enum Status {
        case available(String)
        case upToDate
        case failed
    }

    static func check() async -> Status {
        var req = URLRequest(url: versionURL)
        req.cachePolicy   = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let remote = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !remote.isEmpty
            else { return .failed }
            return isNewer(remote, than: currentVersion) ? .available(remote) : .upToDate
        } catch {
            return .failed
        }
    }

    /// Dot-separated integer comparison: `true` when `a` is strictly newer than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
