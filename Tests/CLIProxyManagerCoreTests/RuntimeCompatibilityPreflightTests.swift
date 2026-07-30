import XCTest
@testable import CLIProxyManagerCore

final class RuntimeCompatibilityPreflightTests: XCTestCase {
    func testPreflightReadsClaudeVersionWithoutCheckingAuth() async {
        let runner = FakePreflightProcessRunner(results: [
            .success(stdout: "/opt/homebrew/bin/claude\n"),
            .success(stdout: "2.1.221 (Claude Code)\n")
        ])
        let report = await RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.arm64Zsh,
            claudeInspector: ClaudeCodeInspector(runner: runner)
        ).report(artifacts: .matching)

        XCTAssertEqual(runner.invocations, [
            .init(executable: "/usr/bin/env", arguments: ["which", "claude"]),
            .init(executable: "/usr/bin/env", arguments: ["claude", "--version"])
        ])
        XCTAssertEqual(report.decision(for: .startProxy).disposition, .allowedWithWarnings)
    }

    func testStaticReportReportsHostBlockersWithoutObservingClaude() {
        let runner = FakePreflightProcessRunner(results: [])
        let report = RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.x86_64Zsh,
            claudeInspector: ClaudeCodeInspector(runner: runner)
        ).staticReport(artifacts: .matching)

        XCTAssertEqual(report.decision(for: .startProxy).disposition, .blocked)
        XCTAssertEqual(runner.invocations, [])
    }

    func testPreflightDoesNotMutateArtifactOrShellState() async {
        let spy = MutationSpy()
        _ = await makePreflight(spy: spy).report(artifacts: .matching)

        XCTAssertEqual(spy.mutations, [])
    }

    func testUnparseableVersionProducesSanitizedUnverifiedFinding() async {
        let runner = FakePreflightProcessRunner(results: [
            .success(stdout: "/opt/homebrew/bin/claude\n"),
            .success(stdout: "not-a-version\n")
        ])
        let report = await RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.arm64Zsh,
            claudeInspector: ClaudeCodeInspector(runner: runner)
        ).report(artifacts: .matching)

        XCTAssertTrue(report.findings.contains(.unverifiedClaudeCode))
    }

    func testMissingClaudeProducesSanitizedUnavailableFinding() async {
        let runner = FakePreflightProcessRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "")
        ])
        let report = await RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.arm64Zsh,
            claudeInspector: ClaudeCodeInspector(runner: runner)
        ).report(artifacts: .matching)

        XCTAssertTrue(report.findings.contains(.unavailableClaudeCode))
    }

    func testLiveEnvironmentProviderInjectsHostInputs() {
        let environment = LiveRuntimeEnvironmentProvider(
            operatingSystem: { .macOS(major: 15, minor: 4) },
            nativeArchitecture: { .arm64 },
            isTranslated: { true },
            loginShell: { "/bin/zsh" }
        )

        let snapshot = environment.snapshot()

        XCTAssertEqual(snapshot.operatingSystem, .macOS(major: 15, minor: 4))
        XCTAssertEqual(snapshot.architecture, .arm64)
        XCTAssertTrue(snapshot.isTranslated)
        XCTAssertEqual(snapshot.loginShell, "zsh")
    }

    func testRequireUsesStaticReportOnly() {
        let runner = FakePreflightProcessRunner(results: [])
        let preflight = RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.x86_64Zsh,
            claudeInspector: ClaudeCodeInspector(runner: runner)
        )

        XCTAssertThrowsError(try preflight.require(.startProxy, artifacts: .matching))
        XCTAssertEqual(runner.invocations, [])
    }

    private func makePreflight(spy: MutationSpy) -> RuntimeCompatibilityPreflight {
        RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.arm64Zsh,
            claudeInspector: spy
        )
    }
}

private struct FixedEnvironment: RuntimeEnvironmentProviding {
    static let arm64Zsh = Self(
        snapshot: .init(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .arm64,
            isTranslated: false,
            loginShell: "/bin/zsh"
        )
    )
    static let x86_64Zsh = Self(
        snapshot: .init(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .x86_64,
            isTranslated: false,
            loginShell: "/bin/zsh"
        )
    )

    let environmentSnapshot: RuntimeEnvironmentSnapshot

    init(snapshot: RuntimeEnvironmentSnapshot) {
        environmentSnapshot = snapshot
    }

    func snapshot() -> RuntimeEnvironmentSnapshot {
        environmentSnapshot
    }
}

private final class FakePreflightProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private var results: [ProcessResult]
    private(set) var invocations: [Invocation] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        invocations.append(.init(executable: executable, arguments: arguments))
        guard results.isEmpty == false else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "FakeProcessRunner exhausted results")
        }
        return results.removeFirst()
    }
}

private final class MutationSpy: ClaudeCodeInspecting, @unchecked Sendable {
    private(set) var mutations: [String] = []

    func observeVersion() async -> ClaudeCodeObservation {
        .version("2.1.220")
    }
}

private extension CompatibilityArtifacts {
    static let matching = Self(
        bundled: .explicit(.darwinArm64),
        active: .explicit(.darwinArm64),
        pending: .explicit(.darwinArm64)
    )
}

private extension ProcessResult {
    static func success(stdout: String) -> Self {
        Self(exitCode: 0, stdout: stdout, stderr: "")
    }
}
