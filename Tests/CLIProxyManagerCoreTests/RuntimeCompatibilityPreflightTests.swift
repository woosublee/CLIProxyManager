import XCTest
@testable import CLIProxyManagerCore

final class RuntimeCompatibilityPreflightTests: XCTestCase {
    func testAsyncReportMatchesStaticReport() async {
        let preflight = RuntimeCompatibilityPreflight(environment: FixedEnvironment.arm64Zsh)

        let asyncReport = await preflight.report(artifacts: .matching)
        let staticReport = preflight.staticReport(artifacts: .matching)

        XCTAssertEqual(asyncReport, staticReport)
        XCTAssertEqual(asyncReport.decision(for: .startProxy).disposition, .allowed)
    }

    func testStaticReportReportsHostBlockers() {
        let report = RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.x86_64Zsh
        ).staticReport(artifacts: .matching)

        XCTAssertEqual(report.decision(for: .startProxy).disposition, .blocked)
    }

    func testAccountLoginShellReaderReturnsAccountRecordShell() {
        let reader = AccountLoginShellReader(accountRecord: FixedAccountRecord(loginShell: "/bin/zsh"))

        XCTAssertEqual(reader.loginShell(), "/bin/zsh")
    }

    func testAccountLoginShellReaderReturnsEmptyStringWhenAccountRecordReadFails() {
        let reader = AccountLoginShellReader(accountRecord: FixedAccountRecord(loginShell: nil))

        XCTAssertEqual(reader.loginShell(), "")
    }

    func testAccountLoginShellReaderReturnsEmptyStringForEmptyAccountRecordShell() {
        let reader = AccountLoginShellReader(accountRecord: FixedAccountRecord(loginShell: ""))

        XCTAssertEqual(reader.loginShell(), "")
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

    func testRequireUsesStaticReport() {
        let preflight = RuntimeCompatibilityPreflight(
            environment: FixedEnvironment.x86_64Zsh
        )

        XCTAssertThrowsError(try preflight.require(.startProxy, artifacts: .matching))
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

private struct FixedAccountRecord: AccountRecordReading {
    let loginShell: String?

    func readLoginShell() -> String? {
        loginShell
    }
}

private extension CompatibilityArtifacts {
    static let matching = Self(
        bundled: .explicit(.darwinArm64),
        active: .explicit(.darwinArm64),
        pending: .explicit(.darwinArm64)
    )
}
