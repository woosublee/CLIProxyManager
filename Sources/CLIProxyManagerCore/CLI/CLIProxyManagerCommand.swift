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
              cpm update check [app | proxy | all]
              cpm update stage [app | proxy | all]
              cpm update apply [app | proxy | all] [--yes]
              cpm secret get|set|delete claude-api-key
              cpm routing next <round-robin-profile-id>
              cpm quota [--json]
              cpm quota key status [--json] | set --stdin | delete
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
    private let proxyUpdater: any ProxyUpdating
    private let appUpdater: any AppUpdating
    private let subscriptionQuotaClient: any SubscriptionQuotaFetching
    private let subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring
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
        output: any CLICommandOutputWriting = TerminalCommandOutput(),
        subscriptionQuotaClient: any SubscriptionQuotaFetching = CLIProxyAPISubscriptionQuotaClient(),
        subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring = SubscriptionUsageManagementKeyFileStore()
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
        self.proxyUpdater = ProxyUpdateService()
        self.appUpdater = AppUpdateService()
        self.subscriptionQuotaClient = subscriptionQuotaClient
        self.subscriptionUsageKeyStore = subscriptionUsageKeyStore
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
        proxyUpdater: any ProxyUpdating = ProxyUpdateService(),
        appUpdater: any AppUpdating = AppUpdateService(),
        subscriptionQuotaClient: any SubscriptionQuotaFetching = CLIProxyAPISubscriptionQuotaClient(),
        subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring = SubscriptionUsageManagementKeyFileStore(),
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
        self.proxyUpdater = proxyUpdater
        self.appUpdater = appUpdater
        self.subscriptionQuotaClient = subscriptionQuotaClient
        self.subscriptionUsageKeyStore = subscriptionUsageKeyStore
        self.currentUID = currentUID
    }

    public func run(arguments: [String]) async throws {
        if arguments.first == "--help" || arguments.first == "-h" || arguments.isEmpty {
            output.writeStdout("\(CLIProxyManagerCommandError.usage.description)\n")
            return
        }

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
        case "update":
            try await runUpdate(arguments: arguments)
        case "quota":
            try await runQuota(arguments: arguments)
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

    private func runUpdate(arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw CLIProxyManagerCommandError.usage }
        let verb = arguments[1]
        guard ["check", "stage", "apply"].contains(verb) else {
            throw CLIProxyManagerCommandError.usage
        }

        let remaining = Array(arguments.dropFirst(2))
        let hasYes = remaining.contains("--yes")
        let targets = remaining.filter { $0 != "--yes" }

        guard targets.count <= 1 else { throw CLIProxyManagerCommandError.usage }
        if hasYes && verb != "apply" { throw CLIProxyManagerCommandError.usage }

        let target = targets.first ?? "all"
        guard ["proxy", "app", "all"].contains(target) else {
            throw CLIProxyManagerCommandError.usage
        }

        let runProxy = (target == "proxy" || target == "all")
        let runApp = (target == "app" || target == "all")

        switch verb {
        case "check":
            if runApp {
                let result = try await appUpdater.check()
                output.writeStdout("App: \(appCheckDescription(result))\n")
            }
            if runProxy {
                let result = try await proxyUpdater.check()
                output.writeStdout("Proxy: \(proxyCheckDescription(result))\n")
            }

        case "stage":
            if runApp {
                let result = try await appUpdater.stage()
                output.writeStdout("App: \(appStageDescription(result))\n")
            }
            if runProxy {
                let result = try await proxyUpdater.stage()
                output.writeStdout("Proxy: \(proxyStageDescription(result))\n")
            }

        case "apply":
            if !hasYes {
                guard output.isInteractive else { throw CLIProxyManagerCommandError.usage }
                let prompt: String
                switch target {
                case "proxy": prompt = "Apply staged CLIProxyAPI update?"
                case "app":   prompt = "Apply staged CLIProxyManager update?"
                default:      prompt = "Apply all staged updates?"
                }
                guard output.confirm(prompt) else { return }
            }
            if target == "all" {
                var appError: Error?
                var proxyError: Error?
                do {
                    let result = try await appUpdater.apply()
                    output.writeStdout("App: Applied CLIProxyManager \(result.version).\n")
                } catch let err as CLIProxyManagerCommandError where isNoStageError(err, for: "app") {
                    output.writeStdout("App: No staged update.\n")
                } catch {
                    appError = error
                    output.writeStderr("App: \(error.localizedDescription)\n")
                }
                do {
                    let result = try await proxyUpdater.apply()
                    if result.restartedProxy {
                        output.writeStdout("Proxy: Applied CLIProxyAPI \(result.version) and restarted.\n")
                    } else {
                        output.writeStdout("Proxy: Applied CLIProxyAPI \(result.version); proxy remains stopped.\n")
                    }
                } catch let err as CLIProxyManagerCommandError where isNoStageError(err, for: "proxy") {
                    output.writeStdout("Proxy: No staged update.\n")
                } catch {
                    proxyError = error
                    output.writeStderr("Proxy: \(error.localizedDescription)\n")
                }
                if let err = appError ?? proxyError { throw err }
            } else if target == "app" {
                let result = try await appUpdater.apply()
                output.writeStdout("Applied CLIProxyManager \(result.version).\n")
            } else {
                let result = try await proxyUpdater.apply()
                if result.restartedProxy {
                    output.writeStdout("Applied CLIProxyAPI \(result.version) and restarted the proxy.\n")
                } else {
                    output.writeStdout("Applied CLIProxyAPI \(result.version); the proxy remains stopped.\n")
                }
            }
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    private func runQuota(arguments: [String]) async throws {
        let remaining = Array(arguments.dropFirst())
        if remaining.first == "key" {
            try await runQuotaKey(arguments: Array(remaining.dropFirst()))
            return
        }

        let useJSON: Bool
        switch remaining {
        case []:
            useJSON = false
        case ["--json"]:
            useJSON = true
        default:
            throw CLIProxyManagerCommandError.usage
        }

        let config = try configStore.load()
        let profiles = try authProfileStore.profiles()
        let report: SubscriptionUsageReport
        if config.subscriptionUsage.isEnabled {
            report = await subscriptionQuotaClient.fetchUsage(port: config.port, profiles: profiles)
        } else {
            report = SubscriptionUsageReport(
                statesByProfileID: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, .disabled) }),
                fetchedAt: Date()
            )
        }

        if useJSON {
            let records = profiles.map { profile in
                QuotaCLIRecord(
                    profileID: profile.id,
                    provider: profile.type,
                    state: report.statesByProfileID[profile.id] ?? .disabled
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(QuotaCLIOutput(fetchedAt: report.fetchedAt, accounts: records))
            output.writeStdout(String(decoding: data, as: UTF8.self) + "\n")
            return
        }

        let accounts = quotaTextAccounts(config: config, profiles: profiles)
        guard !accounts.isEmpty else {
            output.writeStdout("No connected accounts\n")
            return
        }

        for (index, account) in accounts.enumerated() {
            if index > 0 {
                output.writeStdout("\n")
            }
            let state = report.statesByProfileID[account.profile.id] ?? .disabled
            output.writeStdout("\(account.title)  $ \(account.commandName)\n")
            writeQuotaText(state: state, provider: account.profile.type)
        }
    }

    private func runQuotaKey(arguments: [String]) async throws {
        switch arguments {
        case ["status"]:
            output.writeStdout("configured=\(subscriptionUsageKeyStore.isConfigured())\n")
        case ["status", "--json"]:
            let data = try JSONEncoder().encode(QuotaKeyStatus(configured: subscriptionUsageKeyStore.isConfigured()))
            output.writeStdout(String(decoding: data, as: UTF8.self) + "\n")
        case ["set", "--stdin"]:
            guard !output.isInteractive else { throw CLIProxyManagerCommandError.usage }
            let value = input().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CLIProxyManagerCommandError.emptySecret("subscription-usage-management-key") }
            try subscriptionUsageKeyStore.setManagementKey(value)
            try enableSubscriptionUsage()
            try await restartProxyIfRunning()
            output.writeStdout("Management key stored.\n")
        case ["delete"]:
            try subscriptionUsageKeyStore.deleteManagementKey()
            try await restartProxyIfRunning()
            output.writeStdout("Management key removed.\n")
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    private func enableSubscriptionUsage() throws {
        var config = try configStore.load()
        guard !config.subscriptionUsage.isEnabled else { return }
        config.subscriptionUsage.isEnabled = true
        try configStore.save(config)
    }

    private func restartProxyIfRunning() async throws {
        let status = try await proxyRuntime.status()
        guard status.running else { return }
        _ = try await proxyRuntime.restart()
    }

    private struct QuotaTextAccount {
        let profile: AuthProfile
        let title: String
        let commandName: String
    }

    private func quotaTextAccounts(config: AppConfig, profiles: [AuthProfile]) -> [QuotaTextAccount] {
        if config.oauthCommandProfiles.isEmpty {
            return profiles.compactMap { profile in
                guard !profile.disabled else { return nil }
                let commandName = (profile.type == .claude ? config.commands.cc : config.commands.ccodex)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !commandName.isEmpty else { return nil }
                let nickname = (profile.type == .claude ? config.nicknames.cc : config.nicknames.ccodex)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let providerTitle = profile.type == .claude ? "Claude OAuth" : "Codex OAuth"
                return QuotaTextAccount(profile: profile, title: nickname.isEmpty ? providerTitle : nickname, commandName: commandName)
            }
        }

        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return config.oauthCommandProfiles.compactMap { commandProfile in
            guard commandProfile.isEnabled,
                  let profile = profilesByID[commandProfile.authProfileID],
                  !profile.disabled else { return nil }
            let commandName = commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandName.isEmpty else { return nil }
            let nickname = commandProfile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerTitle = commandProfile.provider == .claude ? "Claude OAuth" : "Codex OAuth"
            return QuotaTextAccount(profile: profile, title: nickname.isEmpty ? providerTitle : nickname, commandName: commandName)
        }
    }

    private func writeQuotaText(state: AccountSubscriptionUsageState, provider: AuthProfileType) {
        switch state {
        case .disabled:
            output.writeStdout("  Subscription usage is disabled.\n")
        case .managementKeyNotConfigured:
            output.writeStdout("  Management key is not configured.\n")
        case .loading:
            output.writeStdout("  Checking subscription usage…\n")
        case .unavailable(let issue):
            output.writeStdout("  Usage unavailable — \(issue.message)\n")
        case .available(let snapshot):
            guard !snapshot.windows.isEmpty else {
                output.writeStdout("  Usage details unavailable\n")
                return
            }
            for window in snapshot.windows {
                let percent = Int(min(max(window.usedPercent, 0), 100).rounded())
                let label = quotaWindowLabel(window, provider: provider)
                let displayLabel = label.count < 4
                    ? label.padding(toLength: 4, withPad: " ", startingAt: 0)
                    : label
                output.writeStdout("  \(displayLabel) \(quotaProgressBar(usedPercent: window.usedPercent)) \(String(format: "%3d", percent))%\n")
                if let resetAt = window.resetAt {
                    output.writeStdout("       Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))\n")
                }
            }
        }
    }

    private func quotaWindowLabel(_ window: UsageWindow, provider: AuthProfileType) -> String {
        guard provider == .codex else { return window.label }
        guard let seconds = window.limitWindowSeconds else {
            switch window.id {
            case "primary": return "5h"
            case "secondary": return "7d"
            default: return window.label
            }
        }

        if seconds >= 2_419_200 {
            return "1mo"
        }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400))d"
        }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600))h"
        }
        return window.label
    }

    private func quotaProgressBar(usedPercent: Double) -> String {
        let percent = min(max(usedPercent, 0), 100)
        let filled = min(10, max(0, Int((percent / 10).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
    }

    private func appCheckDescription(_ result: AppUpdateCheckResult) -> String {
        switch result {
        case .upToDate(let v): return "CLIProxyManager is up to date\(v.map { " at \($0)" } ?? "")."
        case .available(let v, let r): return "Update available: \(v ?? "none") → \(r.version)."
        case .pending(_, let s): return "CLIProxyManager \(s.version) is staged."
        }
    }

    private func proxyCheckDescription(_ result: ProxyUpdateCheckResult) -> String {
        switch result {
        case .upToDate(let v): return "CLIProxyAPI is up to date\(v.map { " at \($0)" } ?? "")."
        case .available(let v, let r): return "Update available: \(v ?? "none") → \(r.version)."
        case .pending(_, let p): return "CLIProxyAPI \(p.version) is staged."
        }
    }

    private func appStageDescription(_ result: AppUpdateStageResult) -> String {
        result.staged ? "CLIProxyManager \(result.version) is staged." : "CLIProxyManager \(result.version) is already staged."
    }

    private func proxyStageDescription(_ result: ProxyUpdateStageResult) -> String {
        result.staged ? "CLIProxyAPI \(result.version) is staged." : "CLIProxyAPI \(result.version) is already staged."
    }

    private func isNoStageError(_ error: CLIProxyManagerCommandError, for _: String) -> Bool {
        if case .prerequisite(let msg) = error {
            return msg.contains("No staged")
        }
        return false
    }

    // MARK: - Quota output

    private struct QuotaCLIOutput: Codable {
        let fetchedAt: Date
        let accounts: [QuotaCLIRecord]
    }

    private struct QuotaCLIRecord: Codable {
        let profileID: String
        let provider: AuthProfileType
        let status: String
        let issue: SubscriptionUsageIssue?
        let windows: [UsageWindow]

        init(profileID: String, provider: AuthProfileType, state: AccountSubscriptionUsageState) {
            self.profileID = profileID
            self.provider = provider
            switch state {
            case .disabled:
                status = "disabled"
                issue = nil
                windows = []
            case .managementKeyNotConfigured:
                status = "management_key_not_configured"
                issue = nil
                windows = []
            case .loading:
                status = "loading"
                issue = nil
                windows = []
            case .available(let snapshot):
                status = "available"
                issue = nil
                windows = snapshot.windows
            case .unavailable(let value):
                status = "unavailable"
                issue = value
                windows = []
            }
        }
    }

    private struct QuotaKeyStatus: Codable {
        let configured: Bool
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
