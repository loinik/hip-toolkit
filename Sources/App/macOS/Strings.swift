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
