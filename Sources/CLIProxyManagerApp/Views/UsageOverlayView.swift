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
        self.init(
            viewModel: viewModel,
            presentationState: UsageOverlayPresentationState(displayMode: .expanded)
        )
    }

    private var accountPresentation: UsageOverlayAccountPresentation {
        UsageOverlayAccountPresentation(
            serverStatus: viewModel.serverStatus,
            serverControlState: viewModel.serverControlState,
            providerRows: viewModel.providerRows,
            port: viewModel.config.port
        )
    }

    var body: some View {
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
                        refreshStatus: refreshStatus
                    )
                case .compact:
                    CompactUsageOverlayView(
                        providers: accountPresentation.providers,
                        emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
                        maximumAccountHeight: presentationState.compactAccountMaximumHeight,
                        onMeasurementChange: recordCompactAccountHeight
                    )
                }
            }
            .blur(radius: presentationState.contentBlurRadius)
            .opacity(presentationState.contentOpacity)
            .animation(.easeInOut(duration: 0.14), value: presentationState.isContentHiddenForModeTransition)
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
                viewModel: viewModel,
                displayMode: .compact,
                onRefresh: {},
                onToggleDisplayMode: {},
                onClose: {}
            )
            CompactUsageOverlayView(
                providers: accountPresentation.providers,
                emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
                maximumAccountHeight: presentationState.compactAccountMaximumHeight,
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
        if viewModel.isSubscriptionUsageReloadActionInProgress {
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

struct ExpandedUsageOverlayInsertionState: Equatable {
    private(set) var revealedProviderIDs: Set<ProviderRowState.ID>

    init(providerIDs: [ProviderRowState.ID]) {
        revealedProviderIDs = Set(providerIDs)
    }

    mutating func prepare(providerIDs: [ProviderRowState.ID]) -> [ProviderRowState.ID] {
        let presentProviderIDs = Set(providerIDs)
        revealedProviderIDs.formIntersection(presentProviderIDs)
        return providerIDs.filter { !revealedProviderIDs.contains($0) }
    }

    mutating func reveal(
        _ providerIDs: [ProviderRowState.ID],
        presentProviderIDs: [ProviderRowState.ID]
    ) {
        revealedProviderIDs.formUnion(
            Set(providerIDs).intersection(presentProviderIDs)
        )
    }

    func isRevealed(_ providerID: ProviderRowState.ID) -> Bool {
        revealedProviderIDs.contains(providerID)
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
                accessibilityLabel: "Reload subscription usage",
                action: onRefresh
            )
            .disabled(!viewModel.canReloadSubscriptionUsage || viewModel.isSubscriptionUsageReloadActionInProgress)
            .opacity(viewModel.canReloadSubscriptionUsage ? 1 : 0.45)
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
    let providers: [MenuBarConnectedProvider]
    let emptyMessage: String
    let refreshStatus: String
    @State private var insertionState: ExpandedUsageOverlayInsertionState
    @State private var insertionGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        providers: [MenuBarConnectedProvider],
        emptyMessage: String,
        refreshStatus: String
    ) {
        self.providers = providers
        self.emptyMessage = emptyMessage
        self.refreshStatus = refreshStatus
        _insertionState = State(initialValue: ExpandedUsageOverlayInsertionState(providerIDs: providers.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscription Usage")
                        .font(.system(size: 15, weight: .semibold))
                    Text(refreshStatus)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: UsageOverlaySurfaceLayout.expandedHeaderTrailingPadding)
            }

            accountSurface
        }
        .onChange(of: providerIDs) { _, providerIDs in
            insertionGeneration += 1
            let pendingProviderIDs = insertionState.prepare(providerIDs: providerIDs)
            guard !pendingProviderIDs.isEmpty else { return }
            scheduleReveal(for: pendingProviderIDs)
        }
    }

    private var accountSurface: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(providers) { provider in
                    ExpandedUsageOverlayAccountView(provider: provider)
                        .opacity(insertionState.isRevealed(provider.id) ? 1 : 0)
                        .transition(.identity)
                }
            }

            if providers.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                    .transition(.identity)
            }
        }
    }

    private var providerIDs: [ProviderRowState.ID] {
        providers.map(\.id)
    }

    private func scheduleReveal(for providerIDs: [ProviderRowState.ID]) {
        let generation = insertionGeneration
        DispatchQueue.main.async {
            guard generation == insertionGeneration else { return }
            if accessibilityReduceMotion {
                insertionState.reveal(providerIDs, presentProviderIDs: self.providerIDs)
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    insertionState.reveal(providerIDs, presentProviderIDs: self.providerIDs)
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
                snapshotUsage(snapshot, warning: warning)
            }
        }
    }

    @ViewBuilder
    private func snapshotUsage(
        _ snapshot: SubscriptionUsageSnapshot,
        warning: SubscriptionUsageIssue?
    ) -> some View {
        if snapshot.windows.isEmpty {
            SubscriptionUsageWarningAlignedRow(
                warning: warning,
                reservesWarningSpace: warning != nil,
                lastUpdatedAt: snapshot.fetchedAt
            ) {
                Text("Usage details unavailable")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(subscriptionUsageWarningRows(snapshot: snapshot, warning: warning)) { row in
                    ExpandedUsageOverlayProgressRow(
                        row: row,
                        lastUpdatedAt: snapshot.fetchedAt
                    )
                }
            }
        }
    }
}

private struct ExpandedUsageOverlayProgressRow: View {
    let row: SubscriptionUsageWarningRowPresentation
    let lastUpdatedAt: Date

    var body: some View {
        let window = row.window
        let percent = min(max(window.usedPercent, 0), 100)
        VStack(alignment: .leading, spacing: 2) {
            SubscriptionUsageWarningAlignedRow(
                warning: row.warning,
                reservesWarningSpace: row.reservesWarningSpace,
                lastUpdatedAt: lastUpdatedAt
            ) {
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
