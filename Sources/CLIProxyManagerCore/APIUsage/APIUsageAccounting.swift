import Foundation

public enum APIUsageProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case openAI = "openai"

    public var profileID: String {
        self == .claude ? "claude-api" : "codex-api"
    }
}

public struct APIUsageProfileDescriptor: Equatable, Hashable, Sendable {
    public let profileID: String
    public let provider: APIUsageProvider
    public let modelPrefix: String

    public init(profileID: String, provider: APIUsageProvider, modelPrefix: String) {
        self.profileID = profileID
        self.provider = provider
        self.modelPrefix = modelPrefix
    }

    public static let legacyClaude = APIUsageProfileDescriptor(
        profileID: "claude-api",
        provider: .claude,
        modelPrefix: "cpm-claude-api"
    )
    public static let legacyOpenAI = APIUsageProfileDescriptor(
        profileID: "codex-api",
        provider: .openAI,
        modelPrefix: "cpm-codex-api"
    )
}

public enum APIUsagePricingVariant: String, Codable, Hashable, Sendable {
    case standard
    case priority
    case standardLongContext
    case priorityLongContext
}

public enum APIUsageLedgerIssueReason: String, Codable, Equatable, Sendable {
    case unsupportedAccountingVersion
    case incompleteTokenAccounting
    case unknownProviderMapping
}

public struct APIUsageAggregateInput: Equatable, Sendable {
    public let timestamp: Date
    public let profileID: String
    public let provider: APIUsageProvider
    public let model: String
    public let effectiveServiceTier: String
    public let pricingVariant: APIUsagePricingVariant
    public let tokenBreakdown: APIUsageTokenBreakdown
    public let failed: Bool
}

public struct APIUsageIssueInput: Equatable, Sendable {
    public let timestamp: Date
    public let profileID: String?
    public let provider: APIUsageProvider?
    public let reason: APIUsageLedgerIssueReason
}

public enum APIUsageRecordDisposition: Equatable, Sendable {
    case ignored
    case aggregate(APIUsageAggregateInput)
    case issue(APIUsageIssueInput)
}

public struct APIUsageRecordMapper: Sendable {
    public init() {}

    public func classify(_ record: APIUsageQueueRecord) -> APIUsageRecordDisposition {
        classify(record, profiles: [.legacyClaude, .legacyOpenAI])
    }

