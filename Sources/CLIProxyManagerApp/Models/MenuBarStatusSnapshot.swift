import CLIProxyManagerCore

struct MenuBarConnectedProvider: Equatable, Identifiable {
    let id: ProviderRowState.ID
    let name: String           // Provider type, e.g. "Claude OAuth"
    let displayName: String    // Account identifier — email when known, else provider name
    let functionName: String
    let connectionDetail: String
}

struct MenuBarStatusSnapshot: Equatable {
    enum IndicatorState: Equatable {
        case running
        case stopped
        case error
    }

    let serverTitle: String
    let serverDetail: String
    let statusLabel: String
    let indicatorState: IndicatorState
    let isServerRunning: Bool
    let serverActionTitle: String
    let endpointTitle: String?
    let connectedProviders: [MenuBarConnectedProvider]
    let erroredCount: Int
    let emptyProviderMessage = "No connected accounts"

    init(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState = .stopped,
        providers: [ProviderRowState],
        port: Int = 18_317
    ) {
        let displayState = Self.displayState(serverStatus: serverStatus, serverControlState: serverControlState)
        serverTitle = serverStatus.title
        serverDetail = serverStatus.message
        statusLabel = displayState.label
        indicatorState = displayState.indicatorState
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

    private enum DisplayState: Equatable {
        case running
        case stopped
        case starting
        case stopping
        case error

        var label: String {
            switch self {
            case .running: return "Running"
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .stopping: return "Stopping"
            case .error: return "Error"
            }
        }

        var indicatorState: IndicatorState {
            switch self {
            case .running, .starting: return .running
            case .stopped, .stopping: return .stopped
            case .error: return .error
            }
        }
    }

    private static func displayState(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState
    ) -> DisplayState {
        switch serverControlState {
        case .starting:
            return .starting
        case .stopping:
            return .stopping
        case .stopped, .running, .error:
            switch serverStatus.severity {
            case .ready: return .running
            case .warning: return .stopped
            case .error: return .error
            }
        }
    }
}
