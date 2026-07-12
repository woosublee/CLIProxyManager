import CLIProxyManagerCore
import Combine
import CoreGraphics

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
