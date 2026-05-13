import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let openMain: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

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
                icon: snapshot.isServerRunning ? "stop.fill" : "play.fill",
                label: snapshot.isServerRunning ? "Stop server" : "Start server",
                disabled: viewModel.isServerActionInProgress
            ) {
                Task {
                    if snapshot.isServerRunning {
                        await viewModel.stopServer()
                    } else {
                        await viewModel.startServer()
                    }
                }
            }

            menuSeparator

            MenuItemRow(icon: "macwindow", label: "Open CLIProxyManager", action: openMain)
            MenuItemRow(icon: "gearshape", label: "Preferences…", shortcut: "⌘,", action: openSettings)

            menuSeparator

            MenuItemRow(icon: nil, label: "Quit CLIProxyManager", shortcut: "⌘Q", action: quit)
        }
        .padding(.vertical, 5)
        .frame(width: AppWindowMetrics.menuBarWidth)
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
        HStack(spacing: 9) {
            ProviderAvatar(providerID: provider.id, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "$ \(provider.functionName)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusLED(state: .running, size: 8, pulse: false)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Menu item row (NSMenu-style hover)

private struct MenuItemRow: View {
    let icon: String?
    let label: String
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
