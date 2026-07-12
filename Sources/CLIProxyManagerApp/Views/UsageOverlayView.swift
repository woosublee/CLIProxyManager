import CLIProxyManagerCore
import SwiftUI

struct UsageOverlayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    var onClose: () -> Void = {}
    @State private var refreshStatusReferenceDate = Date()

    private var providers: [MenuBarConnectedProvider] {
        MenuBarStatusSnapshot(
            serverStatus: viewModel.serverStatus,
            serverControlState: viewModel.serverControlState,
            providers: viewModel.providerRows,
            port: viewModel.config.port
        ).connectedProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if providers.isEmpty {
                Text("No connected accounts")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(providers) { provider in
                        UsageOverlayAccountView(provider: provider)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: AppWindowMetrics.usageOverlayWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial.opacity(viewModel.config.usageOverlay.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide usage window")
            }
            .frame(height: 20)

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
            }
        }
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

private struct UsageOverlayAccountView: View {
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
        if case .unavailable(.proxyUnavailable) = provider.subscriptionUsageState {
            Text("Start the server to check usage")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            switch subscriptionUsageDisplayState(for: provider.subscriptionUsageState) {
            case .hidden:
                Text("Subscription usage is disabled")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case .loading(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .snapshot(let snapshot, let warning):
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
                    UsageOverlayProgressRow(window: window)
                }
            }
        }
    }
}

private struct UsageOverlayProgressRow: View {
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