    public func classify(
        _ record: APIUsageQueueRecord,
        profiles: [APIUsageProfileDescriptor]
    ) -> APIUsageRecordDisposition {
        let authType = normalized(record.authType)
        guard ["apikey", "api_key", "api-key"].contains(authType) else {
            return .ignored
        }
        guard let profile = mappedProfile(record, profiles: profiles) else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: nil,
                provider: nil,
                reason: .unknownProviderMapping
            ))
        }
        let provider = profile.provider
        guard record.accountingVersion == 2, record.tokenBreakdown.schemaVersion == 2 else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: profile.profileID,
                provider: provider,
                reason: .unsupportedAccountingVersion
            ))
        }
        guard record.tokenBreakdown.quality == .complete, valid(record.tokenBreakdown) else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: profile.profileID,
                provider: provider,
                reason: .incompleteTokenAccounting
            ))
        }

        let model = canonicalModel(record.model, profile: profile)
        let rawTier = normalized(record.responseServiceTier.flatMap(nonEmpty) ?? record.serviceTier)
        let tier = canonicalServiceTier(rawTier, provider: provider)
        let longContextModels: Set<String> = [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-pro"
        ]
        let longContext = provider == .openAI
            && longContextModels.contains(model)
            && record.tokenBreakdown.input.totalTokens > 272_000
        let priority = tier == "priority"
        let variant: APIUsagePricingVariant = switch (priority, longContext) {
        case (false, false): .standard
        case (true, false): .priority
        case (false, true): .standardLongContext
        case (true, true): .priorityLongContext
        }

        return .aggregate(.init(
            timestamp: record.timestamp,
            profileID: profile.profileID,
            provider: provider,
            model: model,
            effectiveServiceTier: tier.isEmpty ? "default" : tier,
            pricingVariant: variant,
            tokenBreakdown: record.tokenBreakdown,
            failed: record.failed
        ))
    }

    private func mappedProfile(
        _ record: APIUsageQueueRecord,
        profiles: [APIUsageProfileDescriptor]
    ) -> APIUsageProfileDescriptor? {
        guard record.hasAuthIndex else { return nil }

        let provider = normalized(record.provider)
        let executor = normalized(record.executorType)
        let aliasPrefix = normalized(record.alias).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let expectedProvider: APIUsageProvider?
        if ["claude", "anthropic"].contains(provider), executor.contains("claude") {
            expectedProvider = .claude
        } else if ["codex", "openai"].contains(provider),
                  executor.contains("codex") || executor.contains("openai") {
            expectedProvider = .openAI
        } else {
            expectedProvider = nil
        }
        guard let expectedProvider else { return nil }

        if let profile = profiles.first(where: {
            $0.provider == expectedProvider && normalized($0.modelPrefix) == aliasPrefix
        }) {
            return profile
        }
        return inferredManagedProfile(prefix: aliasPrefix, provider: expectedProvider)
    }

    private func inferredManagedProfile(
        prefix: String,
        provider: APIUsageProvider
    ) -> APIUsageProfileDescriptor? {
        guard prefix.hasPrefix("cpm-") else { return nil }
        let profileID = String(prefix.dropFirst("cpm-".count))
        let expectedProfileProvider: AuthProfileType = provider == .claude ? .claude : .codex
        guard AppConfig.APIKeyProfile.provider(forID: profileID) == expectedProfileProvider else {
            return nil
        }
        return APIUsageProfileDescriptor(
            profileID: profileID,
            provider: provider,
            modelPrefix: prefix
        )
    }

    private func canonicalServiceTier(_ tier: String, provider: APIUsageProvider) -> String {
        switch provider {
        case .claude:
            return ["", "default", "auto", "standard", "standard_only"].contains(tier) ? "standard" : tier
        case .openAI:
            if ["", "default", "auto", "standard"].contains(tier) {
                return "default"
            }
            return tier
        }
    }

    private func canonicalModel(
        _ model: String,
        profile: APIUsageProfileDescriptor
    ) -> String {
        let normalizedModel = normalized(model)
        let routingPrefix = normalized(profile.modelPrefix) + "/"

        switch profile.provider {
        case .claude:
            guard normalizedModel.hasPrefix(routingPrefix) else { return normalizedModel }
            return String(normalizedModel.dropFirst(routingPrefix.count))
        case .openAI:
            let modelWithoutRoutingPrefix: String
            if normalizedModel.hasPrefix(routingPrefix) {
                modelWithoutRoutingPrefix = String(normalizedModel.dropFirst(routingPrefix.count))
            } else if normalizedModel.contains("/") {
                return normalizedModel
            } else {
                modelWithoutRoutingPrefix = normalizedModel
            }
            return CodexFastMode.canonicalModel(from: modelWithoutRoutingPrefix)
        }
    }

    private func valid(_ breakdown: APIUsageTokenBreakdown) -> Bool {
        let values = [
            breakdown.totalTokens,
            breakdown.input.totalTokens,
            breakdown.input.uncachedTokens,
            breakdown.input.cacheReadTokens,
            breakdown.input.cacheWriteTokens,
            breakdown.output.totalTokens,
            breakdown.output.nonReasoningTokens,
            breakdown.output.reasoningTokens,
            breakdown.unclassifiedTokens
        ]
        guard values.allSatisfy({ $0 >= 0 }),
              sum([
                breakdown.input.uncachedTokens,
                breakdown.input.cacheReadTokens,
                breakdown.input.cacheWriteTokens
              ]) == breakdown.input.totalTokens,
              sum([
                breakdown.output.nonReasoningTokens,
                breakdown.output.reasoningTokens
              ]) == breakdown.output.totalTokens,
              sum([
                breakdown.input.totalTokens,
                breakdown.output.totalTokens,
                breakdown.unclassifiedTokens
              ]) == breakdown.totalTokens else {
            return false
        }
        return breakdown.quality != .complete || breakdown.unclassifiedTokens == 0
    }

    private func sum(_ values: [Int64]) -> Int64? {
        values.reduce(Optional(0)) { partial, value in
            guard let partial else { return nil }
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? nil : result
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
