import CLIProxyManagerCore

struct UsageOverlayAccountPresentation: Equatable {
    let providers: [MenuBarConnectedProvider]
    let emptyMessage: String?

    init(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState,
        providerRows: [ProviderRowState],
        port: Int
    ) {
        let selectedRows = providerRows.filter(\.showsInUsageOverlay)
        let connectedProviders = MenuBarStatusSnapshot(
            serverStatus: serverStatus,
            serverControlState: serverControlState,
            providers: selectedRows,
            port: port,
            showsSubscriptionUsage: true
        ).connectedProviders
        self.providers = connectedProviders

        if !providerRows.isEmpty, selectedRows.isEmpty {
            emptyMessage = "No accounts selected"
        } else if connectedProviders.isEmpty {
            emptyMessage = "No connected accounts"
        } else {
            emptyMessage = nil
        }
    }
}
