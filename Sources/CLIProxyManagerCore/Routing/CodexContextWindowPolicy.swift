import Foundation

public enum CodexContextWindowPolicy {
    public static let standardContextWindow = 200_000

    // These values mirror the scoped Codex registry bundled with CLIProxyAPI. They are only a
    // safety net when authoritative model metadata is unavailable; unknown models stay unknown.
    private static let fallbackContextWindows: [String: Int] = [
        "gpt-5.6-sol": 372_000,
        "gpt-5.6-terra": 372_000,
        "gpt-5.6-luna": 372_000,
        "gpt-5.5": 272_000,
        "codex-auto-review": 272_000,
        "gpt-image-1.5": 272_000,
        "gpt-image-2": 272_000,
        "gpt-5.4": 1_050_000,
        "gpt-5.4-mini": 400_000,
        "gpt-5.3-codex-spark": 128_000
    ]

    public static func effectiveContextWindow(
        model: String,
        detectedContextWindow: Int?
    ) -> Int? {
        detectedContextWindow ?? fallbackContextWindow(for: model)
    }

    public static func fallbackContextWindow(for model: String) -> Int? {
        fallbackContextWindows[registryModelID(from: model)]
    }

    static func registryModelID(from model: String) -> String {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasSuffix("[1m]") {
            normalized = String(normalized.dropLast(4))
        }
        let canonical = CodexFastMode.canonicalModel(from: normalized)
        return (canonical.split(separator: "/").last.map(String.init) ?? canonical).lowercased()
    }
}
