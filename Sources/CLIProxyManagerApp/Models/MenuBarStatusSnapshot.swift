import CLIProxyManagerCore

struct MenuBarConnectedProvider: Equatable, Identifiable {
    let id: ProviderRowState.ID
    let name: String           // Provider type, e.g. "Claude OAuth"
    let displayName: String    // Account identifier — email when known, else provider name
    let functionName: String
    let connectionDetail: String
}

struct MenuBarStatusSnapshot: Equatable {
    let serverTitle: String
    let serverDetail: String
    let isServerRunning: Bool
    let serverActionTitle: String
    let endpointTitle: String?
    let connectedProviders: [MenuBarConnectedProvider]
    let erroredCount: Int
    let emptyProviderMessage = "No connected accounts"

    init(serverStatus: DiagnosticStatus, providers: [ProviderRowState], port: Int = 18_317) {
        serverTitle = serverStatus.title
        serverDetail = serverStatus.message
        isServerRunning = serverStatus.severity == .ready
        serverActionTitle = isServerRunning ? "Stop Server" : "Start Server"
        endpointTitle = isServerRunning ? "localhost:\(port)" : nil
        connectedProviders = providers
            .filter(\.isConnected)
            .map { provider in
                MenuBarConnectedProvider(
                    id: provider.id,
                    name: provider.name,
                    displayName: provider.displayTitle,
                    functionName: provider.functionName,
                    connectionDetail: provider.connectionDetail
                )
            }
        erroredCount = providers.filter(\.isErrored).count
    }
}
