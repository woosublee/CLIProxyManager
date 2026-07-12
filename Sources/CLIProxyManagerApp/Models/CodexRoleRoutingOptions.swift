import CLIProxyManagerCore
import Foundation

enum CodexRoleRoutingOptions {
    static func modelIDs(currentModel: String, options: [CodexModelOption]) -> [String] {
        ModelSelectionOptions.options(currentModel: currentModel, availableModels: options.map(\.id))
    }

    static func reasoningValues(
        currentReasoning: AppConfig.CodexReasoning,
        model: String,
        options: [CodexModelOption]
    ) -> [AppConfig.CodexReasoning] {
        guard let option = options.first(where: { $0.id == model }),
              !option.supportedReasoning.isEmpty else {
            return currentReasoning == .auto ? [.auto] : [.auto, currentReasoning]
        }
        return [.auto] + option.supportedReasoning.filter { $0 != .auto }
    }

    static func normalizedReasoning(
        currentReasoning: AppConfig.CodexReasoning,
        model: String,
        options: [CodexModelOption]
    ) -> AppConfig.CodexReasoning {
        guard let option = options.first(where: { $0.id == model }),
              !option.supportedReasoning.isEmpty else { return currentReasoning }
        if currentReasoning == .auto || option.supportedReasoning.contains(currentReasoning) {
            return currentReasoning
        }
        if let defaultReasoning = option.defaultReasoning,
           option.supportedReasoning.contains(defaultReasoning) {
            return defaultReasoning
        }
        return .auto
    }
}
