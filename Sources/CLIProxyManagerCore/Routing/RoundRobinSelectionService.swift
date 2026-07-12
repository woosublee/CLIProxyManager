import Foundation

public enum RoundRobinSelectionError: Error, Equatable, LocalizedError {
    case profileNotFound(String)
    case profileDisabled(String)
    case insufficientCandidates(String, Int)
    case selectedProfileUnavailable(String)
    case missingModelPrefix(String)
    case duplicateCommandProfiles(String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Round-robin profile `\(id)` was not found."
        case .profileDisabled(let id):
            "Round-robin profile `\(id)` is disabled."
        case .insufficientCandidates(let id, let count):
            "Round-robin profile `\(id)` requires at least 2 enabled selected accounts, but found \(count)."
        case .selectedProfileUnavailable(let id):
            "Selected round-robin auth profile `\(id)` is unavailable."
        case .missingModelPrefix(let id):
            "Selected round-robin auth profile `\(id)` does not have a routing prefix."
        case .duplicateCommandProfiles(let authProfileID):
            "Round-robin auth profile `\(authProfileID)` has duplicate command profiles."
        }
    }
}

public struct RoundRobinSelectionService: Sendable {
    private struct Candidate: Sendable {
        let authProfileID: String
        let commandProfile: AppConfig.OAuthCommandProfile
        let modelPrefix: String
    }

    private let stateSelector: any RoundRobinStateSelecting
    private let claudeModelClient: any ClaudeModelListing

    public init(
        stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore(),
        claudeModelClient: any ClaudeModelListing = ProxyModelClient()
    ) {
        self.stateSelector = stateSelector
        self.claudeModelClient = claudeModelClient
    }

    public func shellEnvironmentAssignments(
        profileID: String,
        config: AppConfig,
        authProfiles: [AuthProfile]
    ) async throws -> String {
        guard let profile = config.roundRobinProfiles.first(where: { $0.id == profileID }) else {
            throw RoundRobinSelectionError.profileNotFound(profileID)
        }
        guard profile.isEnabled else {
            throw RoundRobinSelectionError.profileDisabled(profileID)
        }

        let candidates = try candidates(for: profile, config: config, authProfiles: authProfiles)
        guard candidates.count >= 2 else {
            throw RoundRobinSelectionError.insufficientCandidates(profile.id, candidates.count)
        }

        let selectedID = try stateSelector.nextSelectedAuthProfileID(
            groupID: profile.id,
            candidates: candidates.map(\.authProfileID)
        )
        guard let selected = candidates.first(where: { $0.authProfileID == selectedID }) else {
            throw RoundRobinSelectionError.selectedProfileUnavailable(selectedID)
        }
        guard !selected.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoundRobinSelectionError.missingModelPrefix(selectedID)
        }

        let models: (opus: String, sonnet: String, haiku: String)
        switch profile.provider {
        case .claude:
            let options = try await claudeModelClient.claudeModelOptions(
                port: config.port,
                modelPrefix: selected.modelPrefix
            )
            let resolved = try ClaudeModelResolver.resolve(
                routing: selected.commandProfile.effectiveClaudeRouting,
                options: options,
                prefix: selected.modelPrefix
            )
            models = (resolved.opus, resolved.sonnet, resolved.haiku)
        case .codex:
            let codex = profile.codex ?? config.ccodex
            models = (
                OAuthModelDefaults.prefixedModel(codex.opus.modelIdentifier, prefix: selected.modelPrefix),
                OAuthModelDefaults.prefixedModel(codex.sonnet.modelIdentifier, prefix: selected.modelPrefix),
                OAuthModelDefaults.prefixedModel(codex.haiku.modelIdentifier, prefix: selected.modelPrefix)
            )
        }
        return [
            shellAssignment(name: "ANTHROPIC_DEFAULT_OPUS_MODEL", value: models.opus),
            shellAssignment(name: "ANTHROPIC_DEFAULT_SONNET_MODEL", value: models.sonnet),
            shellAssignment(name: "ANTHROPIC_DEFAULT_HAIKU_MODEL", value: models.haiku),
            shellAssignment(name: "CLIPROXY_ROUND_ROBIN_PROFILE", value: selected.authProfileID)
        ].joined(separator: "\n")
    }

    private func candidates(
        for profile: AppConfig.RoundRobinProfile,
        config: AppConfig,
        authProfiles: [AuthProfile]
    ) throws -> [Candidate] {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        let commandProfilesByAuthID = Dictionary(grouping: config.oauthCommandProfiles, by: \.authProfileID)

        return try profile.includedAuthProfileIDs.compactMap { authProfileID in
            guard let authProfile = authProfilesByID[authProfileID],
                  authProfile.type == profile.provider,
                  authProfile.disabled == false else {
                return nil
            }

            let matchingCommandProfiles = (commandProfilesByAuthID[authProfileID] ?? []).filter { commandProfile in
                commandProfile.provider == profile.provider
                    && commandProfile.isEnabled
                    && (profile.provider != .claude || commandProfile.connectionMode == .proxy)
            }
            guard !matchingCommandProfiles.isEmpty else { return nil }
            guard matchingCommandProfiles.count == 1, let commandProfile = matchingCommandProfiles.first else {
                throw RoundRobinSelectionError.duplicateCommandProfiles(authProfileID)
            }

            let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (authProfile.prefix ?? "")
                : commandProfile.modelPrefix
            guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Candidate(
                authProfileID: authProfileID,
                commandProfile: commandProfile,
                modelPrefix: prefix
            )
        }
    }

    private func shellAssignment(name: String, value: String) -> String {
        "\(name)=\(OAuthModelDefaults.shellSingleQuoted(value))"
    }
}
