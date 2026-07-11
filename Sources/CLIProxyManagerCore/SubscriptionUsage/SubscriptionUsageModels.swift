import Foundation

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetAt = resetAt
    }
}

public struct SubscriptionUsageSnapshot: Codable, Equatable, Sendable {
    public let profileID: String
    public let provider: AuthProfileType
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public init(profileID: String, provider: AuthProfileType, windows: [UsageWindow], fetchedAt: Date) {
        self.profileID = profileID
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

public enum SubscriptionUsageIssue: String, Codable, Equatable, Sendable {
    case proxyUnavailable
    case managementKeyRejected
    case managementAPINotSupported
    case credentialExpired
    case credentialDisabled
    case authFileNotMatched
    case providerContractUnsupported
    case schemaMismatch
    case transientFailure
    case unknownProvider

    public var message: String {
        switch self {
        case .proxyUnavailable:
            "Local proxy is unavailable."
        case .managementKeyRejected:
            "Management key was rejected."
        case .managementAPINotSupported:
            "This CLIProxyAPI version does not support subscription usage."
        case .credentialExpired:
            "Credential needs attention."
        case .credentialDisabled:
            "Credential is disabled."
        case .authFileNotMatched:
            "Registered credential could not be matched."
        case .providerContractUnsupported:
            "This provider does not support subscription usage."
        case .schemaMismatch:
            "Usage response format changed."
        case .transientFailure:
            "Usage could not be refreshed."
        case .unknownProvider:
            "Unknown credential provider."
        }
    }

    public var stopsPolling: Bool {
        switch self {
        case .credentialExpired, .credentialDisabled, .managementAPINotSupported, .schemaMismatch,
             .managementKeyRejected, .providerContractUnsupported, .unknownProvider:
            true
        case .proxyUnavailable, .authFileNotMatched, .transientFailure:
            false
        }
    }
}

public enum AccountSubscriptionUsageState: Equatable, Sendable {
    case disabled
    case managementKeyNotConfigured
    case loading
    case available(SubscriptionUsageSnapshot)
    case unavailable(SubscriptionUsageIssue)

    public var shouldDisplayInMenuBar: Bool {
        switch self {
        case .disabled, .managementKeyNotConfigured:
            false
        case .loading, .available, .unavailable:
            true
        }
    }
}

public struct SubscriptionUsageReport: Equatable, Sendable {
    public let statesByProfileID: [String: AccountSubscriptionUsageState]
    public let fetchedAt: Date

    public init(statesByProfileID: [String: AccountSubscriptionUsageState], fetchedAt: Date) {
        self.statesByProfileID = statesByProfileID
        self.fetchedAt = fetchedAt
    }
}

public protocol SubscriptionQuotaFetching: Sendable {
    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport
}

public protocol SubscriptionUsageManagementKeyConfiguring: Sendable {
    func isConfigured() -> Bool
    func createManagementKeyIfNeeded() throws -> Bool
    func setManagementKey(_ value: String) throws
    func deleteManagementKey() throws
}

protocol SubscriptionUsageManagementKeyProviding: SubscriptionUsageManagementKeyConfiguring {
    func managementKey() throws -> String
}
