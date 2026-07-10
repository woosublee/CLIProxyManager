import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyManagerUpdateCommandTests: XCTestCase {
    func testCheckProxyDispatchesWithoutConfirmation() async throws {
        let services = UpdateServicesDouble()
        let command = makeCommand(services: services, isInteractive: true)

        try await command.run(arguments: ["update", "check", "proxy"])

        XCTAssertTrue(services.calls.contains(.proxyCheck))
    }

    func testApplyProxyRequiresInteractiveConfirmation() async throws {
        let services = UpdateServicesDouble(confirms: false)
        let interactiveOutput = InteractiveOutputDouble(confirms: false)
        let command = makeCommand(output: interactiveOutput, services: services, isInteractive: true)

        try await command.run(arguments: ["update", "apply", "proxy"])

        XCTAssertTrue(services.calls.isEmpty)
        XCTAssertEqual(interactiveOutput.confirmCalls, ["Apply staged CLIProxyAPI update?"])
    }

    func testApplyProxyYesSkipsConfirmation() async throws {
        let services = UpdateServicesDouble()
        let command = makeCommand(services: services, isInteractive: false)

        try await command.run(arguments: ["update", "apply", "proxy", "--yes"])

        XCTAssertEqual(services.calls, [.proxyApply])
    }

    func testUpdateWithoutTargetChecksAll() async throws {
        let services = UpdateServicesDouble()
        let command = makeCommand(services: services)

        try await command.run(arguments: ["update", "check"])

        XCTAssertTrue(services.calls.contains(.appCheck))
        XCTAssertTrue(services.calls.contains(.proxyCheck))
    }

    func testUpdateUnknownVerbThrowsUsage() async {
        let command = makeCommand(services: UpdateServicesDouble())

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["update", "unknown", "proxy"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    func testStageProxyDispatchesAndReportsStaged() async throws {
        let services = UpdateServicesDouble(proxyStageResult: ProxyUpdateStageResult(version: "7.2.50", staged: true))
        let output = OutputDouble(isInteractive: false)
        let command = makeCommand(output: output, services: services, isInteractive: false)

        try await command.run(arguments: ["update", "stage", "proxy"])

        XCTAssertEqual(services.calls, [.proxyStage])
        XCTAssertTrue(output.stdout.joined().contains("7.2.50 is staged"))
    }

    func testCheckReportsUpToDate() async throws {
        let services = UpdateServicesDouble(proxyCheckResult: .upToDate(current: "7.2.50"))
        let output = OutputDouble(isInteractive: false)
        let command = makeCommand(output: output, services: services, isInteractive: false)

        try await command.run(arguments: ["update", "check", "proxy"])

        XCTAssertTrue(output.stdout.joined().contains("up to date"))
    }

    func testApplyNonInteractiveWithoutYesThrowsUsage() async {
        let services = UpdateServicesDouble()
        let command = makeCommand(services: services, isInteractive: false)

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["update", "apply", "proxy"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    // MARK: - Helpers

    private func makeCommand(
        output: any CLICommandOutputWriting = OutputDouble(isInteractive: false),
        services: UpdateServicesDouble,
        isInteractive: Bool = false,
        uid: uid_t = 501
    ) -> CLIProxyManagerCommand {
        CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            output: output,
            proxyRuntime: NoOpRuntimeDouble(),
            appLifecycle: NoOpLifecycleDouble(),
            logService: NoOpLogDouble(),
            statusReporter: NoOpStatusDouble(),
            proxyUpdater: services,
            appUpdater: services,
            currentUID: { uid }
        )
    }
}

// MARK: - Test doubles

private final class UpdateServicesDouble: ProxyUpdating, AppUpdating, @unchecked Sendable {
    enum Call: Equatable { case proxyCheck, proxyStage, proxyApply, appCheck, appStage, appApply }

    private(set) var calls: [Call] = []
    let confirms: Bool
    private let proxyCheckResult: ProxyUpdateCheckResult
    private let proxyStageResult: ProxyUpdateStageResult
    private let proxyApplyResult: ProxyUpdateApplyResult
    private let appCheckResult: AppUpdateCheckResult
    private let appStageResult: AppUpdateStageResult
    private let appApplyResult: AppUpdateApplyResult

    init(
        confirms: Bool = true,
        proxyCheckResult: ProxyUpdateCheckResult = .upToDate(current: "7.2.50"),
        proxyStageResult: ProxyUpdateStageResult = ProxyUpdateStageResult(version: "7.2.50", staged: false),
        proxyApplyResult: ProxyUpdateApplyResult = ProxyUpdateApplyResult(version: "7.2.50", restartedProxy: false, proxyReady: false),
        appCheckResult: AppUpdateCheckResult = .upToDate(current: "0.1.12"),
        appStageResult: AppUpdateStageResult = AppUpdateStageResult(version: "0.1.12", staged: false),
        appApplyResult: AppUpdateApplyResult = AppUpdateApplyResult(version: "0.1.13", appRestarted: false, appRestartWarning: nil)
    ) {
        self.confirms = confirms
        self.proxyCheckResult = proxyCheckResult
        self.proxyStageResult = proxyStageResult
        self.proxyApplyResult = proxyApplyResult
        self.appCheckResult = appCheckResult
        self.appStageResult = appStageResult
        self.appApplyResult = appApplyResult
    }

    // ProxyUpdating
    func check() async throws -> ProxyUpdateCheckResult { calls.append(.proxyCheck); return proxyCheckResult }
    func stage() async throws -> ProxyUpdateStageResult { calls.append(.proxyStage); return proxyStageResult }
    func apply() async throws -> ProxyUpdateApplyResult { calls.append(.proxyApply); return proxyApplyResult }

    // AppUpdating
    func check() async throws -> AppUpdateCheckResult { calls.append(.appCheck); return appCheckResult }
    func stage() async throws -> AppUpdateStageResult { calls.append(.appStage); return appStageResult }
    func apply() async throws -> AppUpdateApplyResult { calls.append(.appApply); return appApplyResult }
}

private final class OutputDouble: CLICommandOutputWriting, @unchecked Sendable {
    let isInteractive: Bool
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []

    init(isInteractive: Bool) { self.isInteractive = isInteractive }
    func writeStdout(_ text: String) { stdout.append(text) }
    func writeStderr(_ text: String) { stderr.append(text) }
    func confirm(_: String) -> Bool { false }
}

private final class InteractiveOutputDouble: CLICommandOutputWriting, @unchecked Sendable {
    let isInteractive = true
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []
    private(set) var confirmCalls: [String] = []
    private let confirmResult: Bool

    init(confirms: Bool) { self.confirmResult = confirms }
    func writeStdout(_ text: String) { stdout.append(text) }
    func writeStderr(_ text: String) { stderr.append(text) }
    func confirm(_ prompt: String) -> Bool {
        confirmCalls.append(prompt)
        return confirmResult
    }
}

private struct NoOpRuntimeDouble: ProxyRuntimeServicing {
    func status() async throws -> ProxyRuntimeStatus { ProxyRuntimeStatus(port: 0, running: false, health: .stopped, activeVersion: nil, pendingVersion: nil) }
    func start() async throws -> ProxyRuntimeStatus { try await status() }
    func stop() async throws -> ProxyRuntimeStatus { try await status() }
    func restart() async throws -> ProxyRuntimeStatus { try await status() }
}

private struct NoOpLifecycleDouble: AppLifecycleControlling {
    func status() async throws -> AppLifecycleStatus { AppLifecycleStatus(installed: false, running: false, path: nil, version: nil, build: nil) }
    func start() async throws -> AppLifecycleStatus { try await status() }
    func stop() async throws -> AppLifecycleStatus { try await status() }
    func restart() async throws -> AppLifecycleStatus { try await status() }
}

private struct NoOpLogDouble: ProxyLogServicing {
    func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot { ProxyLogSnapshot(fileURL: URL(fileURLWithPath: "/tmp/log"), text: "") }
    func follow() throws {}
}

private struct NoOpStatusDouble: StatusReporting {
    func status() async throws -> CPMStatus {
        CPMStatus(
            app: CPMStatus.App(installed: false, path: nil, version: nil, build: nil, running: false, stagedVersion: nil),
            helper: CPMStatus.Helper(path: "/usr/local/bin/cpm", installed: false, matchesBundled: false),
            proxy: CPMStatus.Proxy(port: 0, running: false, activeVersion: nil, pendingVersion: nil, stagedVersion: nil, logsPath: "/tmp/logs")
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ assertion: (Error) -> Void = { _ in },
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
