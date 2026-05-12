import Foundation
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class SettingsNavigationTests: XCTestCase {
    func testAboutVersionTextUsesBundleVersion() {
        let bundle = BundleMock(info: [
            "CFBundleShortVersionString": "0.1.2-beta.2",
            "CFBundleVersion": "4"
        ])

        XCTAssertEqual(aboutVersionText(bundle: bundle), "Version 0.1.2-beta.2 (4)")
    }

    func testSettingsTabsAreGeneralServerAdvancedAndAbout() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["General", "Server", "Advanced", "About"])
        XCTAssertEqual(SettingsTab.allCases.map(\.systemImage), ["slider.horizontal.3", "server.rack", "wrench.and.screwdriver", "info.circle"])
    }

    func testOAuthCompletionTransitionsAddProviderSheetToInitialProviderSettings() {
        XCTAssertEqual(
            DashboardSheet.afterOAuthLoginCompletion(.codex),
            .providerSettings(.codex, isInitialSetup: true)
        )
    }

    func testProviderSettingsSheetIdentityIncludesInitialSetupState() {
        XCTAssertNotEqual(
            DashboardSheet.providerSettings(.codex, isInitialSetup: true).id,
            DashboardSheet.providerSettings(.codex, isInitialSetup: false).id
        )
    }

    func testCodexProviderSettingsUsesTallerSheetHeight() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.codexHeight, 700)
    }
}

private final class BundleMock: Bundle, @unchecked Sendable {
    private let storedInfo: [String: Any]

    init(info: [String: Any]) {
        self.storedInfo = info
        super.init()
    }

    override var infoDictionary: [String: Any]? {
        storedInfo
    }
}

final class GeneralServerControlSnapshotTests: XCTestCase {
    func testStoppedServerShowsStartAction() {
        let snapshot = GeneralServerControlSnapshot(status: DiagnosticStatus(
            severity: .warning,
            title: "Needs check",
            message: "Server status has not been checked yet."
        ))

        XCTAssertEqual(snapshot.title, "CLIProxyAPI Server")
        XCTAssertEqual(snapshot.actionTitle, "Start Server")
        XCTAssertFalse(snapshot.isRunning)
    }

    func testRunningServerShowsStopAction() {
        let snapshot = GeneralServerControlSnapshot(status: DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI Running",
            message: "Models are available on port 18317."
        ))

        XCTAssertEqual(snapshot.actionTitle, "Stop Server")
        XCTAssertTrue(snapshot.isRunning)
    }
}
