import CLIProxyManagerCore
import Foundation

struct ProviderRowID: Hashable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    var description: String { rawValue }

    var inferredProviderType: AuthProfileType {
        let lowercasedValue = rawValue.lowercased()
        if lowercasedValue == AuthProfileType.codex.rawValue || lowercasedValue.hasPrefix("\(AuthProfileType.codex.rawValue)-") {
            return .codex
        }
        return .claude
    }

    static let claude = ProviderRowID(rawValue: "claude")
    static let codex = ProviderRowID(rawValue: "codex")
}

struct ProviderRowState: Identifiable, Equatable {
    typealias ID = ProviderRowID

    let id: ID
    let providerType: AuthProfileType
    let authProfileID: String
    let commandProfileID: String
    let name: String
    let nickname: String
    let functionName: String
    let connectionTitle: String
    let connectionDetail: String
    let isConnected: Bool
    let isDisabled: Bool
    let isErrored: Bool
    let accountDetailHidden: Bool
    let subscriptionUsageState: AccountSubscriptionUsageState

    init(
        id: ID,
        providerType: AuthProfileType? = nil,
        authProfileID: String? = nil,
        commandProfileID: String? = nil,
        name: String,
        nickname: String,
        functionName: String,
        connectionTitle: String,
        connectionDetail: String,
        isConnected: Bool,
        isDisabled: Bool = false,
        isErrored: Bool = false,
        accountDetailHidden: Bool = true,
        subscriptionUsageState: AccountSubscriptionUsageState = .disabled
    ) {
        self.id = id
        self.providerType = providerType ?? Self.inferredProviderType(from: id)
        self.authProfileID = authProfileID ?? id.rawValue
        self.commandProfileID = commandProfileID ?? id.rawValue
        self.name = name
        self.nickname = nickname
        self.functionName = functionName
        self.connectionTitle = connectionTitle
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.isDisabled = isDisabled
        self.isErrored = isErrored
        self.accountDetailHidden = accountDetailHidden
        self.subscriptionUsageState = subscriptionUsageState
    }

    var displayTitle: String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNickname.isEmpty ? name : trimmedNickname
    }

    private static func inferredProviderType(from id: ID) -> AuthProfileType {
        id.inferredProviderType
    }
}
