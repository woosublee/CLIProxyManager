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
}
