import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let openMain: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    private var snapshot: MenuBarStatusSnapshot {
        MenuBarStatusSnapshot(
            serverStatus: viewModel.serverStatus,
            providers: viewModel.providerRows,
            port: viewModel.config.port
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBlock
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().padding(.horizontal, 6)

            MenuBarActionRow(
                title: snapshot.serverActionTitle,
                systemImage: snapshot.isServerRunning ? "stop.fill" : "play.fill",
                action: {
                    Task {
                        if snapshot.isServerRunning {
                            await viewModel.stopServer()
                        } else {
                            await viewModel.startServer()
                        }
                    }
                }
            )
            .disabled(viewModel.isServerActionInProgress)

            Divider().padding(.horizontal, 6)

            MenuBarActionRow(title: "Open CLIProxyManager", systemImage: "macwindow", action: openMain)
            MenuBarActionRow(title: "Preferences…", systemImage: "gearshape", shortcut: "⌘ ,", action: openSettings)

            Divider().padding(.horizontal, 6)

            MenuBarActionRow(title: "Quit CLIProxyManager", systemImage: nil, shortcut: "⌘ Q", action: quit)
        }
        .padding(.vertical, 5)
        .frame(width: AppWindowMetrics.menuBarWidth)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(snapshot.isServerRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(snapshot.serverTitle)
                    .font(.headline)
                Spacer()
            }
            accountsBlock
            if let endpointTitle = snapshot.endpointTitle {
                Text(endpointTitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accountsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.connectedProviders.isEmpty {
                Text(snapshot.emptyProviderMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(snapshot.connectedProviders) { provider in
                    HStack(spacing: 8) {
                        ProviderMiniMark(providerID: provider.id)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name)
                                .font(.caption.weight(.medium))
                            Text("$ \(provider.functionName)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

private struct MenuBarActionRow: View {
    let title: String
    let systemImage: String?
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let systemImage {
                        Image(systemName: systemImage)
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

                Text(title)
                    .font(.caption)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderMiniMark: View {
    let providerID: ProviderRowState.ID

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay {
                Text(mark)
                    .font(.system(size: providerID == .codex ? 7 : 10, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private var mark: String {
        switch providerID {
        case .claude:
            "A"
        case .codex:
            "<>"
        }
    }

    private var color: Color {
        switch providerID {
        case .claude:
            Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:
            Color.black
        }
    }
}
