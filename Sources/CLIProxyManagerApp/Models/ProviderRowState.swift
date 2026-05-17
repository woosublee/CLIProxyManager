struct ProviderRowState: Identifiable, Equatable {
    enum ID: String {
        case claude
        case codex
    }

    let id: ID
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
}
