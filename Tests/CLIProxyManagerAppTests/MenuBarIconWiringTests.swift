import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class MenuBarIconWiringTests: XCTestCase {
    func testAppSharesBuildFlavorAcrossMenuBarAndDock() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private let buildFlavor: AppBuildFlavor"))
        XCTAssertTrue(source.contains("let buildFlavor = AppBuildFlavor.current"))
        XCTAssertTrue(source.contains("AppAppearanceService(buildFlavor: buildFlavor)"))
        XCTAssertTrue(source.contains("appAppearanceService: appAppearanceService"))
        XCTAssertTrue(source.contains("MenuBarAppIcon("))
        XCTAssertTrue(source.contains("serverControlState: viewModel.serverControlState"))
        XCTAssertTrue(source.contains("severity: viewModel.serverStatus.severity"))
        XCTAssertTrue(source.contains("buildFlavor: buildFlavor"))
        XCTAssertFalse(source.contains("AppMarkRenderer.menuBarTemplate"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
