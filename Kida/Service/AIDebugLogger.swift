import Foundation

enum AIDebugLogger {
    #if DEBUG
    private static let maxCharacters = 16_000

    nonisolated private static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "KidaAIDebug") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "KidaAIDebug")
    }

    nonisolated static func trace(_ title: String, _ body: @autoclosure () -> String) {
        guard isEnabled else { return }

        let value = clipped(body())
        print("""

        === Kida AI Debug: \(title) ===
        \(value)
        === End Kida AI Debug: \(title) ===

        """)
    }

    nonisolated static func json<T: Encodable>(_ title: String, _ value: T) {
        guard isEnabled else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(value),
           let text = String(data: data, encoding: .utf8) {
            trace(title, text)
        } else {
            trace(title, "<failed to encode debug JSON>")
        }
    }

    nonisolated private static func clipped(_ value: String) -> String {
        guard value.count > maxCharacters else { return value }
        let prefix = value.prefix(maxCharacters)
        return "\(prefix)\n... <truncated \(value.count - maxCharacters) characters>"
    }
    #else
    nonisolated static func trace(_ title: String, _ body: @autoclosure () -> String) {}
    nonisolated static func json<T: Encodable>(_ title: String, _ value: T) {}
    #endif
}
