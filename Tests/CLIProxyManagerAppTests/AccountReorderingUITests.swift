import XCTest

final class AccountReorderingUITests: XCTestCase {
    func testDashboardUsesDedicatedDragHandleAndStringDropDestination() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("line.3.horizontal"))
        XCTAssertTrue(source.contains(".draggable(account.id.rawValue)"))
        XCTAssertTrue(source.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(source.contains("Reorder account"))
    }

    func testDashboardProvidesMoveUpAndMoveDownFallbackCommands() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("Move Up"))
        XCTAssertTrue(source.contains("Move Down"))
        XCTAssertTrue(source.contains("canMoveAccountUp"))
        XCTAssertTrue(source.contains("canMoveAccountDown"))
    }

    func testDashboardTracksInsertionPositionAndReducedMotion() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("activeDropIndex"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("AccountReorderDropZone"))
    }

    private func dashboardSource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
