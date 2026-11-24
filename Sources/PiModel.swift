import Foundation

enum PiModel {
    static let key = "piModel"
    static let defaultID = "router/6.2-sol-failover"
    static let usePiDefault = "Use Pi/session default"

    static func load(from defaults: UserDefaults) -> String { defaults.string(forKey: key) ?? defaultID }

    static func preference(_ input: String) -> String? {
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id == usePiDefault { return "" }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
              !id.contains(where: { $0.isWhitespace || $0.isNewline || $0 == ":" }), !id.hasPrefix("-") else { return nil }
        return id
    }
}
