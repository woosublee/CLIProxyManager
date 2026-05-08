import Foundation

public struct ProxyServiceManager: @unchecked Sendable {
    private let paths: ManagedPaths
    private let runner: any ProcessRunning
    private let fileManager: FileManager

    public init(
        paths: ManagedPaths,
        runner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    @discardableResult
    public func start(port: Int) async -> ProcessResult {
        do {
            try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
            try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        } catch {
            return ProcessResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        return await runner.run(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
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
