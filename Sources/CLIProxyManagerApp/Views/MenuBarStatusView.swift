import CLIProxyManagerCore
import SwiftUI

struct MenuBarStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: DashboardViewModel
    let openMain: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void
    @State private var refreshAgeReferenceDate = Date()

    private var subscriptionUsageRefreshAgeLabel: String? {
        guard let refreshedAt = viewModel.lastSuccessfulSubscriptionUsageRefreshAt else { return nil }
        let elapsed = max(0, refreshAgeReferenceDate.timeIntervalSince(refreshedAt))
        let minutes = Int(elapsed / 60)
        if minutes == 0 { return "now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    private var snapshot: MenuBarStatusSnapshot {
        MenuBarStatusSnapshot(
            serverStatus: viewModel.serverStatus,
            serverControlState: viewModel.serverControlState,
            providers: viewModel.providerRows,
            port: viewModel.config.port
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBlock
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)

            menuSeparator

            MenuItemRow(
                icon: "arrow.clockwise",
                label: "Reload usage",
                trailing: subscriptionUsageRefreshAgeLabel,
                disabled: !viewModel.canRefreshSubscriptionUsage || viewModel.isSubscriptionUsageRefreshInProgress
            ) {
                Task {
                    await viewModel.refreshSubscriptionUsage(force: true)
                }
            }

            MenuItemRow(
                icon: snapshot.isServerRunning ? "stop.fill" : "play.fill",
                label: snapshot.isServerRunning ? "Stop server" : "Start server",
                disabled: viewModel.isServerActionInProgress
            ) {
                dismiss()
                Task {
                    if snapshot.isServerRunning {
                        await viewModel.stopServer()
                    } else {
                        await viewModel.startServer()
                    }
                }
            }

            menuSeparator

            MenuItemRow(icon: "macwindow", label: "Open CLIProxyManager", action: dismissing(openMain))
            MenuItemRow(icon: "gearshape", label: "Preferences…", shortcut: "⌘,", action: dismissing(openSettings))

            menuSeparator

            MenuItemRow(icon: nil, label: "Quit CLIProxyManager", shortcut: "⌘Q", action: dismissing(quit))
        }
        .padding(.vertical, 5)
        .frame(width: AppWindowMetrics.menuBarWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuBarWindowBridge())
        .onAppear {
            refreshAgeReferenceDate = Date()
        }
        .task {
            await viewModel.refresh()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                refreshAgeReferenceDate = Date()
            }
        }
    }

    private func dismissing(_ action: @escaping () -> Void) -> () -> Void {
        {
            dismiss()
            action()
        }
    }

    // MARK: - Status header

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusLED(state: ledState, size: 10, pulse: false)
                Text(statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if snapshot.isServerRunning {
                    Text(verbatim: "localhost:\(viewModel.config.port)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            accountsBlock

            if snapshot.erroredCount > 0 {
                Text("\(snapshot.erroredCount) error\(snapshot.erroredCount == 1 ? "" : "s")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(BrandPalette.statusError)
            }
        }
    }

    private var ledState: StatusLED.State {
        switch snapshot.indicatorState {
        case .running: return .running
        case .stopped: return .stopped
        case .error: return .error
        }
    }

    private var statusLabel: String {
        snapshot.statusLabel
    }

    @ViewBuilder
    private var accountsBlock: some View {
        if snapshot.connectedProviders.isEmpty {
            Text(snapshot.emptyProviderMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .italic()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.connectedProviders) { provider in
                    MenuBarAccountRow(provider: provider)
                }
            }
        }
    }

    // MARK: - Separators

    private var menuSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

// MARK: - Account row

private struct MenuBarAccountRow: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ProviderAvatar(providerID: provider.id, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(provider.menuBarDisplayName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: "$ \(provider.functionName)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if let connectionDetail = provider.menuBarConnectionDetail {
                    Text(connectionDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }

                subscriptionUsage
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusLED(state: .running, size: 8, pulse: false)
                .padding(.top, 3)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var subscriptionUsage: some View {
        switch provider.subscriptionUsageState {
        case .disabled, .managementKeyNotConfigured:
            EmptyView()
        case .loading:
            Text("Checking subscription usage…")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        case .unavailable(.proxyUnavailable):
            EmptyView()
        case .unavailable(let issue):
            Text("Usage unavailable — \(issue.message)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .available(let snapshot):
            if snapshot.windows.isEmpty {
                Text("Usage details unavailable")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.windows) { window in
                        usageWindow(window)
                    }
                }
            }
        }
    }

    private func usageWindow(_ window: UsageWindow) -> some View {
        let percent = min(max(window.usedPercent, 0), 100)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                ProgressView(value: percent, total: 100)
                    .tint(subscriptionUsageProgressTone(for: percent).color)
                    .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
                    .frame(minWidth: 96, maxWidth: .infinity)
                    .layoutPriority(1)
                Text("\(Int(percent.rounded()))%")
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10.5, design: .monospaced))

            if let resetAt = window.resetAt {
                Text("Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Menu item row (NSMenu-style hover)

private struct MenuItemRow: View {
    let icon: String?
    let label: String
    var trailing: String? = nil
    var shortcut: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14)
                .foregroundStyle(hovering ? Color.white : Color.secondary)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? Color.white : Color.primary)

                Spacer(minLength: 4)

                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? BrandPalette.accent : Color.clear)
            )
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .onHover { value in
            guard !disabled else { return }
            hovering = value
        }
    }
}
