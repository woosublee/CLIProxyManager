import Foundation

enum ModelSelectionOptions {
    static func options(currentModel: String, availableModels: [String]) -> [String] {
        let trimmedCurrentModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = availableModels

        if trimmedCurrentModel.isEmpty == false && options.contains(trimmedCurrentModel) == false {
            options.insert(trimmedCurrentModel, at: 0)
        }

        return options
    }

    static func selectedModel(currentModel: String, availableModels: [String]) -> String {
        let trimmedCurrentModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrentModel.isEmpty == false {
            return trimmedCurrentModel
        }
        return availableModels.first ?? ""
    }
}
