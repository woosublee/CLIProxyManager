import Foundation

public enum CodexContextWindowExport {
    public static func autoCompactWindow(for codex: AppConfig.Codex) -> Int? {
        [codex.opus, codex.sonnet, codex.haiku]
            .compactMap(\.effectiveContextWindow)
            .filter { $0 > CodexContextWindowPolicy.standardContextWindow }
            .min()
    }
}
