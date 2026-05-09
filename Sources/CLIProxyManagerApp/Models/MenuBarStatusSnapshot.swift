import CLIProxyManagerCore

struct MenuBarConnectedProvider: Equatable, Identifiable {
    let id: ProviderRowState.ID
    let name: String
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
    let emptyProviderMessage = "연결된 계정 없음"

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
                    functionName: provider.functionName,
                    connectionDetail: provider.connectionDetail
                )
            }
    }
}
