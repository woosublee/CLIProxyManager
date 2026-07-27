import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipMigrationTests: XCTestCase {
    func testAppSourcesUseFastTooltipInsteadOfNativeHelp() throws {
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp")
        let sourceFiles = try FileManager.default
            .subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try sourceFiles.map {
            try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
        }

        XCTAssertFalse(sources.contains { $0.contains(".help(") })
        XCTAssertGreaterThanOrEqual(sources.filter { $0.contains(".fastTooltip(") }.count, 8)
    }

    func testKnownTooltipSurfacesUseSharedModifier() throws {
        let files = [
            "Views/ProviderListView.swift",
            "Views/MenuBarStatusView.swift",
            "Views/DashboardView.swift",
            "Views/ProviderSettingsSheets.swift",
            "Views/CodexResetCreditBadge.swift",
            "Views/SubscriptionUsageWarningIcon.swift",
            "Views/UsageOverlayView.swift",
            "Views/CompactUsageOverlayView.swift"
        ]

        for file in files {
            XCTAssertTrue(try appSource(relativePath: file).contains(".fastTooltip("), file)
        }
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
