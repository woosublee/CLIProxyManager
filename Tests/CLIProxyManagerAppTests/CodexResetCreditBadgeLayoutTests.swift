import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditBadgeLayoutTests: XCTestCase {
    func testBadgeMetricsScaleForAllAccountAvatarSizes() {
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 20), 14)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 22), 14)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 26), 15)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.topTrailingOffset(for: 22), CGSize(width: 4, height: -4))
    }

    func testViewsUseSharedDecoratedAvatarWithoutChangingMenuBarAppIcon() throws {
        let menu = try appSource(relativePath: "Views/MenuBarStatusView.swift")
        let expanded = try appSource(relativePath: "Views/UsageOverlayView.swift")
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
        let badge = try appSource(relativePath: "Views/CodexResetCreditBadge.swift")
        let app = try appSource(relativePath: "CLIProxyManagerApp.swift")

        XCTAssertTrue(menu.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(menu.contains("now: refreshAgeReferenceDate"))
        XCTAssertTrue(menu.contains(".frame(minHeight: 22, alignment: .center)"))
        XCTAssertTrue(expanded.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(expanded.contains("now: refreshStatusReferenceDate"))
        XCTAssertTrue(compact.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(compact.contains(".overlay(alignment: .bottomTrailing)"))
        XCTAssertFalse(compact.contains(".fastTooltip(provider.usageOverlayDisplayName)"))
        XCTAssertTrue(badge.contains(".ultraThinMaterial"))
        XCTAssertTrue(badge.contains("accessibilityReduceTransparency"))
        XCTAssertTrue(badge.contains("accessibilityContrast"))
        XCTAssertTrue(badge.contains(".fastTooltip(tooltip"))
        XCTAssertTrue(badge.contains("strokeBorder"))
        XCTAssertTrue(badge.contains(".shadow("))
        XCTAssertTrue(badge.contains("accessibilityReduceMotion"))
        XCTAssertFalse(badge.contains("BrandPalette.statusError"))
        XCTAssertFalse(badge.contains(".help("))
        XCTAssertFalse(app.contains("CodexResetCreditBadge"))
        XCTAssertFalse(app.contains("CodexResetCreditAvatar"))
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
