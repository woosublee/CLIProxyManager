import Foundation

public struct CodexResetCredit: Codable, Equatable, Sendable {
    public let title: String?
    public let status: String?
    public let resetType: String?
    public let expiresAt: Date?
    public let grantedAt: Date?

    public init(
        title: String?,
        status: String?,
        resetType: String?,
        expiresAt: Date?,
        grantedAt: Date?
    ) {
        self.title = title
        self.status = status
        self.resetType = resetType
        self.expiresAt = expiresAt
        self.grantedAt = grantedAt
    }
}

public struct CodexResetCreditsSnapshot: Codable, Equatable, Sendable {
    public let profileID: String
    public let reportedAvailableCount: Int?
    public let reportedTotalEarnedCount: Int?
    public let credits: [CodexResetCredit]
    public let fetchedAt: Date

    public init(
        profileID: String,
        reportedAvailableCount: Int?,
        reportedTotalEarnedCount: Int?,
        credits: [CodexResetCredit],
        fetchedAt: Date
    ) {
        self.profileID = profileID
        self.reportedAvailableCount = reportedAvailableCount
        self.reportedTotalEarnedCount = reportedTotalEarnedCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }
}

public enum CodexResetCreditsIssue: String, Codable, Equatable, Sendable {
    case accountIDUnavailable
    case credentialRejected
    case endpointUnsupported
    case schemaMismatch
    case transientFailure
}

public enum CodexResetCreditsRefreshOutcome: Equatable, Sendable {
    case available(CodexResetCreditsSnapshot)
    case unavailable(CodexResetCreditsIssue)
}
