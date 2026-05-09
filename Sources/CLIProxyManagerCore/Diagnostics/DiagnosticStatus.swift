import Foundation

public enum DiagnosticSeverity: String, Equatable, Sendable {
    case ready
    case warning
    case error
}

public struct DiagnosticStatus: Equatable, Sendable {
    public let severity: DiagnosticSeverity
    public let title: String
    public let message: String

    public init(severity: DiagnosticSeverity, title: String, message: String) {
        self.severity = severity
        self.title = title
        self.message = message
    }
}

public enum ServerControlState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
