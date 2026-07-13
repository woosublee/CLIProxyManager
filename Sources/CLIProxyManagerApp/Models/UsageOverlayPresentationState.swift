import CLIProxyManagerCore
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class UsageOverlayPresentationState: ObservableObject {
    @Published var displayMode: AppConfig.UsageOverlay.DisplayMode
    @Published var presentedDisplayMode: AppConfig.UsageOverlay.DisplayMode
    @Published var compactAccountMaximumHeight: CGFloat
    @Published var compactFittingSize: CGSize?
    @Published var isContentHiddenForModeTransition = false

    init(
        displayMode: AppConfig.UsageOverlay.DisplayMode,
        compactAccountMaximumHeight: CGFloat = 640
    ) {
        self.displayMode = displayMode
        self.presentedDisplayMode = displayMode
        self.compactAccountMaximumHeight = compactAccountMaximumHeight
        self.compactFittingSize = nil
    }

    var contentBlurRadius: CGFloat {
        isContentHiddenForModeTransition ? 8 : 0
    }

    var contentOpacity: Double {
        isContentHiddenForModeTransition ? 0 : 1
    }

    var chromeOpacity: Double { 1 }
    var chromeDisplayMode: AppConfig.UsageOverlay.DisplayMode { displayMode }

    func recordCompactFittingSize(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, compactFittingSize != size else { return false }
        compactFittingSize = size
        return true
    }
}

struct CompactUsageMeasurementState {
    static let estimatedHeight: CGFloat = 120
    private(set) var height: CGFloat = 0
    private var providerIDs: [String] = []

    mutating func updateProviderIDs(_ newProviderIDs: [String]) -> Bool {
        guard providerIDs != newProviderIDs else { return false }
        providerIDs = newProviderIDs
        height = 0
        return true
    }

    mutating func record(height newHeight: CGFloat) -> Bool {
        guard newHeight > 0, abs(newHeight - height) > 0.5 else { return false }
        height = newHeight
        return true
    }

    func viewportHeight(maximumHeight: CGFloat) -> CGFloat {
        min(height > 0 ? height : Self.estimatedHeight, maximumHeight)
    }
}

extension AppConfig.UsageOverlay.DisplayMode {
    var opposite: Self {
        self == .expanded ? .compact : .expanded
    }

    var toggleSymbolName: String {
        switch self {
        case .expanded:
            "arrow.down.right.and.arrow.up.left"
        case .compact:
            "arrow.up.left.and.arrow.down.right"
        }
    }

    var toggleAccessibilityLabel: String {
        switch self {
        case .expanded:
            "Show compact usage window"
        case .compact:
            "Show expanded usage window"
        }
    }
}
