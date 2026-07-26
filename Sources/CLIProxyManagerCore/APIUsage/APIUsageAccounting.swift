import Foundation

public enum APIUsageProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case openAI = "openai"

    public var profileID: String {
        self == .claude ? "claude-api" : "codex-api"
    }
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
        let authType = normalized(record.authType)
        guard ["apikey", "api_key", "api-key"].contains(authType) else {
            return .ignored
        }
        guard let provider = mappedProvider(record) else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: nil,
                provider: nil,
                reason: .unknownProviderMapping
            ))
        }
        guard record.accountingVersion == 2, record.tokenBreakdown.schemaVersion == 2 else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: provider.profileID,
                provider: provider,
                reason: .unsupportedAccountingVersion
            ))
        }
        guard record.tokenBreakdown.quality == .complete, valid(record.tokenBreakdown) else {
            return .issue(.init(
                timestamp: record.timestamp,
                profileID: provider.profileID,
                provider: provider,
                reason: .incompleteTokenAccounting
            ))
        }

        let model = canonicalModel(record.model, provider: provider)
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
            profileID: provider.profileID,
            provider: provider,
            model: model,
            effectiveServiceTier: tier.isEmpty ? "default" : tier,
            pricingVariant: variant,
            tokenBreakdown: record.tokenBreakdown,
            failed: record.failed
        ))
    }

    private func mappedProvider(_ record: APIUsageQueueRecord) -> APIUsageProvider? {
        guard record.hasAuthIndex else { return nil }

        let provider = normalized(record.provider)
        let executor = normalized(record.executorType)
        let alias = normalized(record.alias)
        if ["claude", "anthropic"].contains(provider),
           executor.contains("claude"),
           alias.hasPrefix("cpm-claude-api/") {
            return .claude
        }
        if ["codex", "openai"].contains(provider),
           (executor.contains("codex") || executor.contains("openai")),
           alias.hasPrefix("cpm-codex-api/") {
            return .openAI
        }
        return nil
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

    private func canonicalModel(_ model: String, provider: APIUsageProvider) -> String {
        let normalizedModel = normalized(model)

        switch provider {
        case .claude:
            let prefix = "cpm-claude-api/"
            guard normalizedModel.hasPrefix(prefix) else { return normalizedModel }
            return String(normalizedModel.dropFirst(prefix.count))
        case .openAI:
            let prefix = "cpm-codex-api/"
            let modelWithoutRoutingPrefix: String
            if normalizedModel.hasPrefix(prefix) {
                modelWithoutRoutingPrefix = String(normalizedModel.dropFirst(prefix.count))
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
