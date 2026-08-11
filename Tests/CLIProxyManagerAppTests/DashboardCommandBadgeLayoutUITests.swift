import AppKit
import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

final class DashboardCommandBadgeLayoutUITests: XCTestCase {
    func testSlugPillKeepsCommandTextOnOneLine() throws {
        let slugPill = try sourceSection(
            in: designChromeSource(),
            after: "struct SlugPill: View {",
            before: "\n}\n\n// MARK: - Provider avatar"
        )
        let commandText = try sourceSection(
            in: slugPill,
            after: "Text(slug)",
            before: "Image(systemName:"
        )

        XCTAssertTrue(commandText.contains(".lineLimit(1)"))
        XCTAssertTrue(commandText.contains(".truncationMode(.tail)"))
    }

    func testDashboardMovesCommandBadgeBeforeAccountActions() throws {
        let providerCard = try sourceSection(
            in: dashboardSource(),
            after: "struct ProviderAccountCardView: View {",
            before: "private struct ProviderAccountDragPreview: View"
        )
        let trailingControls = try sourceSection(
            in: providerCard,
            after: "private var trailingControls: some View {",
            before: "\n    }\n\n    private var dragHandle"
        )

        let badgeRange = try XCTUnwrap(
            trailingControls.range(of: "SlugPill(slug: account.commandName)")
        )
        let actionsRange = try XCTUnwrap(trailingControls.range(of: "actions"))
        XCTAssertLessThan(
            trailingControls.distance(from: trailingControls.startIndex, to: badgeRange.lowerBound),
            trailingControls.distance(from: trailingControls.startIndex, to: actionsRange.lowerBound)
        )
    }

    @MainActor
    func testDashboardRendersShortCommandTextAtMainWindowWidth() throws {
        let withCommand = try renderedCardPixels(commandName: "a1")
        let withoutCommand = try renderedCardPixels(commandName: "")

        XCTAssertNotEqual(
            withCommand,
            withoutCommand,
            "A non-empty command must change the rendered badge instead of being compressed to zero width."
        )
    }

    @MainActor
    func testDashboardKeepsAccountDetailSuffixVisibleAtMainWindowWidth() throws {
        let comAddress = try renderedCardPixels(
            commandName: "a1",
            connectionDetail: "account@example.com"
        )
        let netAddress = try renderedCardPixels(
            commandName: "a1",
            connectionDetail: "account@example.net"
        )

        XCTAssertNotEqual(
            comAddress,
            netAddress,
            "The detail row must retain enough width to render the account detail suffix."
        )
    }

    @MainActor
    private func renderedCardPixels(
        commandName: String,
        connectionDetail: String = "user@example.com"
    ) throws -> Data {
        let provider = ProviderRowState(
            id: .claude,
            providerType: .claude,
            authProfileID: "claude-test",
            commandProfileID: "claude-test",
            name: "Claude OAuth",
            nickname: "",
            functionName: commandName,
            connectionTitle: "Connected",
            connectionDetail: connectionDetail,
            isConnected: true,
            accountDetailHidden: false
        )
        let card = ProviderAccountCardView(
            account: DashboardAccountSnapshot(provider: provider),
            canReorder: false,
            isDropTarget: false,
            isDragging: false,
            dragStarted: {},
            connect: {},
            settings: {},
            toggleUsageOverlayVisibility: {},
            toggleAccountDetailVisibility: {},
            setEnabled: { _ in },
            relogin: {},
            isOAuthLoginInProgress: false,
            remove: {}
        )
        .frame(width: AppWindowMetrics.mainWidth - 28)
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: card)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let bitmapData = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func dashboardSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DashboardView.swift")
    }

    private func designChromeSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
