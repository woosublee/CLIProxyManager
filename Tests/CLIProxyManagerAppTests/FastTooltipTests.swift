import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipTests: XCTestCase {
    func testDefaultDelayAndTextNormalization() {
        XCTAssertEqual(FastTooltipConfiguration.defaultDelayMilliseconds, 120)
        XCTAssertNil(normalizedFastTooltipText(nil))
        XCTAssertNil(normalizedFastTooltipText("   \n"))
        XCTAssertEqual(normalizedFastTooltipText("  Reset available  "), "Reset available")
    }

    func testTooltipSourceUsesSharedAdaptivePopoverSurface() throws {
        let source = try appSource(relativePath: "Views/FastTooltip.swift")

        XCTAssertTrue(source.contains(".onHover"))
        XCTAssertTrue(source.contains(".popover("))
        XCTAssertTrue(source.contains(".regularMaterial"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("accessibilityReduceTransparency"))
        XCTAssertTrue(source.contains("accessibilityContrast"))
        XCTAssertTrue(source.contains("Task.sleep"))
        XCTAssertFalse(source.contains("BrandPalette.statusError"))
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp")
                .appendingPathComponent(relativePath),
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
