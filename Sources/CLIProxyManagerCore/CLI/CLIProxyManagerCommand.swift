import Darwin
import Foundation

public enum CLIProxyManagerCommandError: Error, Equatable, CustomStringConvertible {
    case usage
    case emptySecret(String)
    case prerequisite(String)
    case operation(String)

    public var description: String {
        switch self {
        case .usage:
            """
            Usage:
              cpm status [--json]
              cpm start | stop | restart
              cpm logs [--lines <N>] [-f]
              cpm app status | start | stop | restart
              cpm secret get|set|delete claude-api-key
              cpm routing next <round-robin-profile-id>
            """
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
    private let proxyRuntime: any ProxyRuntimeServicing
    private let appLifecycle: any AppLifecycleControlling
    private let logService: any ProxyLogServicing
    private let statusReporter: any StatusReporting
    private let currentUID: @Sendable () -> uid_t

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
        self.proxyRuntime = ProxyRuntimeService()
        self.appLifecycle = AppLifecycleService()
        self.logService = ProxyLogService()
        self.statusReporter = StatusService()
        self.currentUID = { geteuid() }
    }

    init(
        secretStore: any SecretStore = KeychainSecretStore(),
        configStore: AppConfigStore = AppConfigStore(),
        authProfileStore: AuthProfileStore = AuthProfileStore(),
        stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore(),
        input: @escaping @Sendable () -> String = {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        },
        output: any CLICommandOutputWriting = TerminalCommandOutput(),
        proxyRuntime: any ProxyRuntimeServicing,
        appLifecycle: any AppLifecycleControlling,
        logService: any ProxyLogServicing,
        statusReporter: any StatusReporting,
        currentUID: @escaping @Sendable () -> uid_t = { geteuid() }
    ) {
        self.secretStore = secretStore
        self.configStore = configStore
        self.authProfileStore = authProfileStore
        self.stateSelector = stateSelector
        self.input = input
        self.output = output
        self.proxyRuntime = proxyRuntime
        self.appLifecycle = appLifecycle
        self.logService = logService
        self.statusReporter = statusReporter
        self.currentUID = currentUID
    }

    public func run(arguments: [String]) async throws {
        // Legacy commands
        if arguments.count == 3, arguments[0] == "secret" {
            try runSecret(arguments: arguments)
            return
        }
        if arguments.count == 3, arguments[0] == "routing", arguments[1] == "next" {
            try runRoutingNext(profileID: arguments[2])
            return
        }

        switch arguments.first {
        case "status":
            try await runStatus(arguments: arguments)
        case "start":
            guard arguments.count == 1 else { throw CLIProxyManagerCommandError.usage }
            try requireNonRoot()
            let result = try await proxyRuntime.start()
            output.writeStdout("Proxy started on port \(result.port).\n")
        case "stop":
            guard arguments.count == 1 else { throw CLIProxyManagerCommandError.usage }
            try requireNonRoot()
            _ = try await proxyRuntime.stop()
            output.writeStdout("Proxy stopped.\n")
        case "restart":
            guard arguments.count == 1 else { throw CLIProxyManagerCommandError.usage }
            try requireNonRoot()
            let result = try await proxyRuntime.restart()
            output.writeStdout("Proxy restarted on port \(result.port).\n")
        case "logs":
            try await runLogs(arguments: arguments)
        case "app":
            try await runApp(arguments: arguments)
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    // MARK: - Runtime subcommands

    private func runStatus(arguments: [String]) async throws {
        var useJSON = false
        var i = arguments.index(after: arguments.startIndex)
        while i < arguments.endIndex {
            let arg = arguments[i]
            i = arguments.index(after: i)
            switch arg {
            case "--json":
                guard !useJSON else { throw CLIProxyManagerCommandError.usage }
                useJSON = true
            default:
                throw CLIProxyManagerCommandError.usage
            }
        }
        let cpmStatus = try await statusReporter.status()
        if useJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(cpmStatus)
            output.writeStdout(String(data: data, encoding: .utf8)! + "\n")
        } else {
            let app = cpmStatus.app
            let helper = cpmStatus.helper
            let proxy = cpmStatus.proxy
            let versionSuffix = app.version.map { ", v\($0)" } ?? ""
            output.writeStdout("App: installed=\(app.installed), running=\(app.running)\(versionSuffix)\n")
            output.writeStdout("Helper: \(helper.path) (\(helper.installed ? "installed" : "not installed"))\n")
            let activeVersionSuffix = proxy.activeVersion.map { ", version=\($0)" } ?? ""
            output.writeStdout("Proxy: port=\(proxy.port), running=\(proxy.running)\(activeVersionSuffix)\n")
        }
    }

    private func runLogs(arguments: [String]) async throws {
        var lineCount = 200
        var follow = false
        var seenLines = false
        var idx = 1
        while idx < arguments.count {
            let arg = arguments[idx]
            switch arg {
            case "-f":
                guard !follow else { throw CLIProxyManagerCommandError.usage }
                follow = true
            case "--lines":
                guard !seenLines else { throw CLIProxyManagerCommandError.usage }
                idx += 1
                guard idx < arguments.count, let n = Int(arguments[idx]), n > 0 else {
                    throw CLIProxyManagerCommandError.usage
                }
                lineCount = n
                seenLines = true
            default:
                throw CLIProxyManagerCommandError.usage
            }
            idx += 1
        }
        if follow {
            try logService.follow()
        } else {
            let snapshot = try logService.readLastLines(lineCount)
            output.writeStdout(snapshot.text)
        }
    }

    private func runApp(arguments: [String]) async throws {
        guard arguments.count == 2 else { throw CLIProxyManagerCommandError.usage }
        switch arguments[1] {
        case "status":
            let status = try await appLifecycle.status()
            let versionSuffix = status.version.map { ", v\($0)" } ?? ""
            output.writeStdout("App: installed=\(status.installed), running=\(status.running)\(versionSuffix)\n")
        case "start":
            try requireNonRoot()
            _ = try await appLifecycle.start()
            output.writeStdout("App started.\n")
        case "stop":
            try requireNonRoot()
            _ = try await appLifecycle.stop()
            output.writeStdout("App stopped.\n")
        case "restart":
            try requireNonRoot()
            _ = try await appLifecycle.restart()
            output.writeStdout("App restarted.\n")
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    // MARK: - Root check

    private func requireNonRoot() throws {
        guard currentUID() != 0 else {
            throw CLIProxyManagerCommandError.prerequisite(
                "cpm must run as the macOS user that owns ~/.cliproxy-manager; do not use sudo."
            )
        }
    }

    // MARK: - Legacy commands

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
