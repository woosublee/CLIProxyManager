import Foundation

public protocol ManagedProxyProcess: Sendable {
    func terminate()
    func waitUntilExit()
}

extension Process: ManagedProxyProcess {}

public protocol ProcessLaunching: Sendable {
    var usesManagedLaunchdJobs: Bool { get }
    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess
}

public extension ProcessLaunching {
    var usesManagedLaunchdJobs: Bool { true }
}

public protocol ProxyRuntimePreparing: Sendable {
    func prepare(port: Int) throws
}

public struct ProcessLauncher: ProcessLaunching {
    private let launchctl: any LaunchctlManaging
    private let processExists: @Sendable (pid_t) -> Bool

    public init() {
        self.launchctl = LaunchctlRunner()
        self.processExists = { kill($0, 0) == 0 }
    }

    init(launchctl: any LaunchctlManaging, processExists: @escaping @Sendable (pid_t) -> Bool) {
        self.launchctl = launchctl
        self.processExists = processExists
    }

    public func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        let label = Self.label(for: arguments)
        try? launchctl.remove(label: label)
        try launchctl.submit(label: label, executable: executable, arguments: arguments)
        let pid = try launchctl.lookupPID(label: label)
        return DetachedProcess(pid: pid, label: label, launchctl: launchctl, processExists: processExists)
    }

    static let managedPortLabelPrefix = "com.cliproxymanager.port."

    static func label(forPort port: Int) -> String {
        "\(managedPortLabelPrefix)\(port)"
    }

    static func port(fromManagedLabel label: String) -> Int? {
        guard label.hasPrefix(managedPortLabelPrefix) else { return nil }
        return Int(label.dropFirst(managedPortLabelPrefix.count))
    }

    private static func label(for arguments: [String]) -> String {
        if let configPath = configPath(from: arguments), let port = port(fromConfigAtPath: configPath) {
            return label(forPort: port)
        }
        return "com.cliproxymanager.runtime.\(UUID().uuidString)"
    }

    private static func configPath(from arguments: [String]) -> String? {
        guard let configFlagIndex = arguments.firstIndex(of: "--config") else { return nil }
        let pathIndex = arguments.index(after: configFlagIndex)
        guard pathIndex < arguments.endIndex else { return nil }
        return arguments[pathIndex]
    }

    private static func port(fromConfigAtPath path: String) -> Int? {
        guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:") {
                return Int(trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

struct LaunchctlCommandResult: Equatable, Sendable {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
}

protocol LaunchctlCommandRunning: Sendable {
    func run(_ arguments: [String]) throws -> LaunchctlCommandResult
}

struct ProcessLaunchctlCommandRunner: LaunchctlCommandRunning {
    func run(_ arguments: [String]) throws -> LaunchctlCommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        return LaunchctlCommandResult(
            exitStatus: task.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

protocol LaunchctlManaging: Sendable {
    func remove(label: String) throws
    func submit(label: String, executable: String, arguments: [String]) throws
    func lookupPID(label: String) throws -> pid_t
    func labels(matchingPID pid: pid_t) throws -> [String]
    func runningLabels(prefix: String) throws -> [String]
}

struct DisabledLaunchctlManager: LaunchctlManaging {
    func remove(label _: String) throws {}
    func submit(label _: String, executable _: String, arguments _: [String]) throws {}
    func lookupPID(label _: String) throws -> pid_t { 0 }
    func labels(matchingPID _: pid_t) throws -> [String] { [] }
    func runningLabels(prefix _: String) throws -> [String] { [] }
}

extension LaunchctlManaging {
    func runningLabels(prefix: String) throws -> [String] { [] }
}

struct LaunchctlRunner: LaunchctlManaging {
    private let commandRunner: any LaunchctlCommandRunning
    private let sleep: @Sendable (TimeInterval) -> Void

    init(
        commandRunner: any LaunchctlCommandRunning = ProcessLaunchctlCommandRunner(),
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.commandRunner = commandRunner
        self.sleep = sleep
    }

    func remove(label: String) throws {
        let result = try commandRunner.run(["remove", label])
        try check(result, operation: "remove")
    }

    func submit(label: String, executable: String, arguments: [String]) throws {
        var args = ["submit", "-l", label, "--", executable]
        args.append(contentsOf: arguments)
        let result = try commandRunner.run(args)
        try check(result, operation: "submit")
    }

    func lookupPID(label: String) throws -> pid_t {
        var lastError = ""
        for _ in 0..<20 {
            let result: LaunchctlCommandResult
            do {
                result = try commandRunner.run(["list", label])
            } catch {
                try? remove(label: label)
                throw error
            }
            lastError = result.stderr
            if result.exitStatus == 0, let pid = Self.pid(fromLaunchctlListOutput: result.stdout) {
                return pid
            }
            sleep(0.05)
        }
        try? remove(label: label)
        let suffix = lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ": \(lastError.trimmingCharacters(in: .whitespacesAndNewlines))"
        throw NSError(domain: NSPOSIXErrorDomain, code: 0, userInfo: [
            NSLocalizedDescriptionKey: "launchctl spawned job did not report a PID for \(label)\(suffix)"
        ])
    }

    func labels(matchingPID pid: pid_t) throws -> [String] {
        let result = try commandRunner.run(["list"])
        try check(result, operation: "list")
        return Self.labels(fromLaunchctlListOutput: result.stdout, matchingPID: pid)
    }

    func runningLabels(prefix: String) throws -> [String] {
        let result = try commandRunner.run(["list"])
        try check(result, operation: "list")
        return Self.runningLabels(fromLaunchctlListOutput: result.stdout, prefix: prefix)
    }

    private func check(_ result: LaunchctlCommandResult, operation: String) throws {
        guard result.exitStatus == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = stderr.isEmpty ? "" : ": \(stderr)"
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.exitStatus), userInfo: [
                NSLocalizedDescriptionKey: "launchctl \(operation) failed with exit code \(result.exitStatus)\(suffix)"
            ])
        }
    }

    private static func pid(fromLaunchctlListOutput text: String) -> pid_t? {
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"PID\""),
                  let eq = trimmed.firstIndex(of: "="),
                  let semi = trimmed.lastIndex(of: ";") else { continue }
            let raw = trimmed[trimmed.index(after: eq)..<semi].trimmingCharacters(in: .whitespaces)
            if let pid = pid_t(raw), pid > 0 {
                return pid
            }
        }
        return nil
    }

    private static func labels(fromLaunchctlListOutput text: String, matchingPID pid: pid_t) -> [String] {
        text.split(whereSeparator: { $0 == "\n" }).compactMap { line in
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3, pid_t(columns[0]) == pid else { return nil }
            return String(columns[2])
        }
    }

    private static func runningLabels(fromLaunchctlListOutput text: String, prefix: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" }).compactMap { line in
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3,
                  let pid = pid_t(columns[0]),
                  pid > 0 else { return nil }
            let label = String(columns[2])
            return label.hasPrefix(prefix) ? label : nil
        }
    }
}

