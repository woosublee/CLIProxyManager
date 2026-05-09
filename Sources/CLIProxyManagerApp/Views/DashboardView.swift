import CLIProxyManagerCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let openSettings: () -> Void
    let quit: () -> Void
    @State private var activeProvider: ProviderRowState.ID?

    private var preferredHeight: CGFloat {
        min(
            AppWindowMetrics.mainMaxHeight,
            300 + CGFloat(max(viewModel.providerRows.count, 1)) * 64 + (viewModel.settingsMessage == nil ? 0 : 24)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ServerHeroView(
                        status: viewModel.serverStatus,
                        port: viewModel.config.port,
                        isActionInProgress: viewModel.isServerActionInProgress,
                        toggleAction: { isOn in Task { await viewModel.setServerEnabled(isOn) } }
                    )

                    accountsHeader

                    ForEach(viewModel.providerRows.map { DashboardAccountSnapshot(provider: $0) }) { account in
                        ProviderAccountCardView(
                            account: account,
                            connect: { Task { await viewModel.connectProvider(account.id) } },
                            settings: { activeProvider = account.id },
                            disconnect: { viewModel.disconnectProvider(account.id) }
                        )
                    }

                    Button {
                        viewModel.addProvider()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.secondary)
                            Text("Add provider")
                                .font(.callout.weight(.medium))
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.primary.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }

                    if let message = viewModel.settingsMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }

            Divider()

            HStack {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit ⌘Q", action: quit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(12)
        }
        .task {
            await viewModel.refresh()
        }
        .frame(width: AppWindowMetrics.mainWidth, height: preferredHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(item: $activeProvider) { provider in
            providerSettingsSheet(provider)
        }
    }

    private var accountsHeader: some View {
        HStack {
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(viewModel.providerRows.filter(\.isConnected).count) connected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerSettingsSheet(_ provider: ProviderRowState.ID) -> some View {
        switch provider {
        case .claude:
            ClaudeOAuthProviderSettingsSheet(config: viewModel.config) { functionName, dangerousPermissionsEnabled in
                try viewModel.saveClaudeOAuthSettings(functionName: functionName, dangerousPermissionsEnabled: dangerousPermissionsEnabled)
            }
        case .codex:
            CodexProviderSettingsSheet(
                config: viewModel.config,
                availableModels: viewModel.availableCodexModels,
                refreshModels: { Task { await viewModel.loadCodexModels() } },
                save: { functionName, codex, dangerousPermissionsEnabled in
                    try viewModel.saveCodexSettings(
                        functionName: functionName,
                        codex: codex,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled
                    )
                }
            )
        }
    }
}

private struct ServerHeroView: View {
    let status: DiagnosticStatus
    let port: Int
    let isActionInProgress: Bool
    let toggleAction: (Bool) -> Void

    private var isRunning: Bool { status.severity == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Server", systemImage: "server.rack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        StatusLED(severity: status.severity)
                        Text(statusTitle)
                            .font(.title3.weight(.semibold))
                    }
                }

                Spacer()

                Toggle("Server", isOn: Binding(
                    get: { isRunning },
                    set: { toggleAction($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isActionInProgress)
            }

            if isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text("http://localhost:\(port)")
                        .font(.caption.monospaced())
                    Spacer()
                    Image(systemName: "doc.on.doc")
                }
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14, opacity: isRunning ? 0.10 : 0.06)
        .overlay(alignment: .topTrailing) {
            if isRunning {
                Circle()
                    .fill(.green.opacity(0.16))
                    .frame(width: 140, height: 140)
                    .blur(radius: 32)
                    .offset(x: 42, y: -58)
            }
        }
    }

    private var statusTitle: String {
        switch status.severity {
        case .ready:
            "Running"
        case .warning:
            isActionInProgress ? "Working" : "Stopped"
        case .error:
            "Error"
        }
    }
}

private struct ProviderAccountCardView: View {
    let account: DashboardAccountSnapshot
    let connect: () -> Void
    let settings: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            providerMark

            VStack(alignment: .leading, spacing: 4) {
                Text(account.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text("$")
                        .foregroundStyle(.blue)
                        .fontWeight(.bold)
                    Text(account.commandName)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                HStack(spacing: 6) {
                    StatusLED(severity: account.status == .connected ? .ready : .warning, size: 6)
                    Text(account.status == .connected ? account.detail : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if account.status == .connected {
                Button(action: settings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                Menu {
                    Button("Settings", action: settings)
                    Button("Disconnect", action: disconnect)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
            } else {
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12, opacity: 0.05)
    }

    private var providerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(markColor)
            Text(account.title.prefix(1))
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }

    private var markColor: Color {
        switch account.id {
        case .claude:
            Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:
            Color(red: 0.06, green: 0.64, blue: 0.50)
        }
    }
}

private struct StatusLED: View {
    let severity: DiagnosticSeverity
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(severity == .ready ? 0.6 : 0), radius: 4)
    }

    private var color: Color {
        switch severity {
        case .ready:
            .green
        case .warning:
            .gray
        case .error:
            .red
        }
    }
}
