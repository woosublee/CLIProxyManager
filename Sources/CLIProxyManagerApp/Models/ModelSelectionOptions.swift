import Foundation

enum ModelSelectionOptions {
    static func options(currentModel: String, availableModels: [String]) -> [String] {
        let trimmedCurrentModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrentModel.isEmpty,
              !isRoutingPrefixedModel(trimmedCurrentModel),
              !availableModels.contains(trimmedCurrentModel) else {
            return availableModels
        }
        return [trimmedCurrentModel] + availableModels
    }

    private static func isRoutingPrefixedModel(_ model: String) -> Bool {
        guard let slashIndex = model.firstIndex(of: "/") else { return false }
        let prefix = model[..<slashIndex]
        return prefix.hasPrefix("codex-") || prefix.hasPrefix("claude-")
    }

    static func selectedModel(currentModel: String, availableModels: [String]) -> String {
        let trimmedCurrentModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrentModel.isEmpty == false {
            return trimmedCurrentModel
        }
        return availableModels.first ?? ""
    }
}
