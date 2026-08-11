import XCTest

final class AccountReorderingUITests: XCTestCase {
    func testDashboardUsesDedicatedDragHandleAndWholeListDropDestination() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("line.3.horizontal"))
        XCTAssertTrue(source.contains(".onDrag"))
        XCTAssertTrue(source.contains("AccountReorderDropDelegate"))
        XCTAssertTrue(source.contains(".onDrop("))
        XCTAssertTrue(source.contains("Reorder account"))
    }

    func testDashboardRemovesFallbackCommandsWhileKeepingDragReordering() throws {
        let source = try dashboardSource()

        XCTAssertFalse(source.contains("Move Up"))
        XCTAssertFalse(source.contains("Move Down"))
        XCTAssertTrue(source.contains("line.3.horizontal"))
        XCTAssertTrue(source.contains(".onDrag"))
        XCTAssertTrue(source.contains("AccountReorderDropDelegate"))
        XCTAssertTrue(source.contains(".onDrop("))
    }

    func testDashboardTracksInsertionPositionAndReducedMotion() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("activeDropIndex"))
        XCTAssertTrue(source.contains("previewAccountIDs"))
        XCTAssertTrue(source.contains("AccountFramePreferenceKey"))
        XCTAssertTrue(source.contains("AccountOrdering.insertionIndex"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
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
