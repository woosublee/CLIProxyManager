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
    public init() {}

    public func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        // Spawn detached from this session so the child's networking isn't subject to
        // any session-scoped policies inherited from the SwiftUI app process.
        return try DetachedProcess.spawn(executable: executable, arguments: arguments)
    }
}

private final class DetachedProcess: ManagedProxyProcess, @unchecked Sendable {
    private let pid: pid_t
    private let label: String?
    private var hasBeenWaitedFor = false
    private let lock = NSLock()

    private init(pid: pid_t, label: String? = nil) {
        self.pid = pid
        self.label = label
    }

    static func spawn(executable: String, arguments: [String]) throws -> DetachedProcess {
        // Spawn through `launchctl submit` so the child is reparented to launchd and
        // doesn't inherit the SwiftUI app's networking session. This sidesteps a macOS
        // restriction where the parent app cannot make TCP loopback connections to a
        // direct child it spawned via posix_spawn.
        let label = "com.cliproxymanager.runtime.\(UUID().uuidString)"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        var args = ["submit", "-l", label, "--"]
        args.append(executable)
        args.append(contentsOf: arguments)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw NSError(domain: NSPOSIXErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "launchctl submit failed: \(error.localizedDescription)"
            ])
        }

        // Find the launchd-managed PID by querying `launchctl list <label>`.
        let pid = try Self.lookupPID(label: label)
        return DetachedProcess(pid: pid, label: label)
    }

    private static func lookupPID(label: String, attempts: Int = 20) throws -> pid_t {
        for _ in 0..<attempts {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["list", label]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(whereSeparator: { $0 == "\n" }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\"PID\"") {
                    if let eq = trimmed.firstIndex(of: "="),
                       let semi = trimmed.lastIndex(of: ";") {
                        let raw = trimmed[trimmed.index(after: eq)..<semi].trimmingCharacters(in: .whitespaces)
                        if let pid = pid_t(raw), pid > 0 {
                            return pid
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: 0, userInfo: [
            NSLocalizedDescriptionKey: "launchctl spawned job did not report a PID for \(label)"
        ])
    }

    func terminate() {
        if let label {
            // Tell launchd to tear down the job (also kills the process).
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["remove", label]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
        if !isExited() {
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

        var status: Int32 = 0
        // Polling waitpid since the child is in a different session.
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                lock.withLock { hasBeenWaitedFor = true }
                return
            }
            if result == -1 {
                // ECHILD or other; treat as exited.
                lock.withLock { hasBeenWaitedFor = true }
                return
            }
            // Still running.
            if isExited() {
                lock.withLock { hasBeenWaitedFor = true }
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func isExited() -> Bool {
        // kill(pid, 0) returns 0 if process exists, -1 (with errno) otherwise.
        return kill(pid, 0) != 0
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
        return command.contains("cliproxyapi")
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
        guard let command = processCommand(pid: pid), command.contains("cliproxyapi") else { return }
        // Avoid killing ourselves (paranoia — we're the SwiftUI app, not cliproxyapi, but be safe).
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
