import Foundation

public enum RoundRobinSelectionError: Error, Equatable, LocalizedError {
    case profileNotFound(String)
    case profileDisabled(String)
    case insufficientCandidates(String, Int)
    case selectedProfileUnavailable(String)
    case missingModelPrefix(String)

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
        }
    }
}

public struct RoundRobinSelectionService: Sendable {
    private struct Candidate: Sendable {
        let authProfileID: String
        let modelPrefix: String
    }

    private let stateSelector: any RoundRobinStateSelecting

    public init(stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore()) {
        self.stateSelector = stateSelector
    }

    public func shellEnvironmentAssignments(
        profileID: String,
        config: AppConfig,
        authProfiles: [AuthProfile]
    ) throws -> String {
        guard let profile = config.roundRobinProfiles.first(where: { $0.id == profileID }) else {
            throw RoundRobinSelectionError.profileNotFound(profileID)
        }
        guard profile.isEnabled else {
            throw RoundRobinSelectionError.profileDisabled(profileID)
        }

        let candidates = candidates(for: profile, config: config, authProfiles: authProfiles)
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

        let models = modelIdentifiers(for: profile, prefix: selected.modelPrefix, fallbackCodex: config.ccodex)
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
    ) -> [Candidate] {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        let commandProfilesByAuthID = Dictionary(uniqueKeysWithValues: config.oauthCommandProfiles.map { ($0.authProfileID, $0) })

        return profile.includedAuthProfileIDs.compactMap { authProfileID in
            guard let authProfile = authProfilesByID[authProfileID],
                  authProfile.type == profile.provider,
                  authProfile.disabled == false,
                  let commandProfile = commandProfilesByAuthID[authProfileID],
                  commandProfile.provider == profile.provider,
                  commandProfile.isEnabled else {
                return nil
            }

            let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (authProfile.prefix ?? "")
                : commandProfile.modelPrefix
            guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Candidate(authProfileID: authProfileID, modelPrefix: prefix)
        }
    }

    private func modelIdentifiers(
        for profile: AppConfig.RoundRobinProfile,
        prefix: String,
        fallbackCodex: AppConfig.Codex
    ) -> (opus: String, sonnet: String, haiku: String) {
        switch profile.provider {
        case .claude:
            return (
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeOpusModel, prefix: prefix),
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeSonnetModel, prefix: prefix),
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeHaikuModel, prefix: prefix)
            )
        case .codex:
            let codex = profile.codex ?? fallbackCodex
            return (
                OAuthModelDefaults.prefixedModel(codex.opus.modelIdentifier, prefix: prefix),
                OAuthModelDefaults.prefixedModel(codex.sonnet.modelIdentifier, prefix: prefix),
                OAuthModelDefaults.prefixedModel(codex.haiku.modelIdentifier, prefix: prefix)
            )
        }
    }

    private func shellAssignment(name: String, value: String) -> String {
        "\(name)=\(OAuthModelDefaults.shellSingleQuoted(value))"
    }
}
