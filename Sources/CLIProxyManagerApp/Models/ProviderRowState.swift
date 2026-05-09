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

    var displayTitle: String {
        nickname.isEmpty ? name : nickname
    }
}
