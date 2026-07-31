import XCTest
@testable import CLIProxyManagerCore

final class RuntimeCompatibilityTests: XCTestCase {
    func testProxyStartBlocksUnsupportedArchitecture() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .x86_64,
                loginShell: "/bin/zsh"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .notChecked
        )

        XCTAssertEqual(report.decision(for: .startProxy).disposition, .blocked)
        XCTAssertTrue(report.findings.contains(.unsupportedArchitecture(expected: .arm64, actual: .x86_64)))
    }

    func testInstallShellFunctionsAllowsArtifactMismatchWithZshAndAvailableClaudeCode() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .arm64,
                loginShell: "/bin/zsh"
            ),
            artifacts: .init(
                bundled: .explicit(.darwinArm64),
                active: .explicit(.init(operatingSystem: .darwin, architecture: .x86_64)),
                pending: nil
            ),
            claude: .version("2.1.220")
        )

        XCTAssertTrue(report.findings.contains(.unsupportedArtifactTarget(
            expected: .darwinArm64,
            actual: .init(operatingSystem: .darwin, architecture: .x86_64)
        )))
        XCTAssertEqual(report.decision(for: .installShellFunctions).disposition, .allowedWithWarnings)
    }

    func testInstallShellFunctionsBlocksUnsupportedLoginShell() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .arm64,
                loginShell: "/bin/bash"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .notChecked
        )

        XCTAssertEqual(report.decision(for: .installShellFunctions).disposition, .blocked)
        XCTAssertTrue(report.findings.contains(.unsupportedLoginShell(expectedBasename: "zsh", actualBasename: "bash")))
    }

    func testInstallShellFunctionsBlocksUnavailableClaudeCode() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .arm64,
                loginShell: "/bin/zsh"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .unavailable
        )

        XCTAssertTrue(report.findings.contains(.unavailableClaudeCode))
        XCTAssertEqual(report.decision(for: .installShellFunctions).disposition, .blocked)
    }

    func testUnsupportedLoginShellOnlyBlocksShellFunctionInstallation() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .arm64,
                loginShell: "/bin/bash"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .version("2.1.220")
        )

        XCTAssertEqual(report.decision(for: .startProxy).disposition, .allowedWithWarnings)
        XCTAssertEqual(report.decision(for: .installShellFunctions).disposition, .blocked)
    }

    func testTranslatedArm64BlocksMutationActionsWhileAllowingRecovery() {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .arm64,
                isTranslated: true,
                loginShell: "/bin/zsh"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .notChecked
        )

        XCTAssertTrue(report.findings.contains(.translatedExecution))
        for action in [
            CompatibilityAction.startProxy,
            .restartProxy,
            .prepareOAuthLogin,
            .prepareModelServer,
            .stageProxyUpdate,
            .applyProxyUpdate,
            .scheduleProxyUpdate,
        ] {
            XCTAssertEqual(report.decision(for: action).disposition, .blocked, "Expected \(action) to be blocked")
        }
        XCTAssertEqual(report.decision(for: .inspect).disposition, .allowedWithWarnings)
        XCTAssertEqual(report.decision(for: .stopProxy).disposition, .allowedWithWarnings)
        XCTAssertEqual(report.decision(for: .recoverProxyArtifact).disposition, .allowedWithWarnings)
    }

    func testLegacyArtifactInferenceWarnsUntilExplicitTargetBackfill() {
        let environment = RuntimeCompatibilityEnvironment(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .arm64,
            loginShell: "/bin/zsh"
        )
        let legacy = RuntimeCompatibilityPolicy.current.report(
            environment: environment,
            artifacts: .init(bundled: .legacy, active: nil, pending: nil),
            claude: .notChecked
        )

        XCTAssertEqual(legacy.decision(for: .startProxy).disposition, .allowedWithWarnings)
        XCTAssertTrue(legacy.findings.contains(.legacyArtifactTargetInferred))
        XCTAssertEqual(
            CPMStatus.Compatibility(report: legacy).findings.map(\.code),
            ["legacyArtifactTargetInferred"]
        )

        let explicit = RuntimeCompatibilityPolicy.current.report(
            environment: environment,
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
            claude: .notChecked
        )

        XCTAssertEqual(explicit.decision(for: .startProxy).disposition, .allowed)
        XCTAssertFalse(explicit.findings.contains(.legacyArtifactTargetInferred))
    }
}