final class DetachedProcess: ManagedProxyProcess, @unchecked Sendable {
    private let pid: pid_t
    private let label: String?
    private let launchctl: any LaunchctlManaging
    private let processExists: @Sendable (pid_t) -> Bool
    private let sleep: @Sendable (TimeInterval) -> Void
    private var hasBeenWaitedFor = false
    private let lock = NSLock()

    init(
        pid: pid_t,
        label: String? = nil,
        launchctl: any LaunchctlManaging,
        processExists: @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.pid = pid
        self.label = label
        self.launchctl = launchctl
        self.processExists = processExists
        self.sleep = sleep
    }

    func terminate() {
        if let label {
            try? launchctl.remove(label: label)
        }
        if processExists(pid) {
            _ = kill(pid, SIGTERM)
        }
    }

    func waitUntilExit() {
        lock.lock()
        if hasBeenWaitedFor {
            lock.unlock()
            return
        }
        lock.unlock()

        while processExists(pid) {
            sleep(0.05)
        }
        lock.withLock { hasBeenWaitedFor = true }
    }
}

public enum ProxyRestartFailureStage: String, Equatable, Sendable {
    case configActivation = "activate the generated local-only configuration"
    case processLaunch = "launch CLIProxyAPI with the generated local-only configuration"
}

public enum RuntimeCompatibilityBlocker: Equatable, Sendable {
    case unsupportedOperatingSystem
    case unsupportedArchitecture
    case unsupportedArtifactTarget
    case unavailable

    public init(report: RuntimeCompatibilityReport) {
        for finding in report.findings {
            switch finding {
            case .unsupportedOperatingSystem:
                self = .unsupportedOperatingSystem
                return
            case .unsupportedArchitecture:
                self = .unsupportedArchitecture
                return
            case .unsupportedArtifactTarget:
                self = .unsupportedArtifactTarget
                return
            case .unsupportedLoginShell,
                 .unavailableClaudeCode,
                 .unverifiedClaudeCode,
                 .unverifiedClaudeCodeVersion:
                continue
            }
        }
        self = .unavailable
    }

    public var recoveryMessage: String {
        switch self {
        case .unsupportedOperatingSystem:
            "CLIProxyAPI requires macOS 15 or later. Update macOS, then retry."
        case .unsupportedArchitecture:
            "CLIProxyAPI requires an Apple silicon Mac. Use a supported Mac, then retry."
        case .unsupportedArtifactTarget:
            "The installed CLIProxyAPI binary is not supported. Restore the bundled proxy, then retry."
        case .unavailable:
            "CLIProxyAPI compatibility could not be verified. Restore the bundled proxy, then retry."
        }
    }
}

