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
    private let bundledBinaryURL: URL?
    private let launcher: any ProcessLaunching
    private let fileManager: FileManager

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

    public func start(port: Int) async throws {
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }

        do {
            try installBundledBinaryIfNeeded()
            try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        } catch let error as ProxyServiceError {
            throw error
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }

        do {
            try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    private func installBundledBinaryIfNeeded() throws {
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path) == false else { return }

        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
        }

        try fileManager.copyItem(at: bundledBinaryURL, to: paths.clipProxyBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
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
