import Foundation

public enum CodexFastConfigurationError: LocalizedError, Equatable {
    case managedAliasCollision(String)

    public var errorDescription: String? {
        switch self {
        case .managedAliasCollision(let model):
            return "Codex model `\(model)` conflicts with CLIProxyManager's managed Fast alias."
        }
    }
}

public struct CodexFastConfiguration: Equatable, Sendable {
    public let oauthCanonicalModels: [String]
    public let apiKeyCanonicalModels: [String]
    public let allAliases: [String]

    public init(config: AppConfig, includeAPIKeyModels: Bool = true) throws {
        let oauthCodexConfigs: [AppConfig.Codex]
        if config.oauthCommandProfiles.isEmpty {
            oauthCodexConfigs = [config.ccodex]
        } else {
            oauthCodexConfigs = config.oauthCommandProfiles.compactMap { profile in
                guard profile.provider == .codex, profile.isEnabled else { return nil }
                return profile.codex ?? config.ccodex
            }
        }

        let roundRobinCodexConfigs: [AppConfig.Codex] = config.roundRobinProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return profile.codex ?? config.ccodex
        }

        oauthCanonicalModels = try Self.fastModels(in: oauthCodexConfigs + roundRobinCodexConfigs)
        apiKeyCanonicalModels = includeAPIKeyModels
            ? try Self.fastModels(in: [config.codexAPI.codex])
            : []
        allAliases = Set((oauthCanonicalModels + apiKeyCanonicalModels).map(CodexFastMode.alias(for:))).sorted()
    }

    private static func fastModels(in configs: [AppConfig.Codex]) throws -> [String] {
        var models = Set<String>()
        for role in configs.flatMap({ [$0.opus, $0.sonnet, $0.haiku] }) where role.fastModeEnabled {
            guard !CodexFastMode.isManagedAlias(role.model) else {
                throw CodexFastConfigurationError.managedAliasCollision(role.model)
            }
            models.insert(CodexFastMode.canonicalModel(from: role.model))
        }
        return models.sorted()
    }
}
