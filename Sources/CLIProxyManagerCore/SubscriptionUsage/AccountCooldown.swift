import Foundation

public struct AccountCooldown: Equatable, Sendable {
    public let scope: String
    public let modelKey: String?
    public let reason: String
    public let retryAt: Date
    public let remainingSeconds: Int

    public init(scope: String, modelKey: String? = nil, reason: String, retryAt: Date, remainingSeconds: Int) {
        self.scope = scope
        self.modelKey = modelKey
        self.reason = reason
        self.retryAt = retryAt
        self.remainingSeconds = remainingSeconds
    }

    public var isQuota: Bool { reason == "quota" || reason == "credential_quota" }
}

public struct AccountCooldownSnapshot: Equatable, Sendable {
    public let cooldowns: [AccountCooldown]
    public let observedAt: Date

    public init(cooldowns: [AccountCooldown], observedAt: Date) {
        self.cooldowns = cooldowns
        self.observedAt = observedAt
    }
}

public enum AccountCooldownState: Equatable, Sendable {
    case observed(AccountCooldownSnapshot)
    case unsupported
    case unavailable(SubscriptionUsageIssue)

    public var snapshot: AccountCooldownSnapshot? {
        guard case .observed(let snapshot) = self else { return nil }
        return snapshot
    }
}

public enum AccountQuotaResetResult: Equatable, Sendable {
    case reset
    case notNeeded(AccountCooldownState)
}

public enum AccountQuotaResetError: Error, LocalizedError, Equatable, Sendable {
    case invalidPort
    case managementKeyNotConfigured
    case management(SubscriptionUsageIssue)

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The local proxy port is invalid."
        case .managementKeyNotConfigured: "Enable usage management before clearing a quota cooldown."
        case .management(.managementAPINotSupported): "This CLIProxyAPI version does not support clearing quota cooldowns."
        case .management(.schemaMismatch): "The cooldown response could not be verified. Refresh the account status before retrying."
        case .management(let issue): issue.message
        }
    }
}

public protocol AccountQuotaResetting: Sendable {
    func resetQuota(
        port: Int,
        profile: AuthProfile,
        authorize: @escaping @Sendable () async -> Bool
    ) async throws -> AccountQuotaResetResult
}
