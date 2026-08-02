import AppKit
import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

@MainActor
final class MenuBarAppIconTests: XCTestCase {
    func testAnimationTimingUsesApprovedCycle() {
        XCTAssertEqual(MenuBarIconAnimation.drawDuration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.holdDuration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.fadeDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.blankDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.cycleDuration, 1.4, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.framesPerSecond, 15, accuracy: 0.0001)
    }

    func testAnimationDrawHoldFadeBlankAndWrap() {
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 0),
            trim: 0,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 0.45),
            trim: 0.5,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.0),
            trim: 1,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.175),
            trim: 1,
            opacity: 0.5
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.325),
            trim: 0,
            opacity: 0
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.4),
            trim: 0,
            opacity: 1
        )
    }

    func testReducedMotionUsesStaticPartialWaveform() {
        assertPresentation(
            MenuBarIconPresentation.reducedMotionConnecting,
            trim: 0.65,
            opacity: 1
        )
        XCTAssertFalse(MenuBarIconPresentation.reducedMotionConnecting.showsSlash)
    }

    func testAccessibilityLabelsIncludeStateAndDevelopmentBuild() {
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .connected, buildFlavor: .official),
            "CLIProxyManager connected"
        )
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .connecting, buildFlavor: .development),
            "CLIProxyManager connecting, development build"
        )
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .stopped, buildFlavor: .development),
            "CLIProxyManager stopped, development build"
        )
    }

    func testConnectedStoppedConnectingAndDevelopmentRenderDifferently() throws {
        let connected = try renderedData(
            presentation: .connected,
            buildFlavor: .official
        )
        let connecting = try renderedData(
            presentation: .reducedMotionConnecting,
            buildFlavor: .official
        )
        let stopped = try renderedData(
            presentation: .stopped,
            buildFlavor: .official
        )
        let development = try renderedData(
            presentation: .connected,
            buildFlavor: .development
        )

        XCTAssertNotEqual(connected, connecting)
        XCTAssertNotEqual(connected, stopped)
        XCTAssertNotEqual(connected, development)
    }

    func testIconMetricsPreserveApprovedGeometry() {
        XCTAssertEqual(MenuBarIconMetrics.size, 18)
        XCTAssertEqual(MenuBarIconMetrics.officialMarkInset, 2)
        XCTAssertEqual(MenuBarIconMetrics.developmentMarkInset, 3)
        XCTAssertEqual(MenuBarIconMetrics.developmentCornerRadius, 4)
        XCTAssertEqual(MenuBarIconMetrics.developmentBorderWidth, 1)
    }

    func testAnimatedViewUsesPausedTimelineAndReduceMotion() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("TimelineView"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("paused: state != .connecting || reduceMotion"))
        XCTAssertTrue(source.contains(".onChange(of: state)"))
    }

    private func assertPresentation(
        _ presentation: MenuBarIconPresentation,
        trim: CGFloat,
        opacity: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.trim, trim, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(presentation.opacity, opacity, accuracy: 0.0001, file: file, line: line)
        XCTAssertFalse(presentation.showsSlash, file: file, line: line)
    }

    private func renderedData(
        presentation: MenuBarIconPresentation,
        buildFlavor: AppBuildFlavor
    ) throws -> Data {
        let view = MenuBarIconArtwork(
            presentation: presentation,
            buildFlavor: buildFlavor
        )
        .environment(\.colorScheme, .light)
        .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: MenuBarIconMetrics.size,
            height: MenuBarIconMetrics.size
        )
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let bitmapData = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
