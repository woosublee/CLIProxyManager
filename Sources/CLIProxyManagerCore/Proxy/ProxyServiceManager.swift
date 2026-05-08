import Foundation

public protocol ProcessLaunching: Sendable {
    func launch(_ executable: String, _ arguments: [String]) throws
}

public struct ProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

public enum ProxyServiceError: Error, Equatable {
    case invalidPort(Int)
    case missingBinary(String)
    case writeFailed(String)
    case launchFailed(String)
}

public struct ProxyServiceManager: @unchecked Sendable {
    private let paths: ManagedPaths
    private let launcher: any ProcessLaunching
    private let fileManager: FileManager

    public init(
        paths: ManagedPaths,
        launcher: any ProcessLaunching = ProcessLauncher(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.launcher = launcher
        self.fileManager = fileManager
    }

    public func start(port: Int) async throws {
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }

        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path) else {
            throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
        }

        do {
            try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
            try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }

        do {
            try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    private func config(for port: Int) -> String {
        """
        port: \(port)
        auth-dir: "~/.cli-proxy-api"
        logging-to-file: true
        debug: false
        api-keys:
          - sk-dummy
        """
    }
}

private func isValidPort(_ port: Int) -> Bool {
    (1...65_535).contains(port)
}
