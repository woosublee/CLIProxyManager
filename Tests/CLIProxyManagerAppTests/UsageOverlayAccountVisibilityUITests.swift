import Foundation
import XCTest

final class UsageOverlayAccountVisibilityUITests: XCTestCase {
    func testDashboardProvidesPersistentUsageHUDButtonAndSaveAction() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var usageOverlayButton"))
        XCTAssertTrue(source.contains("account.usageOverlayButtonPresentation"))
        XCTAssertTrue(source.contains("setAccountVisibleInUsageOverlay"))
        XCTAssertTrue(source.contains("isVisible: !account.showsInUsageOverlay"))
        XCTAssertTrue(source.contains(".frame(width: 26, height: 26)"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
