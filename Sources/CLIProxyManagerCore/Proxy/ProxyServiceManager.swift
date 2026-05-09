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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
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

        stopLocked(waitUntilExit: true)

        do {
            let process = try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
            processState.set(process)
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    private func stopLocked(waitUntilExit: Bool = false) {
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
