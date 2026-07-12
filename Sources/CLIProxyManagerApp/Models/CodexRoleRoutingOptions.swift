import CLIProxyManagerCore
import Foundation

enum CodexRoleRoutingOptions {
    static let fastModeHelpText = "Fast mode can be about 1.5× faster and may consume more usage or credits."

    static func modelIDs(currentModel: String, options: [CodexModelOption]) -> [String] {
        ModelSelectionOptions.options(
            currentModel: CodexFastMode.canonicalModel(from: currentModel),
            availableModels: options.map(\.id)
        )
    }

    static func supportsFastMode(model: String, options: [CodexModelOption]) -> Bool {
        options.first { $0.id == CodexFastMode.canonicalModel(from: model) }?.supportsFastMode == true
    }

    static func normalizedCodex(
        _ codex: AppConfig.Codex,
        options: [CodexModelOption]
    ) -> AppConfig.Codex {
        AppConfig.Codex(
            opus: normalizedRole(codex.opus, model: codex.opus.model, options: options),
            sonnet: normalizedRole(codex.sonnet, model: codex.sonnet.model, options: options),
            haiku: normalizedRole(codex.haiku, model: codex.haiku.model, options: options)
        )
    }

    static func normalizedRole(
        _ role: AppConfig.CodexRole,
        model: String,
        options: [CodexModelOption]
    ) -> AppConfig.CodexRole {
        var updated = role
        updated.model = CodexFastMode.canonicalModel(from: model)
        updated.reasoning = normalizedReasoning(
            currentReasoning: role.reasoning,
            model: updated.model,
            options: options
        )
        if !supportsFastMode(model: updated.model, options: options) {
            updated.fastModeEnabled = false
        }
        return updated
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
