import AppKit
import XCTest
@testable import CLIProxyManagerApp

@MainActor
final class MenuBarWindowBridgeTests: XCTestCase {
    func testConfiguratorMarksHostWindowReadOnly() {
        let window = makeWindow(fittingHeight: 120)
        let configurator = MenuBarWindowConfigurator()

        configurator.configure(window: window)

        XCTAssertEqual(window.sharingType, .readOnly)
    }

    func testConfiguratorUpdatesContentHeightWhilePreservingWidth() async {
        let window = makeWindow(fittingHeight: 120)
        let configurator = MenuBarWindowConfigurator()

        configurator.configure(window: window)
        await Task.yield()

        XCTAssertEqual(window.contentView?.frame.width, 290)
        XCTAssertEqual(window.contentView?.frame.height, 120)
    }

    func testUsageOverlayConfiguratorMakesBackgroundTransparentAndAppliesTopLevel() {
        let window = makeWindow(fittingHeight: 120)
        let configurator = UsageOverlayWindowConfigurator()

        configurator.configure(window: window, alwaysOnTop: true)

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden == true)
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isHidden == true)
    }

    func testUsageOverlayConfiguratorAllowsBackgroundWindowDragging() {
        let window = makeWindow(fittingHeight: 120)
        let configurator = UsageOverlayWindowConfigurator()

        configurator.configure(window: window, alwaysOnTop: false)

        XCTAssertTrue(window.isMovableByWindowBackground)
    }

    func testUsageOverlayConfiguratorDoesNotRestoreAutosavedFrameWhenReconfigured() {
        let defaults = UserDefaults.standard
        let autosaveKey = "NSWindow Frame usage-overlay"
        let previousValue = defaults.object(forKey: autosaveKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: autosaveKey)
            } else {
                defaults.removeObject(forKey: autosaveKey)
            }
        }

        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        defaults.set(
            "\(screenFrame.minX + 40) \(screenFrame.minY + 40) 290 120 "
                + "\(screenFrame.minX) \(screenFrame.minY) \(screenFrame.width) \(screenFrame.height) ",
            forKey: autosaveKey
        )
        let window = makeWindow(fittingHeight: 120)
        let currentFrame = CGRect(
            x: screenFrame.midX,
            y: screenFrame.midY,
            width: 290,
            height: 420
        )
        window.setFrame(currentFrame, display: false)
        let configurator = UsageOverlayWindowConfigurator()

        configurator.configure(window: window, alwaysOnTop: true)

        XCTAssertTrue(window.frameAutosaveName.isEmpty)
        XCTAssertEqual(window.frame, currentFrame)
    }

    func testWindowBridgeCoordinatorInvokesCallbackOnEveryWindowKeyNotification() {
        let window = makeWindow(fittingHeight: 120)
        var refreshCount = 0
        let bridge = MenuBarWindowBridge(onWindowDidBecomeKey: { refreshCount += 1 })
        let coordinator = bridge.makeCoordinator()

        coordinator.configure(window: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertEqual(refreshCount, 2)
    }

    func testWindowBridgeCoordinatorDoesNotDuplicateObserverOnRepeatedConfigure() {
        let window = makeWindow(fittingHeight: 120)
        var refreshCount = 0
        let bridge = MenuBarWindowBridge(onWindowDidBecomeKey: { refreshCount += 1 })
        let coordinator = bridge.makeCoordinator()

        coordinator.configure(window: window)
        coordinator.configure(window: window)
        coordinator.configure(window: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertEqual(refreshCount, 1)
    }

    func testWindowBridgeCoordinatorIgnoresNotificationsFromOtherWindows() {
        let window = makeWindow(fittingHeight: 120)
        let otherWindow = makeWindow(fittingHeight: 120)
        var refreshCount = 0
        let bridge = MenuBarWindowBridge(onWindowDidBecomeKey: { refreshCount += 1 })
        let coordinator = bridge.makeCoordinator()

        coordinator.configure(window: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)

        XCTAssertEqual(refreshCount, 0)
    }

    func testMenuBarStatusViewRefreshesEveryTimeItsWindowBecomesKey() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("MenuBarWindowBridge(onWindowDidBecomeKey:"))
        XCTAssertTrue(source.contains("await viewModel.refresh()"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeWindow(fittingHeight: CGFloat) -> NSWindow {
        let contentView = FixedFittingSizeView(fittingSize: NSSize(width: 290, height: fittingHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }
}

@MainActor
private final class FixedFittingSizeView: NSView {
    private let size: NSSize

    init(fittingSize: NSSize) {
        size = fittingSize
        super.init(frame: NSRect(origin: .zero, size: fittingSize))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        size
    }
}
