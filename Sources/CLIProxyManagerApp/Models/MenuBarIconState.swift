import CLIProxyManagerCore

enum MenuBarIconState: Equatable, Sendable {
    case connected
    case connecting
    case stopped

    init(serverControlState: ServerControlState, severity: DiagnosticSeverity) {
        switch serverControlState {
        case .starting:
            self = .connecting
        case .running where severity == .ready:
            self = .connected
        case .running, .stopping, .stopped, .error:
            self = .stopped
        }
    }

    var accessibilityStatus: String {
        switch self {
        case .connected: "connected"
        case .connecting: "connecting"
        case .stopped: "stopped"
        }
    }
}
