import Foundation

public enum ClaudeModelSelection: Codable, Equatable, Hashable, Sendable {
    case automatic
    case model(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self = value.isEmpty || value.caseInsensitiveCompare("automatic") == .orderedSame
            ? .automatic
            : .model(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic:
            try container.encode("automatic")
        case .model(let model):
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            try container.encode(trimmed.isEmpty ? "automatic" : trimmed)
        }
    }
}

public struct ClaudeRouting: Codable, Equatable, Sendable {
    public var opus: ClaudeModelSelection
    public var sonnet: ClaudeModelSelection
    public var haiku: ClaudeModelSelection

    public init(
        opus: ClaudeModelSelection,
        sonnet: ClaudeModelSelection,
        haiku: ClaudeModelSelection
    ) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
    }

    public static let automatic = ClaudeRouting(
        opus: .automatic,
        sonnet: .automatic,
        haiku: .automatic
    )
}

public struct ResolvedClaudeModels: Equatable, Sendable {
    public let opus: String
    public let sonnet: String
    public let haiku: String

    public init(opus: String, sonnet: String, haiku: String) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
    }

    public var shellEnvironmentAssignments: String {
        [
            "ANTHROPIC_DEFAULT_OPUS_MODEL=\(OAuthModelDefaults.shellSingleQuoted(opus))",
            "ANTHROPIC_DEFAULT_SONNET_MODEL=\(OAuthModelDefaults.shellSingleQuoted(sonnet))",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL=\(OAuthModelDefaults.shellSingleQuoted(haiku))"
        ].joined(separator: "\n")
    }
}

public enum ClaudeModelResolutionError: LocalizedError, Equatable {
    case noModelsAvailable(prefix: String)
    case noModelForFamily(ClaudeModelFamily)
    case selectedModelUnavailable(role: ClaudeModelFamily, model: String)
    case selectedModelHasWrongFamily(role: ClaudeModelFamily, model: String, actualFamily: ClaudeModelFamily)

    public var errorDescription: String? {
        switch self {
        case .noModelsAvailable(let prefix):
            "No Claude models are available for account prefix `\(prefix)`. Start CLIProxyAPI and verify this account, then retry."
        case .noModelForFamily(let family):
            "No \(family.displayName) model is available for this account. Refresh the account models or choose another account."
        case .selectedModelUnavailable(let role, let model):
            "Selected \(role.displayName) model \(model) is unavailable for this account. Choose another model or switch \(role.displayName) to Automatic."
        case .selectedModelHasWrongFamily(let role, let model, let actualFamily):
            "Selected \(role.displayName) model \(model) belongs to \(actualFamily.displayName). Choose a \(role.displayName) model or switch to Automatic."
        }
    }
}

public enum ClaudeModelResolver {
    public static func resolve(
        routing: ClaudeRouting,
        options: [ClaudeModelOption],
        prefix: String
    ) throws -> ResolvedClaudeModels {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.isEmpty else {
            throw ClaudeModelResolutionError.noModelsAvailable(prefix: trimmedPrefix)
        }

        return ResolvedClaudeModels(
            opus: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.opus, role: .opus, options: options),
                prefix: trimmedPrefix
            ),
            sonnet: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.sonnet, role: .sonnet, options: options),
                prefix: trimmedPrefix
            ),
            haiku: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.haiku, role: .haiku, options: options),
                prefix: trimmedPrefix
            )
        )
    }

    public static func resolveBaseModel(
        selection: ClaudeModelSelection,
        role: ClaudeModelFamily,
        options: [ClaudeModelOption]
    ) throws -> String {
        switch selection {
        case .automatic:
            if let latest = orderedOptions(for: role, options: options).first {
                return latest.id
            }
            let compatibilityID = compatibilityModelID(for: role)
            if options.contains(where: { $0.id == compatibilityID }) {
                return compatibilityID
            }
            throw ClaudeModelResolutionError.noModelForFamily(role)
        case .model(let rawModel):
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let option = options.first(where: { $0.id == model }) else {
                throw ClaudeModelResolutionError.selectedModelUnavailable(role: role, model: model)
            }
            guard option.family == role else {
                throw ClaudeModelResolutionError.selectedModelHasWrongFamily(
                    role: role,
                    model: model,
                    actualFamily: option.family
                )
            }
            return option.id
        }
    }

    public static func orderedOptions(
        for family: ClaudeModelFamily,
        options: [ClaudeModelOption]
    ) -> [ClaudeModelOption] {
        options.filter { $0.family == family }.sorted(by: isNewer)
    }

    private static func isNewer(_ lhs: ClaudeModelOption, _ rhs: ClaudeModelOption) -> Bool {
        switch (lhs.created, rhs.created) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let leftVersion = numericComponents(in: lhs.id)
            let rightVersion = numericComponents(in: rhs.id)
            if leftVersion != rightVersion {
                return versionIsGreater(leftVersion, than: rightVersion)
            }
            return lhs.id > rhs.id
        }
    }

    private static func numericComponents(in id: String) -> [Int] {
        id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private static func versionIsGreater(_ lhs: [Int], than rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func compatibilityModelID(for family: ClaudeModelFamily) -> String {
        switch family {
        case .opus: OAuthModelDefaults.claudeOpusModel
        case .sonnet: OAuthModelDefaults.claudeSonnetModel
        case .haiku: OAuthModelDefaults.claudeHaikuModel
        case .other: ""
        }
    }
}
