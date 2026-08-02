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

    func testMenuBarRendererProducesTemplateImagesForEveryVariant() throws {
        let connected = try XCTUnwrap(
            AppMarkRenderer.menuBarIcon(
                presentation: .connected,
                buildFlavor: .official
            )
        )
        let connecting = try XCTUnwrap(
            AppMarkRenderer.menuBarIcon(
                presentation: .reducedMotionConnecting,
                buildFlavor: .official
            )
        )
        let stopped = try XCTUnwrap(
            AppMarkRenderer.menuBarIcon(
                presentation: .stopped,
                buildFlavor: .official
            )
        )
        let development = try XCTUnwrap(
            AppMarkRenderer.menuBarIcon(
                presentation: .connected,
                buildFlavor: .development
            )
        )

        for image in [connected, connecting, stopped, development] {
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size.width, MenuBarIconMetrics.size, accuracy: 0.01)
            XCTAssertEqual(image.size.height, MenuBarIconMetrics.size, accuracy: 0.01)
        }
        XCTAssertNotEqual(connected.tiffRepresentation, connecting.tiffRepresentation)
        XCTAssertNotEqual(connected.tiffRepresentation, stopped.tiffRepresentation)
        XCTAssertNotEqual(connected.tiffRepresentation, development.tiffRepresentation)
    }

    func testAnimatorPreRendersImagesAndStartsOnlyForUnreducedConnectingState() throws {
        let animator = MenuBarIconAnimator(buildFlavor: .development)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        animator.update(state: .connected, reduceMotion: false, now: now)
        XCTAssertEqual(animator.presentation, .connected)
        XCTAssertTrue(try XCTUnwrap(animator.image).isTemplate)
        XCTAssertFalse(animator.isAnimating)

        animator.update(state: .connecting, reduceMotion: true, now: now)
        XCTAssertEqual(animator.presentation, .reducedMotionConnecting)
        XCTAssertTrue(try XCTUnwrap(animator.image).isTemplate)
        XCTAssertFalse(animator.isAnimating)

        animator.update(state: .connecting, reduceMotion: false, now: now)
        XCTAssertEqual(animator.presentation, MenuBarIconAnimation.presentation(elapsed: 0))
        XCTAssertTrue(try XCTUnwrap(animator.image).isTemplate)
        XCTAssertTrue(animator.isAnimating)

        animator.update(state: .stopped, reduceMotion: false, now: now)
        XCTAssertEqual(animator.presentation, .stopped)
        XCTAssertTrue(try XCTUnwrap(animator.image).isTemplate)
        XCTAssertFalse(animator.isAnimating)
    }

    func testMenuBarLabelUsesPreRenderedImageInsteadOfRawTimelineArtwork() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Image(nsImage: animator.image"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("Timer.scheduledTimer"))
        XCTAssertTrue(source.contains(".onChange(of: state)"))
        XCTAssertFalse(source.contains("TimelineView"))
        XCTAssertFalse(source.contains("AppMarkRenderer.menuBarIcon(\n                presentation: animator.presentation"))
    }

    func testDevelopmentMenuBarUsesNegativeSpaceWaveform() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".fill(Color.primary)"))
        XCTAssertTrue(source.contains(".blendMode(isDevelopment ? .destinationOut : .normal)"))
        XCTAssertTrue(source.contains(".compositingGroup()"))
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
