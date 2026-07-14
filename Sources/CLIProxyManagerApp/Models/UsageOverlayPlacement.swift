import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

struct UsageOverlayDisplayIdentity: Codable, Equatable {
    let uuid: String?
    let vendorNumber: UInt32?
    let modelNumber: UInt32?
    let serialNumber: UInt32?
}

struct UsageOverlayPlacement: Codable, Equatable {
    let display: UsageOverlayDisplayIdentity
    let rightOffset: CGFloat
    let topOffset: CGFloat

    init(display: UsageOverlayDisplayIdentity, frame: CGRect, visibleFrame: CGRect) {
        self.display = display
        self.rightOffset = visibleFrame.maxX - frame.maxX
        self.topOffset = visibleFrame.maxY - frame.maxY
    }
}

struct UsageOverlayScreen: Equatable {
    let displayID: CGDirectDisplayID
    let identity: UsageOverlayDisplayIdentity
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool

    init?(screen: NSScreen) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = number.uint32Value
        self.init(
            displayID: displayID,
            identity: Self.identity(for: displayID),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isPrimary: displayID == CGMainDisplayID()
        )
    }

    init(
        displayID: CGDirectDisplayID,
        identity: UsageOverlayDisplayIdentity,
        frame: CGRect,
        visibleFrame: CGRect,
        isPrimary: Bool
    ) {
        self.displayID = displayID
        self.identity = identity
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
    }

    static func match(
        identity: UsageOverlayDisplayIdentity,
        in screens: [UsageOverlayScreen]
    ) -> UsageOverlayScreen? {
        if let uuid = identity.uuid {
            let matches = screens.filter { $0.identity.uuid == uuid }
            if matches.count == 1 { return matches[0] }
        }

        return uniqueHardwareMatch(identity: identity, in: screens)
    }

    private static func uniqueHardwareMatch(
        identity: UsageOverlayDisplayIdentity,
        in screens: [UsageOverlayScreen]
    ) -> UsageOverlayScreen? {
        guard let vendorNumber = identity.vendorNumber,
              let modelNumber = identity.modelNumber,
              let serialNumber = identity.serialNumber else {
            return nil
        }
        let matches = screens.filter {
            $0.identity.vendorNumber == vendorNumber
                && $0.identity.modelNumber == modelNumber
                && $0.identity.serialNumber == serialNumber
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func identity(for displayID: CGDirectDisplayID) -> UsageOverlayDisplayIdentity {
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).flatMap { unmanaged in
            let value = unmanaged.takeRetainedValue()
            return CFUUIDCreateString(nil, value) as String?
        }
        let vendorNumber = nonzero(CGDisplayVendorNumber(displayID))
        let modelNumber = nonzero(CGDisplayModelNumber(displayID))
        let serialNumber = nonzero(CGDisplaySerialNumber(displayID))
        return UsageOverlayDisplayIdentity(
            uuid: uuid,
            vendorNumber: vendorNumber,
            modelNumber: modelNumber,
            serialNumber: serialNumber
        )
    }

    private static func nonzero(_ value: UInt32) -> UInt32? {
        value == 0 ? nil : value
    }
}

struct UsageOverlayScreenProvider {
    let screens: () -> [UsageOverlayScreen]
    let screenForWindow: (NSWindow) -> UsageOverlayScreen?

    static let live = UsageOverlayScreenProvider(
        screens: {
            NSScreen.screens.compactMap(UsageOverlayScreen.init(screen:))
        },
        screenForWindow: { window in
            window.screen.flatMap(UsageOverlayScreen.init(screen:))
        }
    )
}

struct UsageOverlayPlacementPersistence {
    static let placementKey = "UsageOverlayPlacement"
    static let legacyFrameKey = "NSWindow Frame usage-overlay"

    let load: () -> UsageOverlayPlacement?
    let save: (UsageOverlayPlacement) -> Bool
    let loadLegacyFrame: () -> String?
    let removeLegacyFrame: () -> Void

    static let disabled = UsageOverlayPlacementPersistence(
        load: { nil },
        save: { _ in false },
        loadLegacyFrame: { nil },
        removeLegacyFrame: {}
    )

    static func userDefaults(_ defaults: UserDefaults = .standard) -> UsageOverlayPlacementPersistence {
        UsageOverlayPlacementPersistence(
            load: {
                guard let data = defaults.data(forKey: placementKey) else { return nil }
                return try? JSONDecoder().decode(UsageOverlayPlacement.self, from: data)
            },
            save: { placement in
                guard let data = try? JSONEncoder().encode(placement) else { return false }
                defaults.set(data, forKey: placementKey)
                return true
            },
            loadLegacyFrame: {
                defaults.string(forKey: legacyFrameKey)
            },
            removeLegacyFrame: {
                defaults.removeObject(forKey: legacyFrameKey)
            }
        )
    }
}

struct LegacyUsageOverlayFrame: Equatable {
    let windowFrame: CGRect
    let screenFrame: CGRect

    init?(descriptor: String) {
        let tokens = descriptor.split(whereSeparator: \Character.isWhitespace)
        let values = tokens.compactMap { Double($0) }
        guard tokens.count == 8,
              values.count == tokens.count,
              values.allSatisfy(\.isFinite),
              values[2] > 0,
              values[3] > 0,
              values[6] > 0,
              values[7] > 0 else {
            return nil
        }
        windowFrame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        screenFrame = CGRect(x: values[4], y: values[5], width: values[6], height: values[7])
    }

    func matchingScreen(in screens: [UsageOverlayScreen]) -> UsageOverlayScreen? {
        let matches = screens.filter {
            screenFrame.isApproximatelyEqual(to: $0.frame)
                || screenFrame.isApproximatelyEqual(to: $0.visibleFrame)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
