import CLIProxyManagerCore
import SwiftUI

struct UsageOverlayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var presentationState: UsageOverlayPresentationState
    var onContentSizeInvalidated: () -> Void = {}
    @State private var refreshStatusReferenceDate = Date()

    init(
        viewModel: DashboardViewModel,
        presentationState: UsageOverlayPresentationState,
        onContentSizeInvalidated: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.presentationState = presentationState
        self.onContentSizeInvalidated = onContentSizeInvalidated
    }

    init(viewModel: DashboardViewModel) {
        let accountPresentation = UsageOverlayAccountPresentation(
            serverStatus: viewModel.serverStatus,
            serverControlState: viewModel.serverControlState,
            providerRows: viewModel.providerRows,
            port: viewModel.config.port
        )
        self.init(
            viewModel: viewModel,
            presentationState: UsageOverlayPresentationState(
                displayMode: .expanded,
                accountPresentation: accountPresentation
            )
        )
    }

    var body: some View {
        let accountPresentation = presentationState.presentedAccountPresentation
        VStack(alignment: .leading, spacing: presentationState.presentedDisplayMode == .expanded ? 12 : 4) {
            if presentationState.presentedDisplayMode == .compact {
                Color.clear
                    .frame(height: UsageOverlaySurfaceLayout.chromeSize.height)
            }

            Group {
                switch presentationState.presentedDisplayMode {
                case .expanded:
                    ExpandedUsageOverlayContent(
                        providers: accountPresentation.providers,
                        emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
                        refreshStatus: refreshStatus,
                        now: refreshStatusReferenceDate
                    )
                case .compact:
                    CompactUsageOverlayView(
                        providers: accountPresentation.providers,
                        emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
                        maximumAccountHeight: presentationState.compactAccountMaximumHeight,
                        now: refreshStatusReferenceDate,
                        onMeasurementChange: recordCompactAccountHeight
                    )
                }
            }
            .blur(radius: presentationState.contentBlurRadius)
            .opacity(presentationState.contentOpacity)
            .animation(.easeInOut(duration: 0.14), value: presentationState.isContentConcealed)
        }
        .overlay(alignment: .topTrailing) {
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
                viewModel: viewModel,
                displayMode: .compact,
                onRefresh: {},
                onToggleDisplayMode: {},
                onClose: {}
            )
            CompactUsageOverlayView(
                providers: presentationState.presentedAccountPresentation.providers,
                emptyMessage: presentationState.presentedAccountPresentation.emptyMessage
                    ?? "No connected accounts",
                maximumAccountHeight: presentationState.compactAccountMaximumHeight,
                now: refreshStatusReferenceDate,
                onMeasurementChange: recordCompactAccountHeight
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

    private func recordCompactAccountHeight(_ accountHeight: CGFloat) {
        let fittingSize = CGSize(
            width: AppWindowMetrics.usageOverlayCompactWidth,
            height: UsageOverlaySurfaceLayout.chromeSize.height + 4 + accountHeight + 20
        )
        if presentationState.recordCompactFittingSize(fittingSize) {
            onContentSizeInvalidated()
        }
    }

    private var refreshStatus: String {
        if viewModel.isUsageReloadActionInProgress {
            return "REFRESHING"
        }
        guard let refreshedAt = viewModel.lastSuccessfulUsageRefreshAt else {
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
    @ObservedObject var viewModel: DashboardViewModel
    let displayMode: AppConfig.UsageOverlay.DisplayMode
    let onRefresh: () -> Void
    let onToggleDisplayMode: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            chromeButton(
                symbol: "arrow.clockwise",
                accessibilityLabel: "Reload usage",
                action: onRefresh
            )
            .disabled(!viewModel.canReloadUsage || viewModel.isUsageReloadActionInProgress)
            .opacity(viewModel.canReloadUsage ? 1 : 0.45)
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
    }
}

private struct ExpandedUsageOverlayContent: View {
    let providers: [MenuBarConnectedProvider]
    let emptyMessage: String
    let refreshStatus: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage")
                        .font(.system(size: 15, weight: .semibold))
                    Text(refreshStatus)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: UsageOverlaySurfaceLayout.expandedHeaderTrailingPadding)
            }

            if providers.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(providers) { provider in
                        ExpandedUsageOverlayAccountView(provider: provider, now: now)
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
    showsUsage: Bool,
    usageState: ProviderUsageState
) -> ExpandedUsageContentPresentation {
    guard showsUsage else { return .headerOnly }
    switch usageState {
    case .subscription(.unavailable(.proxyUnavailable)),
         .apiCost(.unavailable(.proxyUnavailable)):
        return .message("Start the server to check usage")
    default:
        break
    }

    switch providerUsageDisplayState(for: usageState) {
    case .hidden:
        switch usageState {
        case .subscription:
            return .message("Subscription usage is disabled")
        case .apiCost:
            return .message("API cost tracking is disabled")
        }
    case .loading(let message), .unavailable(let message):
        return .message(message)
    case .subscription, .apiCost:
        return .usage
    }
}

private struct ExpandedUsageOverlayAccountView: View {
    let provider: MenuBarConnectedProvider
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                CodexResetCreditAvatar(
                    providerID: provider.id,
                    providerType: provider.providerType,
                    accountName: provider.usageOverlayDisplayName,
                    size: 20,
                    snapshot: provider.resetCreditsSnapshot,
                    now: now
                )
                Text(provider.usageOverlayDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                if let warningMessage = providerUsageWarningMessage(for: provider.usageState) {
                    UsageWarningIcon(message: warningMessage)
                        .frame(
                            width: UsageWarningLayout.iconFrameSize.width,
                            height: UsageWarningLayout.iconFrameSize.height
                        )
                }
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
            showsUsage: provider.showsUsage,
            usageState: provider.usageState
        ) {
        case .headerOnly:
            EmptyView()
        case .message(let message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .usage:
            switch providerUsageDisplayState(for: provider.usageState) {
            case let .subscription(snapshot, warning):
                snapshotUsage(snapshot, warning: warning)
            case let .apiCost(snapshot, issues):
                apiCostUsage(snapshot, issues: issues)
            case .hidden, .loading, .unavailable:
                EmptyView()
            }
        }
    }

    private func apiCostUsage(
        _ snapshot: APICostSnapshot,
        issues: [APICostIssue]
    ) -> some View {
        let presentation = apiCostUsagePresentation(snapshot: snapshot, issues: issues)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(presentation.rows) { row in
                Group {
                    switch row.decoration {
                    case .textOnly:
                        HStack(spacing: 8) {
                            Text(row.label)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 28, alignment: .leading)
                            Text(row.detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(row.textLayout.lineLimit)
                                .minimumScaleFactor(row.textLayout.minimumScaleFactor)
                                .allowsTightening(true)
                                .layoutPriority(1)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            Text(row.cost)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(row.textLayout.lineLimit)
                                .minimumScaleFactor(row.textLayout.minimumScaleFactor)
                                .allowsTightening(true)
                                .layoutPriority(1)
                                .frame(minWidth: 58, alignment: .trailing)
                        }
                    }
                }
                .fastTooltip(row.tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private func snapshotUsage(
        _ snapshot: SubscriptionUsageSnapshot,
        warning _: SubscriptionUsageIssue?
    ) -> some View {
        if snapshot.windows.isEmpty {
            Text("Usage details unavailable")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(subscriptionUsageWarningRows(snapshot: snapshot, warning: nil)) { row in
                    ExpandedUsageOverlayProgressRow(row: row)
                }
            }
        }
    }
}

private struct ExpandedUsageOverlayProgressRow: View {
    let row: SubscriptionUsageWarningRowPresentation

    var body: some View {
        let window = row.window
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
