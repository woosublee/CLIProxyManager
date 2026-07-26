import CLIProxyManagerCore
import Foundation

struct AppConfigMigrationResult: Equatable, Sendable {
    let config: AppConfig
    let shouldPersist: Bool
}

enum AppConfigMigration {
    static func recomputingModelPrefixes(in config: AppConfig) -> AppConfig {
        var config = config
        config.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(
            config.oauthCommandProfiles
        )
        return config
    }

    static func reconcile(
        loadResult: AppConfigLoadResult,
        authProfiles: [AuthProfile]
    ) -> AppConfigMigrationResult {
        var config = loadResult.config
        let authIDs = Set(authProfiles.map(\.id))
        var commandProfiles = config.oauthCommandProfiles.filter {
            authIDs.contains($0.authProfileID)
        }
        var usedIDs = Set(commandProfiles.map(\.id))
        var seenAuthProfileIDs = Set(commandProfiles.map(\.authProfileID))
        let firstAuthProfileIDs = Dictionary(
            authProfiles.map { ($0.type, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let preferProviderID = commandProfiles.isEmpty

        for authProfile in authProfiles where !seenAuthProfileIDs.contains(authProfile.id) {
            let legacyDefaults: LegacyOAuthProviderDefaults?
            if firstAuthProfileIDs[authProfile.type] == authProfile.id {
                switch authProfile.type {
                case .claude:
                    legacyDefaults = loadResult.legacyOAuthDefaults?.claude
                case .codex:
                    legacyDefaults = loadResult.legacyOAuthDefaults?.codex
                }
            } else {
                legacyDefaults = nil
            }

            let id = commandProfileID(
                provider: authProfile.type,
                authProfileID: authProfile.id,
                preferProviderID: preferProviderID,
                usedIDs: &usedIDs
            )
            commandProfiles.append(
                AppConfig.OAuthCommandProfile(
                    id: id,
                    provider: authProfile.type,
                    authProfileID: authProfile.id,
                    commandName: legacyDefaults?.commandName ?? "",
                    nickname: legacyDefaults?.nickname ?? "",
                    accountDetailHidden: legacyDefaults?.accountDetailHidden ?? true,
                    dangerousPermissionsEnabled: legacyDefaults?.dangerousPermissionsEnabled ?? false,
                    claude: authProfile.type == .claude
                        ? (legacyDefaults?.claude ?? .automatic)
                        : nil,
                    codex: authProfile.type == .codex
                        ? (legacyDefaults?.codex ?? .default)
                        : nil,
                    modelPrefix: "",
                    connectionMode: .proxy,
                    isEnabled: !authProfile.disabled
                )
            )
            seenAuthProfileIDs.insert(authProfile.id)
        }

        config.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(commandProfiles)
        return AppConfigMigrationResult(
            config: config,
            shouldPersist: loadResult.requiresCanonicalRewrite || config != loadResult.config
        )
    }

    private static func commandProfileID(
        provider: AuthProfileType,
        authProfileID: String,
        preferProviderID: Bool,
        usedIDs: inout Set<String>
    ) -> String {
        let providerID = provider.rawValue
        if preferProviderID, !usedIDs.contains(providerID) {
            usedIDs.insert(providerID)
            return providerID
        }

        let baseID = "\(provider.rawValue)-\(slug(for: authProfileID))"
        var candidate = baseID
        var suffix = 2
        while usedIDs.contains(candidate) {
            candidate = "\(baseID)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }

    private static func commandProfilesWithRecomputedModelPrefixes(
        _ commandProfiles: [AppConfig.OAuthCommandProfile]
    ) -> [AppConfig.OAuthCommandProfile] {
        var usedPrefixes: Set<String> = []
        return commandProfiles.map { commandProfile in
            var updatedProfile = commandProfile
            updatedProfile.modelPrefix = uniqueModelPrefix(
                provider: commandProfile.provider,
                nickname: commandProfile.nickname,
                authProfileID: commandProfile.authProfileID,
                usedPrefixes: &usedPrefixes
            )
            return updatedProfile
        }
    }

    private static func uniqueModelPrefix(
        provider: AuthProfileType,
        nickname: String,
        authProfileID: String,
        usedPrefixes: inout Set<String>
    ) -> String {
        let basePrefix = modelPrefixBase(
            provider: provider,
            nickname: nickname,
            authProfileID: authProfileID
        )
        var candidate = basePrefix
        var suffix = 2
        while usedPrefixes.contains(candidate) {
            candidate = "\(basePrefix)-\(suffix)"
            suffix += 1
        }
        usedPrefixes.insert(candidate)
        return candidate
    }

    private static func modelPrefixBase(
        provider: AuthProfileType,
        nickname: String,
        authProfileID: String
    ) -> String {
        let suffix = nonEmptySlug(for: nickname)
            ?? shortAuthProfileSlug(provider: provider, authProfileID: authProfileID)
        return "\(provider.rawValue)-\(suffix)"
    }

    private static func shortAuthProfileSlug(
        provider: AuthProfileType,
        authProfileID: String
    ) -> String {
        let fileName = URL(fileURLWithPath: authProfileID)
            .deletingPathExtension()
            .lastPathComponent
        let fullSlug = slug(for: fileName)
        let providerPrefix = "\(provider.rawValue)-"
        let suffixSource: String
        if fullSlug == provider.rawValue {
            suffixSource = "account"
        } else if fullSlug.hasPrefix(providerPrefix) {
            suffixSource = String(fullSlug.dropFirst(providerPrefix.count))
        } else {
            suffixSource = fullSlug
        }

        let firstSegment = suffixSource
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        return firstSegment.isEmpty ? "account" : firstSegment
    }

    private static func nonEmptySlug(for value: String) -> String? {
        let slug = rawSlug(for: value)
        return slug.isEmpty ? nil : slug
    }

    private static func slug(for value: String) -> String {
        let slug = rawSlug(for: value)
        return slug.isEmpty ? "account" : slug
    }

    private static func rawSlug(for value: String) -> String {
        let lowercasedValue = value.lowercased()
        var result = ""
        var previousWasSeparator = false
        for scalar in lowercasedValue.unicodeScalars {
            let isAllowed = (97...122).contains(Int(scalar.value))
                || (48...57).contains(Int(scalar.value))
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
