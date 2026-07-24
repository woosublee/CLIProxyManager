import Foundation

public enum APIUsageTokenAccountingQuality: String, Decodable, Equatable, Sendable {
    case complete, inconsistent, unclassified
}

public struct APIUsageTokenInputBreakdown: Decodable, Equatable, Sendable {
    public let totalTokens: Int64
    public let uncachedTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64

    public init(
        totalTokens: Int64,
        uncachedTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) {
        self.totalTokens = totalTokens
        self.uncachedTokens = uncachedTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case uncachedTokens = "uncached_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
    }
}

public struct APIUsageTokenOutputBreakdown: Decodable, Equatable, Sendable {
    public let totalTokens: Int64
    public let nonReasoningTokens: Int64
    public let reasoningTokens: Int64

    public init(totalTokens: Int64, nonReasoningTokens: Int64, reasoningTokens: Int64) {
        self.totalTokens = totalTokens
        self.nonReasoningTokens = nonReasoningTokens
        self.reasoningTokens = reasoningTokens
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case nonReasoningTokens = "non_reasoning_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

public struct APIUsageTokenBreakdown: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let quality: APIUsageTokenAccountingQuality
    public let totalTokens: Int64
    public let input: APIUsageTokenInputBreakdown
    public let output: APIUsageTokenOutputBreakdown
    public let unclassifiedTokens: Int64

    public init(
        schemaVersion: Int,
        quality: APIUsageTokenAccountingQuality,
        totalTokens: Int64,
        input: APIUsageTokenInputBreakdown,
        output: APIUsageTokenOutputBreakdown,
        unclassifiedTokens: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.quality = quality
        self.totalTokens = totalTokens
        self.input = input
        self.output = output
        self.unclassifiedTokens = unclassifiedTokens
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case quality
        case totalTokens = "total_tokens"
        case input
        case output
        case unclassifiedTokens = "unclassified_tokens"
    }
}

public struct APIUsageQueueRecord: Decodable, Equatable, Sendable {
    public let timestamp: Date
    public let provider: String
    public let executorType: String
    public let model: String
    public let alias: String
    public let authType: String
    public let hasAuthIndex: Bool
    public let failed: Bool
    public let accountingVersion: Int
    public let tokenBreakdown: APIUsageTokenBreakdown
    public let serviceTier: String
    public let responseServiceTier: String?

    enum CodingKeys: String, CodingKey {
        case timestamp, provider, model, alias, failed
        case executorType = "executor_type"
        case authType = "auth_type"
        case authIndex = "auth_index"
        case accountingVersion = "accounting_version"
        case tokenBreakdown = "token_breakdown"
        case serviceTier = "service_tier"
        case responseServiceTier = "response_service_tier"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        provider = try container.decode(String.self, forKey: .provider)
        executorType = try container.decode(String.self, forKey: .executorType)
        model = try container.decode(String.self, forKey: .model)
        alias = try container.decode(String.self, forKey: .alias)
        authType = try container.decode(String.self, forKey: .authType)
        let rawAuthIndex = try container.decode(String.self, forKey: .authIndex)
        hasAuthIndex = !rawAuthIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        failed = try container.decode(Bool.self, forKey: .failed)
        accountingVersion = try container.decode(Int.self, forKey: .accountingVersion)
        tokenBreakdown = try container.decode(APIUsageTokenBreakdown.self, forKey: .tokenBreakdown)
        serviceTier = try container.decode(String.self, forKey: .serviceTier)
        responseServiceTier = try container.decodeIfPresent(String.self, forKey: .responseServiceTier)
    }
}

public enum APIUsageQueueClientError: Error, Equatable, Sendable {
    case invalidPort
    case invalidCount
    case managementKeyNotConfigured
    case managementKeyRejected
    case managementAPINotSupported
    case transientFailure
    case proxyUnavailable
    case schemaMismatch
}

public protocol APIUsageQueueFetching: Sendable {
    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord]
}
