import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class SettingsNavigationTests: XCTestCase {
    func testSettingsTabsAreGeneralServerAdvancedAndAbout() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["General", "Server", "Advanced", "About"])
        XCTAssertEqual(SettingsTab.allCases.map(\.systemImage), ["slider.horizontal.3", "server.rack", "wrench.and.screwdriver", "info.circle"])
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
