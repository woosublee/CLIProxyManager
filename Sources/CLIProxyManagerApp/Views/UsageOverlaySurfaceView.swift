import AppKit
import Combine
import SwiftUI

struct UsageOverlaySurfaceLayout {
    static let expandedCornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 18
    static let chromeSize = CGSize(width: 76, height: 24)
    static let chromeInset: CGFloat = 16
    static let expandedContentInset: CGFloat = 16
    static let expandedHeaderControlSpacing: CGFloat = 8
    static let expandedHeaderTrailingPadding = chromeSize.width
        + chromeInset
        - expandedContentInset
        + expandedHeaderControlSpacing

    static func chromeFrame(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - chromeInset - chromeSize.width,
            y: bounds.maxY - chromeInset - chromeSize.height,
            width: chromeSize.width,
            height: chromeSize.height
        )
    }

    static func surfaceFrame(in bounds: CGRect) -> CGRect {
        bounds
    }

    static func cornerRadius(progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return expandedCornerRadius
            + (compactCornerRadius - expandedCornerRadius) * progress
    }
}

@MainActor
final class UsageOverlaySurfaceView: NSView {
    private let hostingView: NSHostingView<UsageOverlayView>
    private let chromeHostingView: NSHostingView<UsageOverlayChrome>
    private var cancellables: Set<AnyCancellable> = []
    private var cornerRadius = UsageOverlaySurfaceLayout.expandedCornerRadius

    init(
        rootView: UsageOverlayView,
        viewModel: DashboardViewModel,
        presentationState: UsageOverlayPresentationState,
        onToggleDisplayMode: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        hostingView = NSHostingView(rootView: rootView)
        chromeHostingView = NSHostingView(
            rootView: UsageOverlayChrome(
                viewModel: viewModel,
                displayMode: presentationState.chromeDisplayMode,
                onRefresh: {
                    Task { await viewModel.reloadSubscriptionUsage() }
                },
                onToggleDisplayMode: onToggleDisplayMode,
                onClose: onClose
            )
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(hostingView)
        addSubview(chromeHostingView)
        presentationState.$displayMode
            .removeDuplicates()
            .sink { [weak chromeHostingView] mode in
                chromeHostingView?.rootView = UsageOverlayChrome(
                    viewModel: viewModel,
                    displayMode: mode,
                    onRefresh: {
                        Task { await viewModel.reloadSubscriptionUsage() }
                    },
                    onToggleDisplayMode: onToggleDisplayMode,
                    onClose: onClose
                )
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override var fittingSize: NSSize {
        hostingView.fittingSize
    }

    var hostedSurfaceFrame: CGRect {
        hostingView.frame
    }

    var chromeViewIdentity: ObjectIdentifier {
        ObjectIdentifier(chromeHostingView)
    }

    override func layout() {
        super.layout()
        hostingView.frame = UsageOverlaySurfaceLayout.surfaceFrame(in: bounds)
        chromeHostingView.frame = UsageOverlaySurfaceLayout.chromeFrame(in: bounds)
        updateCornerRadius()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentView?.wantsLayer = true
    }

    private func updateCornerRadius() {
        let expandedWidth = AppWindowMetrics.usageOverlayExpandedWidth
        let compactWidth = AppWindowMetrics.usageOverlayCompactWidth
        let widthRange = max(1, expandedWidth - compactWidth)
        let progress = (expandedWidth - bounds.width) / widthRange
        cornerRadius = UsageOverlaySurfaceLayout.cornerRadius(progress: progress)
        layer?.cornerRadius = cornerRadius
    }
}
