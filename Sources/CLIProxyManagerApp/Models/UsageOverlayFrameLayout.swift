import CLIProxyManagerCore
import CoreGraphics

struct UsageOverlayFrameLayout {
    static func targetFrame(
        currentFrame: CGRect,
        targetContentHeight: CGFloat,
        mode: AppConfig.UsageOverlay.DisplayMode,
        visibleFrame: CGRect
    ) -> CGRect {
        let margin = AppWindowMetrics.usageOverlayScreenMargin
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let maximumHeight = min(AppWindowMetrics.usageOverlayMaximumHeight, availableHeight)
        let minimumHeight = mode == .expanded
            ? min(AppWindowMetrics.usageOverlayExpandedMinimumHeight, maximumHeight)
            : min(72, maximumHeight)
        let width = mode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedWidth
            : AppWindowMetrics.usageOverlayCompactWidth
        let height = min(max(targetContentHeight, minimumHeight), maximumHeight)

        var frame = CGRect(
            x: currentFrame.maxX - width,
            y: currentFrame.maxY - height,
            width: width,
            height: height
        )
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)

        if frame.minX < safeFrame.minX { frame.origin.x = safeFrame.minX }
        if frame.maxX > safeFrame.maxX { frame.origin.x = safeFrame.maxX - frame.width }
        if frame.minY < safeFrame.minY { frame.origin.y = safeFrame.minY }
        if frame.maxY > safeFrame.maxY { frame.origin.y = safeFrame.maxY - frame.height }

        return frame
    }
}
