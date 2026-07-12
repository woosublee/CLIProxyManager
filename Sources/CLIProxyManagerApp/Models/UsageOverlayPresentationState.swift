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

func usageOverlayModeAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
}

struct CompactUsageMeasurementState {
    static let estimatedHeight: CGFloat = 120
    private(set) var height: CGFloat = 0

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