public enum ProxyServiceError: LocalizedError, Equatable {
    case invalidPort(Int)
    case missingBinary(String)
    case writeFailed(String)
    case launchFailed(String)
    case listenerInspectionFailed(port: Int, detail: String)
    case configurationChangeRequiresRestart
    case compatibilityBlocked(RuntimeCompatibilityBlocker)
    case restartFailed(stage: ProxyRestartFailureStage, rollbackSucceeded: Bool)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Port \(port) is outside the supported range. Choose a port between 1 and 65535."
        case .missingBinary:
            "CLIProxyAPI is unavailable. Reinstall the app or restore the bundled proxy, then retry."
        case .writeFailed:
            "The local-only proxy configuration could not be prepared. The existing server was left unchanged. Retry the operation."
        case .launchFailed:
            "CLIProxyAPI could not be started with the local-only configuration. Check the configured port and retry Start Server."
        case let .listenerInspectionFailed(port, detail):
            "The proxy listener on port \(port) could not be inspected, so its configuration was left unchanged. Retry the operation or check Diagnostics. Details: \(detail)"
        case .configurationChangeRequiresRestart:
            "The running proxy must be restarted before account login can update its local-only configuration. Restart Server, then retry login."
        case .compatibilityBlocked(let blocker):
            blocker.recoveryMessage
        case let .restartFailed(stage, rollbackSucceeded):
            if rollbackSucceeded {
                "Failed to \(stage.rawValue). The previous proxy configuration was restored and remains available. Retry Restart Server."
            } else {
                "Failed to \(stage.rawValue), and the previous server could not be restored. The proxy is stopped; retry Start Server after checking the configured port."
            }
        }
    }
}

extension ProxyServiceManager: ProxyServiceControlling {}

public struct ProxyServiceManager: ProxyRuntimePreparing, @unchecked Sendable {
    private let paths: ManagedPaths
    private let bundledBinaryURL: URL?
    private let bundledManifestURL: URL?
    private let binaryStore: CLIProxyAPIBinaryStore
    private let compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing
    private let launcher: any ProcessLaunching
    private let launchctl: any LaunchctlManaging
    private let fileManager: FileManager
    private let managementKeyProvider: @Sendable () -> String?
    private let usageEnabledProvider: @Sendable () -> Bool
    private let legacyClaudeAPIKeyProvider: (@Sendable () -> String?)?
    private let legacyCodexAPIKeyProvider: (@Sendable () -> String?)?
    private let apiKeyProvider: @Sendable (SecretReference) throws -> String?
    private let appConfigProvider: @Sendable () throws -> AppConfig
    private let rollbackReadinessProvider: (@Sendable (Int) -> Bool)?
    private let inspectLaunchctlJobs: Bool
    private let inspectSystemProcesses: Bool
    private let allowsSystemRuntimeMutation: Bool
    private let processState = LockedProcessState()
    private let lifecycleLock = NSLock()

    public init(
        paths: ManagedPaths,
        bundledBinaryURL: URL? = nil,
        bundledManifestURL: URL? = nil,
        launcher: any ProcessLaunching = ProcessLauncher(),
        fileManager: FileManager = .default,
        managementKeyProvider: (@Sendable () -> String?)? = nil,
        usageEnabledProvider: (@Sendable () -> Bool)? = nil,
        claudeAPIKeyProvider: (@Sendable () -> String?)? = nil,
        codexAPIKeyProvider: (@Sendable () -> String?)? = nil,
        apiKeyProvider: (@Sendable (SecretReference) throws -> String?)? = nil,
        appConfigProvider: (@Sendable () throws -> AppConfig)? = nil,
        rollbackReadinessProvider: (@Sendable (Int) -> Bool)? = nil,
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight()
    ) {
        let managesSystemRuntime = Self.shouldInspectSystemRuntime(using: launcher)
        self.init(
            paths: paths,
            bundledBinaryURL: bundledBinaryURL,
            bundledManifestURL: bundledManifestURL,
            launcher: launcher,
            launchctl: Self.defaultLaunchctlManager(using: launcher),
            fileManager: fileManager,
            managementKeyProvider: managementKeyProvider ?? { try? SubscriptionUsageManagementKeyFileStore(paths: paths).managementKey() },
            usageEnabledProvider: usageEnabledProvider ?? {
                (try? AppConfigStore(paths: paths).load().isUsageEnabled) ?? false
            },
            claudeAPIKeyProvider: claudeAPIKeyProvider,
            codexAPIKeyProvider: codexAPIKeyProvider,
            apiKeyProvider: apiKeyProvider,
            appConfigProvider: appConfigProvider ?? { try AppConfigStore(paths: paths).load() },
            rollbackReadinessProvider: rollbackReadinessProvider,
            compatibilityAuthorizer: compatibilityAuthorizer,
            inspectLaunchctlJobs: managesSystemRuntime,
            inspectSystemProcesses: managesSystemRuntime
        )
    }

