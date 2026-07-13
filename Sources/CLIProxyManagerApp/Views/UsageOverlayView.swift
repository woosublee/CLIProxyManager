import CLIProxyManagerCore
import SwiftUI

struct UsageOverlayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var presentationState: UsageOverlayPresentationState
    var onToggleDisplayMode: () -> Void = {}
    var onContentSizeInvalidated: () -> Void = {}
    var onClose: () -> Void = {}
    @State private var refreshStatusReferenceDate = Date()

    init(
        viewModel: DashboardViewModel,
        presentationState: UsageOverlayPresentationState,
        onToggleDisplayMode: @escaping () -> Void = {},
        onContentSizeInvalidated: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.presentationState = presentationState
        self.onToggleDisplayMode = onToggleDisplayMode
        self.onContentSizeInvalidated = onContentSizeInvalidated
        self.onClose = onClose
    }

    init(
        viewModel: DashboardViewModel,
        onClose: @escaping () -> Void = {}
    ) {
        self.init(
            viewModel: viewModel,
            presentationState: UsageOverlayPresentationState(displayMode: .expanded),
            onClose: onClose
        )
    }

    private var providers: [MenuBarConnectedProvider] {
        MenuBarStatusSnapshot(
            serverStatus: viewModel.serverStatus,
            serverControlState: viewModel.serverControlState,
            providers: viewModel.providerRows,
            port: viewModel.config.port,
            showsSubscriptionUsage: true
        ).connectedProviders
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: presentationState.presentedDisplayMode == .expanded ? 12 : 4) {
                Color.clear
                    .frame(height: 24)

                Group {
                    switch presentationState.presentedDisplayMode {
                    case .expanded:
                        ExpandedUsageOverlayContent(
                            viewModel: viewModel,
                            providers: providers,
                            refreshStatus: refreshStatus
                        )
                    case .compact:
                        CompactUsageOverlayView(
                            providers: providers,
                            maximumAccountHeight: presentationState.compactAccountMaximumHeight,
                            onMeasurementChange: onContentSizeInvalidated
                        )
                    }
                }
                .blur(radius: presentationState.contentBlurRadius)
                .opacity(presentationState.contentOpacity)
                .animation(.easeInOut(duration: 0.14), value: presentationState.isContentHiddenForModeTransition)
            }

            if presentationState.displayMode == .compact,
               presentationState.presentedDisplayMode == .expanded {
                compactMeasurementContent
            }
        }
        .padding(presentationState.presentedDisplayMode == .expanded ? 16 : 10)
        .frame(width: overlayWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(.regularMaterial.opacity(viewModel.config.usageOverlay.backgroundOpacity))
        .contentShape(
            RoundedRectangle(
                cornerRadius: presentationState.presentedDisplayMode == .expanded
                    ? UsageOverlaySurfaceLayout.expandedCornerRadius
                    : UsageOverlaySurfaceLayout.compactCornerRadius,
                style: .continuous
            )
        )
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .task { await viewModel.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                refreshStatusReferenceDate = Date()
            }
        }
    }

    private var compactMeasurementContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            UsageOverlayChrome(
                displayMode: .compact,
                onToggleDisplayMode: {},
                onClose: {}
            )
            CompactUsageOverlayView(
                providers: providers,
                maximumAccountHeight: presentationState.compactAccountMaximumHeight,
                onMeasurementChange: onContentSizeInvalidated
            )
        }
        .padding(10)
        .frame(width: AppWindowMetrics.usageOverlayCompactWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CompactUsageOverlayFittingSizePreferenceKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(CompactUsageOverlayFittingSizePreferenceKey.self) { size in
            if presentationState.recordCompactFittingSize(size) {
                onContentSizeInvalidated()
            }
        }
        .accessibilityHidden(true)
    }

    private var overlayWidth: CGFloat {
        presentationState.presentedDisplayMode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedWidth
            : AppWindowMetrics.usageOverlayCompactWidth
    }

    private var refreshStatus: String {
        if viewModel.isSubscriptionUsageRefreshInProgress {
            return "REFRESHING"
        }
        guard let refreshedAt = viewModel.lastSuccessfulSubscriptionUsageRefreshAt else {
            return "NOT YET REFRESHED"
        }
        let minutes = max(0, Int(refreshStatusReferenceDate.timeIntervalSince(refreshedAt) / 60))
        return minutes == 0 ? "UPDATED NOW" : "UPDATED \(minutes)M AGO"
    }
}

private struct CompactUsageOverlayFittingSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct UsageOverlayChrome: View {
    let displayMode: AppConfig.UsageOverlay.DisplayMode
    let onToggleDisplayMode: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Spacer()
            chromeButton(
                symbol: displayMode.toggleSymbolName,
                accessibilityLabel: displayMode.toggleAccessibilityLabel,
                action: onToggleDisplayMode
            )
            chromeButton(
                symbol: "xmark",
                accessibilityLabel: "Hide usage window",
                action: onClose
            )
        }
        .frame(height: 24)
    }

    private func chromeButton(
        symbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

private struct ExpandedUsageOverlayContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let providers: [MenuBarConnectedProvider]
    let refreshStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscription Usage")
                        .font(.system(size: 15, weight: .semibold))
                    Text(refreshStatus)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.refreshSubscriptionUsage(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRefreshSubscriptionUsage || viewModel.isSubscriptionUsageRefreshInProgress)
                .opacity(viewModel.canRefreshSubscriptionUsage ? 1 : 0.45)
                .accessibilityLabel("Reload subscription usage")
            }

            if providers.isEmpty {
                Text("No connected accounts")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(providers) { provider in
                        ExpandedUsageOverlayAccountView(provider: provider)
                    }
                }
            }
        }
    }
}

enum ExpandedUsageContentPresentation: Equatable {
    case headerOnly
    case message(String)
    case usage
}

func expandedUsageContentPresentation(
    showsSubscriptionUsage: Bool,
    subscriptionUsageState: AccountSubscriptionUsageState
) -> ExpandedUsageContentPresentation {
    guard showsSubscriptionUsage else { return .headerOnly }
    if case .unavailable(.proxyUnavailable) = subscriptionUsageState {
        return .message("Start the server to check usage")
    }

    switch subscriptionUsageDisplayState(for: subscriptionUsageState) {
    case .hidden:
        return .message("Subscription usage is disabled")
    case .loading(let message), .unavailable(let message):
        return .message(message)
    case .snapshot:
        return .usage
    }
}

private struct ExpandedUsageOverlayAccountView: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderAvatar(providerID: provider.id, size: 20)
                Text(provider.usageOverlayDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(verbatim: "$ \(provider.functionName)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        switch expandedUsageContentPresentation(
            showsSubscriptionUsage: provider.showsSubscriptionUsage,
            subscriptionUsageState: provider.subscriptionUsageState
        ) {
        case .headerOnly:
            EmptyView()
        case .message(let message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .usage:
            if case let .snapshot(snapshot, warning) = subscriptionUsageDisplayState(
                for: provider.subscriptionUsageState
            ) {
                HStack(alignment: .top, spacing: 6) {
                    snapshotUsage(snapshot)
                    if let warning {
                        SubscriptionUsageWarningIcon(
                            issue: warning,
                            lastUpdatedAt: snapshot.fetchedAt
                        )
                        .padding(.top, 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func snapshotUsage(_ snapshot: SubscriptionUsageSnapshot) -> some View {
        if snapshot.windows.isEmpty {
            Text("Usage details unavailable")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.windows) { window in
                    ExpandedUsageOverlayProgressRow(window: window)
                }
            }
        }
    }
}

private struct ExpandedUsageOverlayProgressRow: View {
    let window: UsageWindow

    var body: some View {
        let percent = min(max(window.usedPercent, 0), 100)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(subscriptionUsageDisplayLabel(for: window))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                ProgressView(value: percent, total: 100)
                    .tint(subscriptionUsageProgressTone(for: percent).color)
                    .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }
            if let resetAt = window.resetAt {
                Text("Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 36)
            }
        }
    }
}
