import Foundation

public enum AuthProfileType: String, Codable, Equatable, Sendable {
    case claude
    case codex
}

public struct AuthProfile: Equatable, Identifiable, Sendable {
    public var id: String { fileName }

    public let fileName: String
    public let type: AuthProfileType
    public let email: String?
    public let accountID: String?
    public let expired: String?
    public let disabled: Bool

    public init(
        fileName: String,
        type: AuthProfileType,
        email: String?,
        accountID: String?,
        expired: String?,
        disabled: Bool
    ) {
        self.fileName = fileName
        self.type = type
        self.email = email
        self.accountID = accountID
        self.expired = expired
        self.disabled = disabled
    }
}
