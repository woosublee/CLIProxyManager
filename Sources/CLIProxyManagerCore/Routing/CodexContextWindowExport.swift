import Foundation

public enum CodexContextWindowExport {
    public static func autoCompactWindow(for codex: AppConfig.Codex) -> Int? {
        [codex.opus, codex.sonnet, codex.haiku]
            .compactMap(\.detectedContextWindow)
            .filter { $0 > 200_000 }
            .min()
    }
}
