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
        try Self.validateNoManagedAliasCollisions(in: config)

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

        oauthCanonicalModels = Self.fastModels(in: oauthCodexConfigs + roundRobinCodexConfigs)
        apiKeyCanonicalModels = includeAPIKeyModels
            ? Self.fastModels(in: [config.codexAPI.codex])
            : []
        allAliases = Set((oauthCanonicalModels + apiKeyCanonicalModels).map(CodexFastMode.alias(for:))).sorted()
    }

    private static func validateNoManagedAliasCollisions(in config: AppConfig) throws {
        let allCodexConfigs = [config.ccodex, config.codexAPI.codex]
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