    init(
        paths: ManagedPaths,
        bundledBinaryURL: URL? = nil,
        bundledManifestURL: URL? = nil,
        launcher: any ProcessLaunching = ProcessLauncher(),
        launchctl: any LaunchctlManaging,
        fileManager: FileManager = .default,
        managementKeyProvider: (@Sendable () -> String?)? = nil,
        usageEnabledProvider: (@Sendable () -> Bool)? = nil,
        claudeAPIKeyProvider: (@Sendable () -> String?)? = nil,
        codexAPIKeyProvider: (@Sendable () -> String?)? = nil,
        apiKeyProvider: (@Sendable (SecretReference) throws -> String?)? = nil,
        appConfigProvider: (@Sendable () throws -> AppConfig)? = nil,
        rollbackReadinessProvider: (@Sendable (Int) -> Bool)? = nil,
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight(),
        inspectLaunchctlJobs: Bool = true,
        inspectSystemProcesses: Bool? = nil
    ) {
        self.paths = paths
        self.bundledBinaryURL = bundledBinaryURL
        self.bundledManifestURL = bundledManifestURL
        self.binaryStore = CLIProxyAPIBinaryStore(paths: paths, fileManager: fileManager)
        self.compatibilityAuthorizer = compatibilityAuthorizer
        self.launcher = launcher
        self.launchctl = launchctl
        self.fileManager = fileManager
        self.managementKeyProvider = managementKeyProvider ?? { try? SubscriptionUsageManagementKeyFileStore(paths: paths).managementKey() }
        self.usageEnabledProvider = usageEnabledProvider ?? {
            (try? AppConfigStore(paths: paths).load().isUsageEnabled) ?? false
        }
        self.legacyClaudeAPIKeyProvider = claudeAPIKeyProvider
        self.legacyCodexAPIKeyProvider = codexAPIKeyProvider
        if let apiKeyProvider {
            self.apiKeyProvider = apiKeyProvider
        } else if claudeAPIKeyProvider != nil || codexAPIKeyProvider != nil {
            self.apiKeyProvider = { _ in nil }
        } else {
            let store = FileSecretStore(paths: paths)
            self.apiKeyProvider = { reference in
                do {
                    return try store.get(reference)
                } catch SecretStoreError.missingSecret {
                    return nil
                }
            }
        }
        self.appConfigProvider = appConfigProvider ?? { try AppConfigStore(paths: paths).load() }
        self.rollbackReadinessProvider = rollbackReadinessProvider
        self.inspectLaunchctlJobs = inspectLaunchctlJobs
        self.inspectSystemProcesses = inspectSystemProcesses ?? launcher.usesManagedLaunchdJobs
        self.allowsSystemRuntimeMutation = launcher.usesManagedLaunchdJobs
    }

    static func shouldInspectSystemRuntime(using launcher: any ProcessLaunching) -> Bool {
        launcher.usesManagedLaunchdJobs
    }

    static func defaultLaunchctlManager(using launcher: any ProcessLaunching) -> any LaunchctlManaging {
        shouldInspectSystemRuntime(using: launcher) ? LaunchctlRunner() : DisabledLaunchctlManager()
    }

    public func prepare(port: Int) throws {
        try lifecycleLock.withLock {
            try prepareLocked(port: port)
        }
    }

    public func start(port: Int) async throws {
        try lifecycleLock.withLock {
            try startLocked(port: port)
        }
    }

    public func stop() async throws {
        lifecycleLock.withLock {
            stopLocked()
        }
    }

    public func restart(port: Int) async throws {
        try lifecycleLock.withLock {
            _ = try reconcileConfigurationLocked(port: port, forceRestart: true)
        }
    }

    public func reconcileConfiguration(port: Int) async throws -> Bool {
        try lifecycleLock.withLock {
            try reconcileConfigurationLocked(port: port, forceRestart: false)
        }
    }

    private struct ProxyConfigSnapshot {
        let data: Data?
        let port: Int?
    }

    private struct StagedProxyConfig {
        let url: URL
        let data: Data
    }

    private func requireCompatibility(for action: CompatibilityAction) throws {
        let artifacts: CompatibilityArtifacts
        do {
            artifacts = try compatibilityArtifacts()
        } catch {
            throw ProxyServiceError.compatibilityBlocked(.unsupportedArtifactTarget)
        }
        do {
            try compatibilityAuthorizer.require(action, artifacts: artifacts)
        } catch {
            throw ProxyServiceError.compatibilityBlocked(
                RuntimeCompatibilityBlocker(report: compatibilityAuthorizer.staticReport(artifacts: artifacts))
            )
        }
    }

    private func compatibilityArtifacts() throws -> CompatibilityArtifacts {
        CompatibilityArtifacts(
            bundled: try bundledManifestURL.flatMap(compatibilityArtifact(at:)),
            active: try compatibilityArtifact(for: binaryStore.activeManifest()),
            pending: try compatibilityArtifact(for: binaryStore.pendingManifest())
        )
    }

