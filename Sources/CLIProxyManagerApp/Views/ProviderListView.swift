import CLIProxyManagerCore
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
                .accessibilityLabel("Add provider")
            }

            VStack(spacing: 10) {
                ForEach(viewModel.providerRows) { provider in
                    ProviderRowView(
                        provider: provider,
                        connect: { connect(provider.id) },
                        setEnabled: { enabled in viewModel.setProviderEnabled(provider.id, enabled: enabled) },
                        settings: { activeProvider = provider.id }
                    )
                }
            }
        }
        .padding(24)
        .settingsToast(message: viewModel.settingsMessage, dismiss: viewModel.clearSettingsMessage)
        .sheet(isPresented: Binding(
            get: { activeProvider != nil },
            set: { isPresented in
                if !isPresented { activeProvider = nil }
            }
        )) {
            if let activeProvider {
                providerSettingsSheet(activeProvider)
            }
        }
    }

    private func connect(_ provider: ProviderRowState.ID) {
        viewModel.startOAuthLogin(provider)
    }

    @ViewBuilder
    private func providerSettingsSheet(_ provider: ProviderRowState.ID) -> some View {
        let row = viewModel.providerRows.first { $0.id == provider }
        let providerType = row?.providerType ?? provider.inferredProviderType
        switch providerType {
        case .claude:
            ClaudeOAuthProviderSettingsSheet(
                config: viewModel.config,
                providerID: provider,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                onDisconnect: { viewModel.disconnectProvider(provider) },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: provider, functionName: functionName)
                },
                refreshModels: {
                    try await viewModel.claudeModels(for: provider)
                },
                save: { functionName, nickname, dangerousPermissionsEnabled, connectionMode, claudeRouting in
                    try viewModel.saveClaudeOAuthSettings(
                        provider: provider,
                        functionName: functionName,
                        nickname: nickname,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled,
                        connectionMode: connectionMode,
                        claudeRouting: claudeRouting
                    )
                }
            )
        case .codex:
            CodexProviderSettingsSheet(
                config: viewModel.config,
                providerID: provider,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                availableModels: viewModel.availableCodexModelOptions,
                modelLoadingState: viewModel.codexModelLoadingState,
                refreshModels: {
                    await viewModel.refreshCodexModels()
                    return try await viewModel.codexModels(for: provider)
                },
                onDisconnect: { viewModel.disconnectProvider(provider) },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: provider, functionName: functionName)
                },
                preferredModel: { viewModel.preferredCodexDefaultModel(in: $0) },
                save: { functionName, nickname, codex, dangerousPermissionsEnabled in
                    try viewModel.saveCodexSettings(
                        provider: provider,
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
    let setEnabled: (Bool) -> Void
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
                    .foregroundStyle(provider.isConnected ? .green : provider.isDisabled ? .secondary : .orange)
                Text(provider.functionName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if provider.isConnected {
                Button("Disable account") {
                    setEnabled(false)
                }
            } else if provider.isDisabled {
                Button("Enable account") {
                    setEnabled(true)
                }
            } else {
                Button("Connect", action: connect)
            }
            Button("Settings", action: settings)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
