import CLIProxyManagerCore
import CoreGraphics

struct UsageOverlayFrameLayout {
    static func targetFrame(
        currentFrame: CGRect,
        targetContentHeight: CGFloat,
        mode: AppConfig.UsageOverlay.DisplayMode,
        visibleFrame: CGRect
    ) -> CGRect {
        let availableHeight = max(
            1,
            visibleFrame.height - AppWindowMetrics.usageOverlayScreenMargin * 2
        )
        let maximumHeight = min(AppWindowMetrics.usageOverlayMaximumHeight, availableHeight)
        let minimumHeight = mode == .expanded
            ? min(AppWindowMetrics.usageOverlayExpandedMinimumHeight, maximumHeight)
            : min(72, maximumHeight)
        let width = mode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedWidth
            : AppWindowMetrics.usageOverlayCompactWidth
        let height = min(max(targetContentHeight, minimumHeight), maximumHeight)

        let frame = CGRect(
            x: currentFrame.maxX - width,
            y: currentFrame.maxY - height,
            width: width,
            height: height
        )
        return clampedFrame(frame, visibleFrame: visibleFrame)
    }

    static func placementFrame(
        size: CGSize,
        rightOffset: CGFloat,
        topOffset: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let frame = CGRect(
            x: visibleFrame.maxX - rightOffset - size.width,
            y: visibleFrame.maxY - topOffset - size.height,
            width: size.width,
            height: size.height
        )
        return clampedFrame(frame, visibleFrame: visibleFrame)
    }

    static func clampedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var frame = frame
        let margin = AppWindowMetrics.usageOverlayScreenMargin
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)

        if frame.minX < safeFrame.minX { frame.origin.x = safeFrame.minX }
        if frame.maxX > safeFrame.maxX { frame.origin.x = safeFrame.maxX - frame.width }
        if frame.minY < safeFrame.minY { frame.origin.y = safeFrame.minY }
        if frame.maxY > safeFrame.maxY { frame.origin.y = safeFrame.maxY - frame.height }

        return frame
    }
}
