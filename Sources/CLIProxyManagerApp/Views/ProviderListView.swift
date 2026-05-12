import SwiftUI

struct ProviderListView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var activeProvider: ProviderRowState.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Providers")
                    .font(.title2.bold())
                Spacer()
                Button {
                    viewModel.addProvider()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add provider")
            }

            VStack(spacing: 10) {
                ForEach(viewModel.providerRows) { provider in
                    ProviderRowView(
                        provider: provider,
                        connect: { connect(provider.id) },
                        disconnect: { disconnect(provider.id) },
                        settings: { activeProvider = provider.id }
                    )
                }
            }
        }
        .padding(24)
        .settingsToast(message: viewModel.settingsMessage, dismiss: viewModel.clearSettingsMessage)
        .sheet(item: $activeProvider) { provider in
            providerSettingsSheet(provider)
        }
    }

    private func connect(_ provider: ProviderRowState.ID) {
        viewModel.startOAuthLogin(provider)
    }

    private func disconnect(_ provider: ProviderRowState.ID) {
        viewModel.disconnectProvider(provider)
    }

    @ViewBuilder
    private func providerSettingsSheet(_ provider: ProviderRowState.ID) -> some View {
        switch provider {
        case .claude:
            let row = viewModel.providerRows.first { $0.id == .claude }
            ClaudeOAuthProviderSettingsSheet(
                config: viewModel.config,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                onDisconnect: { viewModel.disconnectProvider(.claude) },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: .claude, functionName: functionName)
                },
                save: { functionName, nickname, dangerousPermissionsEnabled in
                    try viewModel.saveClaudeOAuthSettings(
                        functionName: functionName,
                        nickname: nickname,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled
                    )
                }
            )
        case .codex:
            let row = viewModel.providerRows.first { $0.id == .codex }
            CodexProviderSettingsSheet(
                config: viewModel.config,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                availableModels: viewModel.availableCodexModels,
                modelLoadingState: viewModel.codexModelLoadingState,
                refreshModels: { Task { await viewModel.refreshCodexModels() } },
                onDisconnect: { viewModel.disconnectProvider(.codex) },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: .codex, functionName: functionName)
                },
                save: { functionName, nickname, codex, dangerousPermissionsEnabled in
                    try viewModel.saveCodexSettings(
                        functionName: functionName,
                        nickname: nickname,
                        codex: codex,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled
                    )
                }
            )
        }
    }
}

private struct ProviderRowView: View {
    let provider: ProviderRowState
    let connect: () -> Void
    let disconnect: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name)
                    .font(.headline)
                Text(provider.connectionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(provider.connectionTitle)
                    .foregroundStyle(provider.isConnected ? .green : .orange)
                Text(provider.functionName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if provider.isConnected {
                Button("Disconnect", action: disconnect)
            } else {
                Button("Connect", action: connect)
            }
            Button("Settings", action: settings)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension ProviderRowState.ID: Identifiable {
    var id: String { rawValue }
}
