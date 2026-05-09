struct ProviderRowState: Identifiable, Equatable {
    enum ID: String {
        case claude
        case codex
    }

    let id: ID
    let name: String
    let functionName: String
    let connectionTitle: String
    let connectionDetail: String
    let isConnected: Bool
}