    private func compatibilityArtifact(at manifestURL: URL) throws -> RuntimeCompatibilityArtifact? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: data)
        return try compatibilityArtifact(for: manifest)
    }

    private func compatibilityArtifact(for manifest: CLIProxyAPIBinaryManifest?) throws -> RuntimeCompatibilityArtifact? {
        guard let manifest else { return nil }
        guard let target = manifest.target else {
            guard manifest.upstreamAsset == "CLIProxyAPI_\(manifest.version)_darwin_aarch64.tar.gz" else {
                throw CLIProxyAPIBinaryStoreError.unsupportedArtifactTarget
            }
            return .legacy
        }
        return .explicit(target)
    }

    private func prepareLocked(port: Int) throws {
        try requireCompatibility(for: .prepareOAuthLogin)
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }
        let staged = try stageConfiguration(port: port)
        defer { try? fileManager.removeItem(at: staged.url) }
        try validateConfigTarget()
        let snapshot = currentConfigSnapshot()
        guard snapshot.data != staged.data else { return }
        let candidatePorts = [snapshot.port, port].compactMap { $0 }
        guard try managedListeningPorts(candidates: candidatePorts).isEmpty else {
            throw ProxyServiceError.configurationChangeRequiresRestart
        }
        try activate(staged)
    }

    private func startLocked(port: Int) throws {
        if processState.port != nil {
            _ = try reconcileConfigurationLocked(port: port, forceRestart: true)
            return
        }
        _ = try reconcileConfigurationLocked(port: port, forceRestart: false)
        if !(try managedListeningPorts(candidates: [port])).isEmpty {
            return
        }
        try launchLocked(port: port)
    }

    @discardableResult
    private func reconcileConfigurationLocked(port: Int, forceRestart: Bool) throws -> Bool {
        try requireCompatibility(for: forceRestart ? .restartProxy : .startProxy)
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }

        let staged = try stageConfiguration(port: port)
        defer { try? fileManager.removeItem(at: staged.url) }
        try validateConfigTarget()
        let snapshot = currentConfigSnapshot()
        let configChanged = snapshot.data != staged.data
        let candidatePorts = [snapshot.port, port].compactMap { $0 }
        let runningPorts = try managedListeningPorts(candidates: candidatePorts)
        let requiresRestartForAdoptedProcess = processState.port == nil && !runningPorts.isEmpty

        guard configChanged || forceRestart || requiresRestartForAdoptedProcess else { return false }
        guard !runningPorts.isEmpty else {
            if configChanged {
                try activate(staged)
            }
            if forceRestart {
                try launchLocked(port: port)
                return true
            }
            return false
        }

        let rollbackPort = runningPorts.first ?? snapshot.port ?? port
        stopManagedProcessesLocked(onPorts: runningPorts)
        do {
            if configChanged {
                try activate(staged)
            }
        } catch {
            let rollbackSucceeded = restore(snapshot: snapshot, relaunchPort: rollbackPort)
            throw ProxyServiceError.restartFailed(
                stage: .configActivation,
                rollbackSucceeded: rollbackSucceeded
            )
        }

        do {
            try launchLocked(port: port)
            return true
        } catch {
            let rollbackSucceeded = restore(snapshot: snapshot, relaunchPort: rollbackPort)
            throw ProxyServiceError.restartFailed(
                stage: .processLaunch,
                rollbackSucceeded: rollbackSucceeded
            )
        }
    }

    private func stageConfiguration(port: Int) throws -> StagedProxyConfig {
        do {
            try installBundledBinaryIfNeeded()
            try fileManager.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
            let url = paths.clipProxyConfigFile
                .deletingLastPathComponent()
                .appendingPathComponent(".config-\(UUID().uuidString).yaml")
            let data = Data(try config(for: port).utf8)
            guard fileManager.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ProxyServiceError.writeFailed("Failed to create proxy config")
            }
            return StagedProxyConfig(url: url, data: data)
        } catch let error as ProxyServiceError {
            throw error
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }
    }

    private func validateConfigTarget() throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: paths.clipProxyConfigFile.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            throw ProxyServiceError.writeFailed("Proxy config path is a directory")
        }
    }

    private func currentConfigSnapshot() -> ProxyConfigSnapshot {
        let data = try? Data(contentsOf: paths.clipProxyConfigFile)
        return ProxyConfigSnapshot(data: data, port: data.flatMap(portFromConfigData))
    }

    private func activate(_ staged: StagedProxyConfig) throws {
        do {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: paths.clipProxyConfigFile.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                throw ProxyServiceError.writeFailed("Proxy config path is a directory")
            }
            if exists {
                _ = try fileManager.replaceItemAt(paths.clipProxyConfigFile, withItemAt: staged.url)
            } else {
                try fileManager.moveItem(at: staged.url, to: paths.clipProxyConfigFile)
            }
        } catch let error as ProxyServiceError {
            throw error
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }
    }

    private func restore(snapshot: ProxyConfigSnapshot, relaunchPort: Int) -> Bool {
        guard let data = snapshot.data,
              Self.isExplicitLoopbackConfig(data) else {
            return false
        }
        do {
            let url = paths.clipProxyConfigFile
                .deletingLastPathComponent()
                .appendingPathComponent(".config-rollback-\(UUID().uuidString).yaml")
            guard fileManager.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else { return false }
            defer { try? fileManager.removeItem(at: url) }
            try activate(StagedProxyConfig(url: url, data: data))

            if !(try managedListeningPorts(candidates: [relaunchPort])).isEmpty {
                return true
            }
            try launchLocked(port: relaunchPort)
            guard waitForManagedListener(onPort: relaunchPort) else {
                stopManagedProcessesLocked(onPorts: [relaunchPort])
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func launchLocked(port: Int) throws {
        do {
            let process = try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
            processState.set(process, port: port)
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    private func stopLocked(waitUntilExit: Bool = false) {
        let candidatePorts = [processState.port, readPortFromConfig()].compactMap { $0 }
        let runningPorts = (try? managedListeningPorts(candidates: candidatePorts)) ?? candidatePorts
        terminateTrackedLocked(waitUntilExit: waitUntilExit)
        cleanupManagedProcessesLocked(onPorts: runningPorts)
    }

    private func stopManagedProcessesLocked(onPorts ports: [Int]) {
        terminateTrackedLocked(waitUntilExit: true)
        cleanupManagedProcessesLocked(onPorts: ports)
    }

    private func cleanupManagedProcessesLocked(onPorts ports: [Int]) {
        for port in ports {
            if allowsSystemRuntimeMutation && inspectLaunchctlJobs {
                removeManagedLaunchdJob(onPort: port)
            }
            if allowsSystemRuntimeMutation && inspectSystemProcesses {
                killOrphanCliproxyapi(onPort: port)
            }
        }
    }

    private func terminateTrackedLocked(waitUntilExit: Bool) {
        guard let tracked = processState.clear() else { return }
        tracked.process.terminate()
        if waitUntilExit {
            tracked.process.waitUntilExit()
        } else {
            Task.detached(priority: .utility) {
                tracked.process.waitUntilExit()
            }
        }
    }

    private func managedListeningPorts(candidates: [Int]) throws -> [Int] {
        var ports: Set<Int> = []
        if let trackedPort = processState.port {
            ports.insert(trackedPort)
        }
        if inspectLaunchctlJobs {
            for label in try launchctl.runningLabels(prefix: ProcessLauncher.managedPortLabelPrefix) {
                guard let port = ProcessLauncher.port(fromManagedLabel: label), isValidPort(port) else { continue }
                ports.insert(port)
            }
        }
        if inspectSystemProcesses {
            for port in candidates where !ports.contains(port) {
                if try managedListenerDetected(onPort: port) {
                    ports.insert(port)
                }
            }
        }
        return ports.sorted()
    }

    private func managedListenerDetected(onPort port: Int) throws -> Bool {
        switch probePIDListening(onPort: port) {
        case .notListening:
            return false
        case .unavailable:
            throw ProxyServiceError.listenerInspectionFailed(
                port: port,
                detail: "The listener probe did not return a usable result."
            )
        case .listening(let pid):
            guard let command = processCommand(pid: pid) else {
                throw ProxyServiceError.listenerInspectionFailed(
                    port: port,
                    detail: "The listening process command could not be read."
                )
            }
            return Self.isManagedCliproxyapiCommand(
                command,
                binaryPath: paths.clipProxyBinary.path,
                configPath: paths.clipProxyConfigFile.path
            )
        }
    }

    private func isCliproxyapiListening(onPort port: Int) -> Bool {
        (try? managedListenerDetected(onPort: port)) == true
    }

    private func readPortFromConfig() -> Int? {
        guard let data = try? Data(contentsOf: paths.clipProxyConfigFile) else { return nil }
        return portFromConfigData(data)
    }

    private func portFromConfigData(_ data: Data) -> Int? {
        guard let yaml = String(data: data, encoding: .utf8) else { return nil }
        for line in yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:") {
                let value = trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    static func isExplicitLoopbackConfig(_ data: Data) -> Bool {
        guard let yaml = String(data: data, encoding: .utf8) else { return false }
        let hosts = yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { rawLine -> String? in
            guard rawLine.first.map({ !$0.isWhitespace }) == true else { return nil }
            let line = String(rawLine)
            guard line.hasPrefix("host:") else { return nil }
            var value = line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return hosts == [ProxyNetworkPolicy.loopbackHost]
    }

    private func waitForManagedListener(onPort port: Int) -> Bool {
        if let rollbackReadinessProvider {
            return rollbackReadinessProvider(port)
        }
        guard inspectSystemProcesses else { return false }
        for _ in 0..<20 {
            if isCliproxyapiListening(onPort: port) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func killOrphanCliproxyapi(onPort port: Int) {
        guard let pid = pidListening(onPort: port) else { return }
        guard let command = processCommand(pid: pid),
              Self.isManagedCliproxyapiCommand(
                command,
                binaryPath: paths.clipProxyBinary.path,
                configPath: paths.clipProxyConfigFile.path
              ) else { return }
        guard pid != getpid() else { return }
        removeLaunchdJobs(forPID: pid)
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = kill(pid, SIGKILL)
    }

    private func removeManagedLaunchdJob(onPort port: Int) {
        try? launchctl.remove(label: ProcessLauncher.label(forPort: port))
    }

    private func removeLaunchdJobs(forPID pid: pid_t) {
        guard let labels = try? launchctl.labels(matchingPID: pid) else { return }
        for label in labels where label.hasPrefix("com.cliproxymanager.") {
            try? launchctl.remove(label: label)
        }
    }

    private enum ListenerPIDProbe {
        case listening(pid_t)
        case notListening
        case unavailable
    }

    private func probePIDListening(onPort port: Int) -> ListenerPIDProbe {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .unavailable
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return .unavailable }
        let first = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        if task.terminationStatus == 0,
           let pid = pid_t(first.trimmingCharacters(in: .whitespaces)),
           pid > 0 {
            return .listening(pid)
        }
        if task.terminationStatus == 1, first.isEmpty {
            return .notListening
        }
        return .unavailable
    }

    private func pidListening(onPort port: Int) -> pid_t? {
        guard case .listening(let pid) = probePIDListening(onPort: port) else { return nil }
        return pid
    }

    private func processCommand(pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isManagedCliproxyapiCommand(_ command: String, binaryPath: String, configPath: String) -> Bool {
        let arguments = command.split(separator: " ").map(String.init)
        return arguments.contains(binaryPath)
            && arguments.contains("--config")
            && arguments.contains(configPath)
    }

    private func installBundledBinaryIfNeeded() throws {
        do {
            try binaryStore.prepareActiveBinary(
                bundledBinaryURL: bundledBinaryURL,
                bundledManifestURL: bundledManifestURL
            )
        } catch CLIProxyAPIBinaryStoreError.missingBundledBinary {
            if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                return
            }
            throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
        } catch {
            throw error
        }
    }

    private struct ResolvedAPIKeyProfile {
        let profile: AppConfig.APIKeyProfile
        let key: String
    }

    private struct LegacyAPIKeys {
        let claude: String?
        let codex: String?
    }

    private func resolvedLegacyAPIKeys() -> LegacyAPIKeys {
        LegacyAPIKeys(
            claude: nonEmpty(legacyClaudeAPIKeyProvider?()),
            codex: nonEmpty(legacyCodexAPIKeyProvider?())
        )
    }

    private func appendLegacyCompatibilityProfilesIfNeeded(
        to config: inout AppConfig,
        legacyAPIKeys: LegacyAPIKeys
    ) {
        if !config.apiKeyProfiles.contains(where: { $0.id == "claude-api" }),
           legacyAPIKeys.claude != nil {
            config.apiKeyProfiles.append(.legacy(provider: .claude))
        }
        if !config.apiKeyProfiles.contains(where: { $0.id == "codex-api" }),
           legacyAPIKeys.codex != nil {
            config.apiKeyProfiles.append(.legacy(provider: .codex))
        }
    }

    private func resolvedAPIKey(
        for profile: AppConfig.APIKeyProfile,
        legacyAPIKeys: LegacyAPIKeys
    ) throws -> String? {
        if profile.secretReference == .claudeAPIKey,
           legacyClaudeAPIKeyProvider != nil {
            return legacyAPIKeys.claude
        }
        if profile.secretReference == .codexAPIKey,
           legacyCodexAPIKeyProvider != nil {
            return legacyAPIKeys.codex
        }
        return nonEmpty(try apiKeyProvider(profile.secretReference))
    }

    private func config(for port: Int) throws -> String {
        var appConfig = try appConfigProvider()
        let usageEnabled = usageEnabledProvider()
        let legacyAPIKeys = resolvedLegacyAPIKeys()
        appendLegacyCompatibilityProfilesIfNeeded(to: &appConfig, legacyAPIKeys: legacyAPIKeys)
        var resolvedAPIKeyProfiles: [ResolvedAPIKeyProfile] = []
        for profile in appConfig.apiKeyProfiles {
            do {
                guard let key = try resolvedAPIKey(for: profile, legacyAPIKeys: legacyAPIKeys) else { continue }
                resolvedAPIKeyProfiles.append(.init(profile: profile, key: key))
            } catch is SecretStoreError {
                continue
            }
        }
        let hasManagedAPIKey = !resolvedAPIKeyProfiles.isEmpty
        let fastConfiguration = try CodexFastConfiguration(
            config: appConfig,
            includedAPIKeyProfileIDs: Set(resolvedAPIKeyProfiles.map(\.profile.id))
        )

        let managementConfiguration: String
        if usageEnabled,
           let key = managementKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            managementConfiguration = """
            remote-management:
              secret-key: \(yamlDoubleQuoted(key))
            """
        } else {
            managementConfiguration = ""
        }

        let usageQueueConfiguration = usageEnabled && hasManagedAPIKey
            ? """
              usage-statistics-enabled: true
              redis-usage-queue-retention-seconds: 3600
              """
            : ""

        let managementAndUsageQueueConfiguration = [
            managementConfiguration,
            usageQueueConfiguration
        ].filter { !$0.isEmpty }.joined(separator: "\n")

        let claudeProfiles = resolvedAPIKeyProfiles.filter { $0.profile.provider == .claude }
        let claudeAPIConfiguration: String
        if claudeProfiles.isEmpty {
            claudeAPIConfiguration = ""
        } else {
            var lines = ["claude-api-key:"]
            for resolved in claudeProfiles {
                lines.append("  - api-key: \(yamlDoubleQuoted(resolved.key))")
                lines.append("    base-url: \(yamlDoubleQuoted("https://api.anthropic.com"))")
                lines.append("    prefix: \(yamlDoubleQuoted(resolved.profile.modelPrefix))")
            }
            claudeAPIConfiguration = lines.joined(separator: "\n")
        }

        let codexProfiles = resolvedAPIKeyProfiles.filter { $0.profile.provider == .codex }
        let codexAPIConfiguration: String
        if codexProfiles.isEmpty {
            codexAPIConfiguration = ""
        } else {
            var lines = ["codex-api-key:"]
            for resolved in codexProfiles {
                lines.append("  - api-key: \(yamlDoubleQuoted(resolved.key))")
                lines.append("    base-url: \(yamlDoubleQuoted("https://api.openai.com/v1"))")
                lines.append("    prefix: \(yamlDoubleQuoted(resolved.profile.modelPrefix))")
                let models = fastConfiguration.apiKeyCanonicalModelsByProfileID[resolved.profile.id] ?? []
                if !models.isEmpty {
                    lines.append("    models:")
                    lines.append(contentsOf: codexAPIModelsConfiguration(models: models))
                }
            }
            codexAPIConfiguration = lines.joined(separator: "\n")
        }

        let oauthFastConfiguration = oauthFastAliasConfiguration(
            models: fastConfiguration.oauthCanonicalModels
        )
        let payloadConfiguration = fastPayloadConfiguration(
            aliases: fastConfiguration.allAliases
        )
        let baseConfiguration = """
        host: \(yamlDoubleQuoted(ProxyNetworkPolicy.loopbackHost))
        port: \(port)
        auth-dir: \(yamlDoubleQuoted(paths.authDirectory.path))
        logging-to-file: true
        debug: \(appConfig.runtimeLogConfiguration.proxyDebugEnabled)
        api-keys:
          - sk-dummy
        """

        guard !fastConfiguration.allAliases.isEmpty else {
            guard !managementAndUsageQueueConfiguration.isEmpty || !claudeAPIConfiguration.isEmpty || !codexAPIConfiguration.isEmpty else {
                return baseConfiguration + "\n\n"
            }
            return """
            \(baseConfiguration)
            \(managementAndUsageQueueConfiguration)
            \(claudeAPIConfiguration)
            \(codexAPIConfiguration)
            """
        }

        var sections = [baseConfiguration]
        sections.append(contentsOf: [
            managementConfiguration,
            usageQueueConfiguration,
            claudeAPIConfiguration,
            codexAPIConfiguration,
            oauthFastConfiguration,
            payloadConfiguration
        ].filter { !$0.isEmpty })
        return sections.joined(separator: "\n") + "\n\n"
    }

    private func oauthFastAliasConfiguration(models: [String]) -> String {
        guard !models.isEmpty else { return "" }
        var lines = ["oauth-model-alias:", "  codex:"]
        for model in models {
            lines.append("    - name: \(yamlDoubleQuoted(model))")
            lines.append("      alias: \(yamlDoubleQuoted(CodexFastMode.alias(for: model)))")
            lines.append("      fork: true")
        }
        return lines.joined(separator: "\n")
    }

    private func codexAPIModelsConfiguration(models: [String]) -> [String] {
        var lines: [String] = []
        for model in models {
            lines.append("      - name: \(yamlDoubleQuoted(model))")
            lines.append("        alias: \(yamlDoubleQuoted(CodexFastMode.alias(for: model)))")
        }
        return lines
    }

    private func fastPayloadConfiguration(aliases: [String]) -> String {
        guard !aliases.isEmpty else { return "" }
        var lines = ["payload:", "  override:", "    - models:"]
        for alias in aliases {
            lines.append("        - name: \(yamlDoubleQuoted(alias))")
            lines.append("          protocol: \(yamlDoubleQuoted("codex"))")
        }
        lines.append("      params:")
        lines.append("        service_tier: priority")
        return lines.joined(separator: "\n")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func yamlDoubleQuoted(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\t":
                escaped += "\\t"
            case "\r":
                escaped += "\\r"
            case "\u{08}":
                escaped += "\\b"
            case "\u{0C}":
                escaped += "\\f"
            case let scalar where scalar.value < 0x20:
                escaped += String(format: "\\x%02X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

private final class LockedProcessState: @unchecked Sendable {
    struct TrackedProcess {
        let process: any ManagedProxyProcess
        let port: Int
    }

    private let lock = NSLock()
    private var trackedProcess: TrackedProcess?

    var port: Int? {
        lock.withLock { trackedProcess?.port }
    }

    func set(_ process: any ManagedProxyProcess, port: Int) {
        lock.withLock {
            trackedProcess = TrackedProcess(process: process, port: port)
        }
    }

    func clear() -> TrackedProcess? {
        lock.withLock {
            let trackedProcess = self.trackedProcess
            self.trackedProcess = nil
            return trackedProcess
        }
    }
}

private func isValidPort(_ port: Int) -> Bool {
    (1...65_535).contains(port)
}
