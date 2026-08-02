import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class MenuBarIconStateTests: XCTestCase {
    func testRunningReadyMapsToConnected() {
        XCTAssertEqual(
            MenuBarIconState(serverControlState: .running, severity: .ready),
            .connected
        )
    }

    func testStartingMapsToConnectingForEverySeverity() {
        for severity in [DiagnosticSeverity.ready, .warning, .error] {
            XCTAssertEqual(
                MenuBarIconState(serverControlState: .starting, severity: severity),
                .connecting
            )
        }
    }

    func testNonReadyAndInactiveStatesMapToStopped() {
        let cases: [(ServerControlState, DiagnosticSeverity)] = [
            (.running, .warning),
            (.running, .error),
            (.stopping, .ready),
            (.stopped, .warning),
            (.error("failed"), .error)
        ]

        for (controlState, severity) in cases {
            XCTAssertEqual(
                MenuBarIconState(serverControlState: controlState, severity: severity),
                .stopped
            )
        }
    }

    func testAccessibilityStatusMatchesState() {
        XCTAssertEqual(MenuBarIconState.connected.accessibilityStatus, "connected")
        XCTAssertEqual(MenuBarIconState.connecting.accessibilityStatus, "connecting")
        XCTAssertEqual(MenuBarIconState.stopped.accessibilityStatus, "stopped")
    }

    func testBuildFlavorUsesOnlyExactDevelopmentMarker() {
        XCTAssertEqual(AppBuildFlavor(infoDictionary: nil), .official)
        XCTAssertEqual(AppBuildFlavor(infoDictionary: [:]), .official)
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "official"]),
            .official
        )
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "Development"]),
            .official
        )
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "development"]),
            .development
        )
    }
}
