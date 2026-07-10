import Foundation

public struct PgrepAppProcessInspector: AppProcessInspecting, Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func isRunning(bundleIdentifier: String) async -> Bool {
        let result = await runner.run("/usr/bin/pgrep", ["-x", "CLIProxyManager"])
        return result.exitCode == 0
    }
}

public struct AppLifecycleService: AppLifecycleControlling, Sendable {
    private let bundleLocator: any AppBundleLocating
    private let runner: any ProcessRunning
    private let inspector: any AppProcessInspecting
    private let pollIntervalNanoseconds: UInt64
    private let maxPollIterations: Int

    public init(
        bundleLocator: any AppBundleLocating = AppBundleLocator(),
        runner: any ProcessRunning = ProcessRunner(),
        inspector: any AppProcessInspecting = PgrepAppProcessInspector()
    ) {
        self.bundleLocator = bundleLocator
        self.runner = runner
        self.inspector = inspector
        self.pollIntervalNanoseconds = 100_000_000
        self.maxPollIterations = 30
    }

    init(
        bundleLocator: any AppBundleLocating,
        runner: any ProcessRunning,
        inspector: any AppProcessInspecting,
        pollIntervalNanoseconds: UInt64,
        maxPollIterations: Int
    ) {
        self.bundleLocator = bundleLocator
        self.runner = runner
        self.inspector = inspector
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollIterations = maxPollIterations
    }

    public func status() async throws -> AppLifecycleStatus {
        do {
            let bundle = try bundleLocator.locateInstalledApp()
            let running = await inspector.isRunning(bundleIdentifier: AppBundleLocator.expectedBundleIdentifier)
            return AppLifecycleStatus(
                installed: true,
                running: running,
                path: bundle.appURL.path,
                version: bundle.version,
                build: bundle.build
            )
        } catch let error as CLIProxyManagerCommandError {
            if case .prerequisite = error {
                return AppLifecycleStatus(installed: false, running: false, path: nil, version: nil, build: nil)
            }
            throw error
        }
    }

    public func start() async throws -> AppLifecycleStatus {
        let bundle = try bundleLocator.locateInstalledApp()
        let openResult = await runner.run("/usr/bin/open", ["-a", bundle.appURL.path])
        guard openResult.exitCode == 0 else {
            let message = openResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIProxyManagerCommandError.operation(message.isEmpty ? "Failed to open CLIProxyManager.app." : message)
        }
        for _ in 0..<maxPollIterations {
            let running = await inspector.isRunning(bundleIdentifier: AppBundleLocator.expectedBundleIdentifier)
            if running {
                return AppLifecycleStatus(
                    installed: true,
                    running: true,
                    path: bundle.appURL.path,
                    version: bundle.version,
                    build: bundle.build
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw CLIProxyManagerCommandError.operation("Aqua GUI session is unavailable; the app could not start.")
    }

    public func stop() async throws -> AppLifecycleStatus {
        let alreadyStopped = !(await inspector.isRunning(bundleIdentifier: AppBundleLocator.expectedBundleIdentifier))
        if alreadyStopped {
            return AppLifecycleStatus(installed: true, running: false, path: nil, version: nil, build: nil)
        }
        _ = await runner.run(
            "/usr/bin/osascript",
            ["-e", "tell application id \"\(AppBundleLocator.expectedBundleIdentifier)\" to quit"]
        )
        for _ in 0..<maxPollIterations {
            let stillRunning = await inspector.isRunning(bundleIdentifier: AppBundleLocator.expectedBundleIdentifier)
            if !stillRunning {
                return AppLifecycleStatus(installed: true, running: false, path: nil, version: nil, build: nil)
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        throw CLIProxyManagerCommandError.operation("CLIProxyManager did not exit after a normal quit request.")
    }

    public func restart() async throws -> AppLifecycleStatus {
        _ = try await stop()
        return try await start()
    }
}
