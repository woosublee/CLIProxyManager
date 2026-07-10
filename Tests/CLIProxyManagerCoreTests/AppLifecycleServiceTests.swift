import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppLifecycleServiceTests: XCTestCase {
    func testStartUsesOpenWithTheInstalledBundlePath() async throws {
        let runner = ProcessRunnerDouble(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let inspector = AppProcessInspectorDouble(runningValues: [true])
        let service = makeService(runner: runner, inspector: inspector)

        let status = try await service.start()

        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/bin/open"])
        XCTAssertEqual(runner.calls.map(\.arguments), [["-a", "/Applications/CLIProxyManager.app"]])
        XCTAssertTrue(status.running)
    }

    func testStopRequestsNormalQuitAndNeverCallsProxyControl() async throws {
        let runner = ProcessRunnerDouble(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let inspector = AppProcessInspectorDouble(runningValues: [true, false])
        let service = makeService(runner: runner, inspector: inspector)

        _ = try await service.stop()

        XCTAssertEqual(runner.calls.first?.executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.calls.first?.arguments, ["-e", "tell application id \"com.woosublee.CLIProxyManager\" to quit"])
    }

    func testStartReportsPrerequisiteWhenAppIsNotInstalled() async {
        let service = makeService(locator: MissingBundleLocator())

        await XCTAssertThrowsErrorAsync(try await service.start()) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("CLIProxyManager.app is not installed at /Applications/CLIProxyManager.app.")
            )
        }
    }

    func testStatusReturnsFalseInstalledWhenLocatorThrowsPrerequisite() async throws {
        let service = makeService(locator: MissingBundleLocator())

        let status = try await service.status()

        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.running)
    }

    func testStopReturnsEarlyWhenAlreadyStopped() async throws {
        let runner = ProcessRunnerDouble(results: [])
        let inspector = AppProcessInspectorDouble(runningValues: [false])
        let service = makeService(runner: runner, inspector: inspector)

        let status = try await service.stop()

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(status.running)
    }

    func testStartThrowsOperationWhenOpenFails() async {
        let runner = ProcessRunnerDouble(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "Unable to find application")])
        let inspector = AppProcessInspectorDouble(runningValues: [])
        let service = makeService(runner: runner, inspector: inspector)

        await XCTAssertThrowsErrorAsync(try await service.start()) { error in
            if case CLIProxyManagerCommandError.operation(let msg) = error {
                XCTAssertTrue(msg.contains("Unable to find application"))
            } else {
                XCTFail("Expected operation error, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeService(
        runner: any ProcessRunning = ProcessRunnerDouble(results: []),
        inspector: any AppProcessInspecting = AppProcessInspectorDouble(runningValues: []),
        locator: any AppBundleLocating = FixedBundleLocator()
    ) -> AppLifecycleService {
        AppLifecycleService(
            bundleLocator: locator,
            runner: runner,
            inspector: inspector,
            pollIntervalNanoseconds: 1,
            maxPollIterations: 30
        )
    }
}

// MARK: - Test doubles

private struct ProcessCall {
    let executable: String
    let arguments: [String]
}

private final class ProcessRunnerDouble: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private(set) var calls: [ProcessCall] = []

    init(results: [ProcessResult]) { self.results = results }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock {
            calls.append(ProcessCall(executable: executable, arguments: arguments))
            return results.isEmpty ? ProcessResult(exitCode: 0, stdout: "", stderr: "") : results.removeFirst()
        }
    }
}

private final class AppProcessInspectorDouble: AppProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(runningValues: [Bool]) { self.values = runningValues }

    func isRunning(bundleIdentifier: String) async -> Bool {
        lock.withLock {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}

private struct FixedBundleLocator: AppBundleLocating {
    func locateInstalledApp() throws -> ManagedAppBundle {
        ManagedAppBundle(
            appURL: URL(fileURLWithPath: "/Applications/CLIProxyManager.app"),
            proxyBinaryURL: URL(fileURLWithPath: "/Applications/CLIProxyManager.app/Contents/Resources/cliproxyapi/cliproxyapi"),
            proxyManifestURL: URL(fileURLWithPath: "/Applications/CLIProxyManager.app/Contents/Resources/cliproxyapi/cliproxyapi.manifest.json"),
            version: "0.1.12",
            build: "15"
        )
    }
}

private struct MissingBundleLocator: AppBundleLocating {
    func locateInstalledApp() throws -> ManagedAppBundle {
        throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is not installed at /Applications/CLIProxyManager.app.")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ assertion: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        assertion(error)
    }
}
