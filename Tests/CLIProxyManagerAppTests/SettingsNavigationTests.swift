import Foundation
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class SettingsNavigationTests: XCTestCase {
    func testAboutVersionTextUsesBundleVersion() {
        let bundle = BundleMock(info: [
            "CFBundleShortVersionString": "0.1.2-beta.1",
            "CFBundleVersion": "3"
        ])

        XCTAssertEqual(aboutVersionText(bundle: bundle), "Version 0.1.2-beta.1 (3)")
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
            title: "확인 필요",
            message: "서버 상태 확인 전입니다."
        ))

        XCTAssertEqual(snapshot.title, "CLIProxyAPI Server")
        XCTAssertEqual(snapshot.actionTitle, "Start Server")
        XCTAssertFalse(snapshot.isRunning)
    }

    func testRunningServerShowsStopAction() {
        let snapshot = GeneralServerControlSnapshot(status: DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI 실행 중",
            message: "포트 18317에서 모델 목록을 불러올 수 있습니다."
        ))

        XCTAssertEqual(snapshot.actionTitle, "Stop Server")
        XCTAssertTrue(snapshot.isRunning)
    }
}
