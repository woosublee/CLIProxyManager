struct DashboardAccountSnapshot: Equatable, Identifiable {
    enum Status: Equatable {
        case connected
        case disconnected
    }

    let id: ProviderRowState.ID
    let title: String
    let commandName: String
    let commandSlug: String
    let detail: String
    let status: Status
    let primaryActionTitle: String
    let showsMoreMenu: Bool

    init(provider: ProviderRowState) {
        id = provider.id
        title = provider.name
        commandName = provider.functionName
        commandSlug = "$ \(provider.functionName)"
        detail = provider.connectionDetail
        status = provider.isConnected ? .connected : .disconnected
        primaryActionTitle = provider.isConnected ? "Settings" : "Connect"
        showsMoreMenu = provider.isConnected
    }
}
