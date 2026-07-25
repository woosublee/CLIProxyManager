import CLIProxyManagerCore

struct MenuBarConnectedProvider: Equatable, Identifiable {
    let id: ProviderRowState.ID
    let name: String           // Provider type, e.g. "Claude OAuth"
    let displayName: String    // Trimmed account nickname, or provider name fallback
    let functionName: String
    let connectionDetail: String
    let accountDetailHidden: Bool
    let usageState: ProviderUsageState
    let showsUsage: Bool

    var menuBarDisplayName: String {
        displayName
    }

    var usageOverlayDisplayName: String {
        displayName
    }

    var menuBarConnectionDetail: String? {
        accountDetailHidden ? nil : connectionDetail
    }

    // Temporary compatibility projection while Task 11/12 migrate view call sites.
    var subscriptionUsageState: AccountSubscriptionUsageState {
        usageState.subscriptionCompatibilityState
    }

    var showsSubscriptionUsage: Bool {
        showsUsage && usageState.isSubscription
    }
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
        port: Int = 18_317,
        showsUsage: Bool = true
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
            .filter { !$0.isDisabled }
            .map { provider in
                MenuBarConnectedProvider(
                    id: provider.id,
                    name: provider.name,
                    displayName: provider.displayTitle,
                    functionName: provider.functionName,
                    connectionDetail: provider.connectionDetail,
                    accountDetailHidden: provider.accountDetailHidden,
                    usageState: provider.usageState,
                    showsUsage: provider.showsUsage && showsUsage
                )
            }
        erroredCount = providers.filter(\.isErrored).count
    }

    // Temporary forwarding overload while Task 12 migrates the persisted-setting label.
    init(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState = .stopped,
        providers: [ProviderRowState],
        port: Int = 18_317,
        showsSubscriptionUsage: Bool
    ) {
        self.init(
            serverStatus: serverStatus,
            serverControlState: serverControlState,
            providers: providers,
            port: port,
            showsUsage: showsSubscriptionUsage
        )
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
