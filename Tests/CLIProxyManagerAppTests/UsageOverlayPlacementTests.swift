import XCTest
@testable import CLIProxyManagerApp

final class UsageOverlayPlacementTests: XCTestCase {
    func testMatchesScreenByUUIDBeforeHardwareFallback() {
        let target = screen(
            id: 2,
            uuid: "target",
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )
        let duplicateHardware = screen(
            id: 3,
            uuid: "other",
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(
            UsageOverlayScreen.match(identity: target.identity, in: [duplicateHardware, target]),
            target
        )
    }

    func testMatchesScreenByUniqueHardwareIdentityWhenUUIDIsUnavailable() {
        let target = screen(
            id: 2,
            uuid: nil,
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(UsageOverlayScreen.match(identity: target.identity, in: [target]), target)
    }

    func testMatchesScreenByHardwareIdentityWhenUUIDChanges() {
        let savedIdentity = identity(uuid: "old", vendor: 1, model: 2, serial: 3)
        let currentScreen = screen(
            id: 2,
            uuid: "new",
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(
            UsageOverlayScreen.match(identity: savedIdentity, in: [currentScreen]),
            currentScreen
        )
    }

    func testRejectsAmbiguousHardwareIdentity() {
        let first = screen(
            id: 2,
            uuid: nil,
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )
        let second = screen(
            id: 3,
            uuid: nil,
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        XCTAssertNil(UsageOverlayScreen.match(identity: first.identity, in: [first, second]))
    }

    func testPlacementRestoresRightTopOffsetOnNegativeOriginScreen() {
        let visibleFrame = CGRect(x: -2560, y: 0, width: 2560, height: 1410)
        let frame = CGRect(x: -124, y: 1035, width: 108, height: 359)
        let placement = UsageOverlayPlacement(
            display: identity(uuid: "left"),
            frame: frame,
            visibleFrame: visibleFrame
        )

        let restored = UsageOverlayFrameLayout.placementFrame(
            size: frame.size,
            rightOffset: placement.rightOffset,
            topOffset: placement.topOffset,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(restored, frame)
    }

    func testPlacementKeepsOffsetsWhenVisibleFrameChanges() {
        let originalVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let originalFrame = CGRect(x: 1200, y: 600, width: 108, height: 180)
        let placement = UsageOverlayPlacement(
            display: identity(uuid: "display"),
            frame: originalFrame,
            visibleFrame: originalVisibleFrame
        )
        let resizedVisibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1050)

        let restored = UsageOverlayFrameLayout.placementFrame(
            size: originalFrame.size,
            rightOffset: placement.rightOffset,
            topOffset: placement.topOffset,
            visibleFrame: resizedVisibleFrame
        )

        XCTAssertEqual(resizedVisibleFrame.maxX - restored.maxX, placement.rightOffset)
        XCTAssertEqual(resizedVisibleFrame.maxY - restored.maxY, placement.topOffset)
    }

    func testLegacyFrameParsesAndMatchesVisibleScreenFrame() {
        let screen = screen(
            id: 2,
            uuid: "left",
            vendor: 1,
            model: 2,
            serial: 3,
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1410)
        )
        let descriptor = "-124 1035 108 359 -2560 0 2560 1410 "

        let legacyFrame = LegacyUsageOverlayFrame(descriptor: descriptor)

        XCTAssertEqual(legacyFrame?.windowFrame, CGRect(x: -124, y: 1035, width: 108, height: 359))
        XCTAssertEqual(legacyFrame?.matchingScreen(in: [screen]), screen)
    }

    func testLegacyFrameRejectsExtraInvalidToken() {
        let descriptor = "invalid -124 1035 108 359 -2560 0 2560 1410"

        XCTAssertNil(LegacyUsageOverlayFrame(descriptor: descriptor))
    }

    func testLegacyFrameRejectsNonFiniteValues() {
        let descriptor = "nan 1035 108 359 -2560 0 2560 1410"

        XCTAssertNil(LegacyUsageOverlayFrame(descriptor: descriptor))
    }

    private func identity(
        uuid: String?,
        vendor: UInt32? = nil,
        model: UInt32? = nil,
        serial: UInt32? = nil
    ) -> UsageOverlayDisplayIdentity {
        UsageOverlayDisplayIdentity(
            uuid: uuid,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: serial
        )
    }

    private func screen(
        id: CGDirectDisplayID,
        uuid: String?,
        vendor: UInt32?,
        model: UInt32?,
        serial: UInt32?,
        frame: CGRect,
        visibleFrame: CGRect? = nil
    ) -> UsageOverlayScreen {
        UsageOverlayScreen(
            displayID: id,
            identity: identity(uuid: uuid, vendor: vendor, model: model, serial: serial),
            frame: frame,
            visibleFrame: visibleFrame ?? frame,
            isPrimary: false
        )
    }
}
