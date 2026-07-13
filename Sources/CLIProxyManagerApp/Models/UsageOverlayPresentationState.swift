import CLIProxyManagerCore
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class UsageOverlayPresentationState: ObservableObject {
    @Published var displayMode: AppConfig.UsageOverlay.DisplayMode
    @Published var compactAccountMaximumHeight: CGFloat

    init(
        displayMode: AppConfig.UsageOverlay.DisplayMode,
        compactAccountMaximumHeight: CGFloat = 640
    ) {
        self.displayMode = displayMode
        self.compactAccountMaximumHeight = compactAccountMaximumHeight
    }
}

struct CompactUsageMeasurementState {
    static let estimatedHeight: CGFloat = 120
    private(set) var height: CGFloat = 0
    private var providerIDs: [String] = []

    mutating func updateProviderIDs(_ newProviderIDs: [String]) -> Bool {
        guard providerIDs != newProviderIDs else { return false }
        let accountSetChanged = Set(providerIDs) != Set(newProviderIDs)
        providerIDs = newProviderIDs
        guard accountSetChanged else { return false }
        height = 0
        return true
    }

    mutating func record(height newHeight: CGFloat) -> Bool {
        guard newHeight > 0, abs(newHeight - height) > 0.5 else { return false }
        height = newHeight
        return true
    }

    mutating func record(height newHeight: CGFloat, providerIDs newProviderIDs: [String]) -> Bool {
        providerIDs = newProviderIDs
        return record(height: newHeight)
    }

    func viewportHeight(maximumHeight: CGFloat) -> CGFloat {
        min(contentHeight, maximumHeight)
    }

    func needsScrolling(maximumHeight: CGFloat) -> Bool {
        contentHeight > maximumHeight
    }

    private var contentHeight: CGFloat {
        height > 0 ? height : Self.estimatedHeight
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
