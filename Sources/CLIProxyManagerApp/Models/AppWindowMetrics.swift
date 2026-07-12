import CoreGraphics

enum AppWindowMetrics {
    static let mainWidth: CGFloat = 380
    static let mainMaxHeight: CGFloat = 720
    static let settingsWidth: CGFloat = 720
    static let settingsHeight: CGFloat = 500
    static let menuBarWidth: CGFloat = 248
    static let usageOverlayExpandedWidth: CGFloat = 300
    static let usageOverlayCompactWidth: CGFloat = 108
    static let usageOverlayExpandedMinimumHeight: CGFloat = 260
    static let usageOverlayMaximumHeight: CGFloat = 720
    static let usageOverlayScreenMargin: CGFloat = 16

    // Temporary compatibility aliases while the existing view/controller migrate in Tasks 4–5.
    static let usageOverlayWidth = usageOverlayExpandedWidth
    static let usageOverlayHeight = usageOverlayExpandedMinimumHeight
}
