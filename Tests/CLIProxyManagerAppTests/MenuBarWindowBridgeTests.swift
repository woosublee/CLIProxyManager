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

    private func makeWindow(fittingHeight: CGFloat) -> NSWindow {
        let contentView = FixedFittingSizeView(fittingSize: NSSize(width: 290, height: fittingHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 420),
            styleMask: [.titled],
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
