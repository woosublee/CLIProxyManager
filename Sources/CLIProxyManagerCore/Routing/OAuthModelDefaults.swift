import Foundation

public enum OAuthModelDefaults {
    public static let claudeOpusModel = "claude-opus-4-7"
    public static let claudeSonnetModel = "claude-sonnet-4-6"
    public static let claudeHaikuModel = "claude-haiku-4-5-20251001"

    public static func prefixedModel(_ model: String, prefix: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return model }
        return "\(trimmedPrefix)/\(model)"
    }

    public static func shellSingleQuoted(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
