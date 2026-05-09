import Foundation

public protocol ManagedProxyProcess: Sendable {
    func terminate()
    func waitUntilExit()
}

extension Process: ManagedProxyProcess {}

public protocol ProcessLaunching: Sendable {
    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess
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

    private static func label(for arguments: [String]) -> String {
        if let configPath = configPath(from: arguments), let port = port(fromConfigAtPath: configPath) {
            return "com.cliproxymanager.port.\(port)"
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
            let result = try commandRunner.run(["list", label])
            lastError = result.stderr
            if result.exitStatus == 0, let pid = Self.pid(fromLaunchctlListOutput: result.stdout) {
                return pid
            }
            sleep(0.05)
        }
        let suffix = lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ": \(lastError.trimmingCharacters(in: .whitespacesAndNewlines))"
        throw NSError(domain: NSPOSIXErrorDomain, code: 0, userInfo: [
            NSLocalizedDescriptionKey: "launchctl spawned job did not report a PID for \(label)\(suffix)"
        ])
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

public enum ProxyServiceError: Error, Equatable {
    case invalidPort(Int)
    case missingBinary(String)
    case writeFailed(String)
    case launchFailed(String)
}

public struct ProxyServiceManager: ProxyRuntimePreparing, @unchecked Sendable {
    private let paths: ManagedPaths
    private let bundledBinaryURL: URL?
    private let launcher: any ProcessLaunching
    private let fileManager: FileManager
    private let processState = LockedProcessState()
    private let lifecycleLock = NSLock()

    public init(
        paths: ManagedPaths,
        bundledBinaryURL: URL? = nil,
        launcher: any ProcessLaunching = ProcessLauncher(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.bundledBinaryURL = bundledBinaryURL
        self.launcher = launcher
        self.fileManager = fileManager
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
            stopLocked(waitUntilExit: true)
            try startLocked(port: port)
        }
    }

    private func prepareLocked(port: Int) throws {
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }

        do {
            try installBundledBinaryIfNeeded()
            try fileManager.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
            try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        } catch let error as ProxyServiceError {
            throw error
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }
    }

    private func startLocked(port: Int) throws {
        try prepareLocked(port: port)

        terminateTrackedLocked(waitUntilExit: true)

        // If a cliproxyapi instance is already serving on the configured port (e.g. from a
        // previous app run), adopt it instead of fighting for the port.
        if isCliproxyapiListening(onPort: port) {
            return
        }

        do {
            let process = try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
            processState.set(process)
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    private func stopLocked(waitUntilExit: Bool = false) {
        terminateTrackedLocked(waitUntilExit: waitUntilExit)

        // Sweep up any cliproxyapi (tracked or adopted) still listening on the configured port.
        if let port = readPortFromConfig() {
            killOrphanCliproxyapi(onPort: port)
        }
    }

    private func terminateTrackedLocked(waitUntilExit: Bool) {
        guard let process = processState.clear() else { return }
        process.terminate()
        if waitUntilExit {
            process.waitUntilExit()
        } else {
            Task.detached(priority: .utility) {
                process.waitUntilExit()
            }
        }
    }

    private func isCliproxyapiListening(onPort port: Int) -> Bool {
        guard let pid = pidListening(onPort: port),
              let command = processCommand(pid: pid) else { return false }
        return Self.isManagedCliproxyapiCommand(
            command,
            binaryPath: paths.clipProxyBinary.path,
            configPath: paths.clipProxyConfigFile.path
        )
    }

    private func readPortFromConfig() -> Int? {
        guard let yaml = try? String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8) else { return nil }
        for line in yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:") {
                let value = trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
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
        _ = kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = kill(pid, SIGKILL)
    }

    private func pidListening(onPort port: Int) -> pid_t? {
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
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let first = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        return pid_t(first.trimmingCharacters(in: .whitespaces))
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
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)

        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                return
            }
            throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
        }

        if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
            let installedData = try Data(contentsOf: paths.clipProxyBinary)
            let bundledData = try Data(contentsOf: bundledBinaryURL)
            if installedData == bundledData {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
                return
            }
            try fileManager.removeItem(at: paths.clipProxyBinary)
        }

        try fileManager.copyItem(at: bundledBinaryURL, to: paths.clipProxyBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
    }

    private func config(for port: Int) -> String {
        """
        port: \(port)
        auth-dir: \(yamlDoubleQuoted(paths.authDirectory.path))
        logging-to-file: true
        debug: false
        api-keys:
          - sk-dummy
        """
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
    private let lock = NSLock()
    private var process: (any ManagedProxyProcess)?

    func set(_ process: any ManagedProxyProcess) {
        lock.withLock { self.process = process }
    }

    func clear() -> (any ManagedProxyProcess)? {
        lock.withLock {
            let process = self.process
            self.process = nil
            return process
        }
    }
}

private func isValidPort(_ port: Int) -> Bool {
    (1...65_535).contains(port)
}
