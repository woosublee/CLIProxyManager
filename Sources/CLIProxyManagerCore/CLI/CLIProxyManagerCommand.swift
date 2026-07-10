import Foundation

public enum CLIProxyManagerCommandError: Error, Equatable, CustomStringConvertible {
    case usage
    case emptySecret(String)
    case prerequisite(String)
    case operation(String)

    public var description: String {
        switch self {
        case .usage:
            "Usage: cliproxy-manager secret <get|set|delete> claude-api-key | cliproxy-manager routing next <round-robin-profile-id>"
        case .emptySecret(let key):
            "Secret value cannot be empty: \(key)"
        case .prerequisite(let message), .operation(let message):
            message
        }
    }

    public var exitCode: CLICommandExitCode {
        switch self {
        case .usage, .emptySecret:
            .usage
        case .prerequisite:
            .prerequisite
        case .operation:
            .failure
        }
    }
}

public struct CLIProxyManagerCommand: Sendable {
    private let secretStore: any SecretStore
    private let configStore: AppConfigStore
    private let authProfileStore: AuthProfileStore
    private let stateSelector: any RoundRobinStateSelecting
    private let input: @Sendable () -> String
    private let output: any CLICommandOutputWriting

    public init(
        secretStore: any SecretStore = KeychainSecretStore(),
        configStore: AppConfigStore = AppConfigStore(),
        authProfileStore: AuthProfileStore = AuthProfileStore(),
        stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore(),
        input: @escaping @Sendable () -> String = {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        },
        output: any CLICommandOutputWriting = TerminalCommandOutput()
    ) {
        self.secretStore = secretStore
        self.configStore = configStore
        self.authProfileStore = authProfileStore
        self.stateSelector = stateSelector
        self.input = input
        self.output = output
    }

    public func run(arguments: [String]) async throws {
        if arguments.count == 3, arguments[0] == "secret" {
            try runSecret(arguments: arguments)
            return
        }
        if arguments.count == 3, arguments[0] == "routing", arguments[1] == "next" {
            try runRoutingNext(profileID: arguments[2])
            return
        }
        throw CLIProxyManagerCommandError.usage
    }

    private func runSecret(arguments: [String]) throws {
        guard let key = SecretKey(rawValue: arguments[2]) else {
            throw CLIProxyManagerCommandError.usage
        }
        switch arguments[1] {
        case "get":
            output.writeStdout("\(try secretStore.get(key))\n")
        case "set":
            let value = input().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw CLIProxyManagerCommandError.emptySecret(key.rawValue)
            }
            try secretStore.set(value, for: key)
        case "delete":
            try secretStore.delete(key)
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    private func runRoutingNext(profileID: String) throws {
        let config = try configStore.load()
        let authProfiles = try authProfileStore.profiles()
        let service = RoundRobinSelectionService(stateSelector: stateSelector)
        output.writeStdout("\(try service.shellEnvironmentAssignments(profileID: profileID, config: config, authProfiles: authProfiles))\n")
    }
}
