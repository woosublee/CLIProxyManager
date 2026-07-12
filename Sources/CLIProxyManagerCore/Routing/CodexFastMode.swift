import Foundation

public enum CodexFastMode {
    public static let managedAliasSuffix = "-cpm-fast"

    public static func alias(for canonicalModel: String) -> String {
        self.canonicalModel(from: canonicalModel) + managedAliasSuffix
    }

    public static func isManagedAlias(_ model: String) -> Bool {
        baseModel(from: model).hasSuffix(managedAliasSuffix)
    }

    public static func canonicalModel(from model: String) -> String {
        let base = baseModel(from: model)
        guard base.hasSuffix(managedAliasSuffix) else { return base }
        return String(base.dropLast(managedAliasSuffix.count))
    }

    public static func modelIdentifier(
        model: String,
        reasoning: AppConfig.CodexReasoning,
        fastModeEnabled: Bool
    ) -> String {
        let canonical = canonicalModel(from: model)
        let requestedModel = fastModeEnabled ? alias(for: canonical) : canonical
        return reasoning == .auto ? requestedModel : "\(requestedModel)(\(reasoning.rawValue))"
    }

    private static func baseModel(from model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let opening = trimmed.lastIndex(of: "(") else {
            return trimmed
        }
        let valueStart = trimmed.index(after: opening)
        let valueEnd = trimmed.index(before: trimmed.endIndex)
        let rawValue = String(trimmed[valueStart..<valueEnd])
        guard AppConfig.CodexReasoning(rawValue: rawValue) != nil else {
            return trimmed
        }
        return String(trimmed[..<opening])
    }
}
