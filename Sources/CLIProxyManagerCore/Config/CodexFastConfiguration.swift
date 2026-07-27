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
    public let apiKeyCanonicalModelsByProfileID: [String: [String]]
    public let allAliases: [String]

    public var apiKeyCanonicalModels: [String] {
        Set(apiKeyCanonicalModelsByProfileID.values.flatMap { $0 }).sorted()
    }

    public init(config: AppConfig, includeAPIKeyModels: Bool = true) throws {
        try self.init(
            config: config,
            includedAPIKeyProfileIDs: includeAPIKeyModels
                ? Set(config.apiKeyProfiles.map(\.id))
                : []
        )
    }

    public init(
        config: AppConfig,
        includedAPIKeyProfileIDs: Set<String>
    ) throws {
        try Self.validateNoManagedAliasCollisions(in: config)

        let oauthCodexConfigs: [AppConfig.Codex] = config.oauthCommandProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return profile.codex ?? .default
        }

        let roundRobinCodexConfigs: [AppConfig.Codex] = config.roundRobinProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return profile.codex ?? .default
        }

        oauthCanonicalModels = Self.fastModels(in: oauthCodexConfigs + roundRobinCodexConfigs)
        apiKeyCanonicalModelsByProfileID = Dictionary(
            uniqueKeysWithValues: config.apiKeyProfiles.compactMap { profile in
                guard profile.provider == .codex,
                      includedAPIKeyProfileIDs.contains(profile.id) else {
                    return nil
                }
                return (profile.id, Self.fastModels(in: [profile.effectiveCodex]))
            }
        )
        allAliases = Set(
            (oauthCanonicalModels + apiKeyCanonicalModelsByProfileID.values.flatMap { $0 })
                .map(CodexFastMode.alias(for:))
        ).sorted()
    }

    private static func validateNoManagedAliasCollisions(in config: AppConfig) throws {
        let allCodexConfigs = config.apiKeyProfiles.compactMap { profile in
            profile.provider == .codex ? profile.effectiveCodex : nil
        }
            + config.oauthCommandProfiles.compactMap { $0.provider == .codex ? $0.codex : nil }
            + config.roundRobinProfiles.compactMap { $0.provider == .codex ? $0.codex : nil }

        for role in allCodexConfigs.flatMap({ [$0.opus, $0.sonnet, $0.haiku] }) {
            guard !CodexFastMode.isManagedAlias(role.model) else {
                throw CodexFastConfigurationError.managedAliasCollision(role.model)
            }
        }
    }

    private static func fastModels(in configs: [AppConfig.Codex]) -> [String] {
        Set(
            configs
                .flatMap { [$0.opus, $0.sonnet, $0.haiku] }
                .filter(\.fastModeEnabled)
                .map { CodexFastMode.canonicalModel(from: $0.model) }
        )
        .sorted()
    }
}
