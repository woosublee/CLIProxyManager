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
    let isErrored: Bool
    let accountDetailHidden: Bool

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
        isErrored: Bool = false,
        accountDetailHidden: Bool = true
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
        self.isErrored = isErrored
        self.accountDetailHidden = accountDetailHidden
    }

    var displayTitle: String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNickname.isEmpty ? name : trimmedNickname
    }

    private static func inferredProviderType(from id: ID) -> AuthProfileType {
        id.rawValue.lowercased().contains("codex") ? .codex : .claude
    }
}
