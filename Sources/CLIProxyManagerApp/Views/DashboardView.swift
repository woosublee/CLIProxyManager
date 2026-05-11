import CLIProxyManagerCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let openSettings: () -> Void
    let quit: () -> Void
    @State private var activeProvider: ProviderRowState.ID?
    @State private var copiedEndpoint: Bool = false
    @State private var showAddProvider: Bool = false
    @State private var initialSetupProvider: ProviderRowState.ID?

    private var preferredHeight: CGFloat {
        min(
            AppWindowMetrics.mainMaxHeight,
            300 + CGFloat(max(viewModel.providerRows.count, 1)) * 88 + (viewModel.settingsMessage == nil ? 0 : 32)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ServerHeroView(
                        controlState: viewModel.serverControlState,
                        statusMessage: viewModel.serverStatus.message,
                        port: viewModel.config.port,
                        isActionInProgress: viewModel.isServerActionInProgress,
                        copied: copiedEndpoint,
                        toggleAction: { isOn in
                            Task {
                                await viewModel.setServerEnabled(isOn)
                            }
                        },
                        copyEndpoint: copyEndpointToPasteboard
                    )
                    .padding(.bottom, 8)

                    SectionHeader(
                        title: "Accounts",
                        trailing: "\(viewModel.providerRows.filter(\.isConnected).count) connected"
                    )

                    ForEach(viewModel.providerRows.map { DashboardAccountSnapshot(provider: $0) }) { account in
                        ProviderAccountCardView(
                            account: account,
                            connect: { Task { await viewModel.connectProvider(account.id) } },
                            settings: { activeProvider = account.id },
                            disconnect: { viewModel.disconnectProvider(account.id) },
                            remove: { viewModel.removeProvider(account.id) }
                        )
                    }

                    AddProviderCard {
                        showAddProvider = true
                    }
                    .padding(.top, 4)

                    if let message = viewModel.settingsMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }

            Divider()

            footer
        }
        .task {
            await viewModel.refresh()
            await viewModel.performAutostartIfEnabled()
        }
        .frame(width: AppWindowMetrics.mainWidth, height: preferredHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(item: $activeProvider) { provider in
            providerSettingsSheet(provider)
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderModal { provider in
                Task {
                    await viewModel.connectProvider(provider)
                    // After OAuth, if a connected row appeared, open the settings sheet
                    // so the user can finalize nickname / command name / Codex routing.
                    if viewModel.providerRows.contains(where: { $0.id == provider && $0.isConnected }) {
                        initialSetupProvider = provider
                        activeProvider = provider
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: openSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                    Text("Open Settings")
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Spacer()

            Button(action: quit) {
                HStack(spacing: 6) {
                    Text("Quit")
                    Text("⌘Q")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func copyEndpointToPasteboard() {
        let url = "http://localhost:\(viewModel.config.port)"
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #endif
        withAnimation(.easeInOut(duration: 0.18)) { copiedEndpoint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.18)) { copiedEndpoint = false }
        }
    }

    @ViewBuilder
    private func providerSettingsSheet(_ provider: ProviderRowState.ID) -> some View {
        let row = viewModel.providerRows.first { $0.id == provider }
        let isInitial = initialSetupProvider == provider
        switch provider {
        case .claude:
            ClaudeOAuthProviderSettingsSheet(
                config: viewModel.config,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                onDisconnect: {
                    viewModel.removeProvider(.claude)
                    initialSetupProvider = nil
                },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: .claude, functionName: functionName)
                },
                onCancel: {
                    if isInitial {
                        viewModel.removeProvider(.claude)
                    }
                    initialSetupProvider = nil
                },
                isInitialSetup: isInitial,
                save: { functionName, nickname, dangerousPermissionsEnabled in
                    try viewModel.saveClaudeOAuthSettings(
                        functionName: functionName,
                        nickname: nickname,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled
                    )
                    initialSetupProvider = nil
                }
            )
        case .codex:
            CodexProviderSettingsSheet(
                config: viewModel.config,
                connectionDetail: row?.connectionDetail ?? "",
                isConnected: row?.isConnected ?? false,
                availableModels: viewModel.availableCodexModels,
                refreshModels: { Task { await viewModel.loadCodexModels() } },
                onDisconnect: {
                    viewModel.removeProvider(.codex)
                    initialSetupProvider = nil
                },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: .codex, functionName: functionName)
                },
                onCancel: {
                    if isInitial {
                        viewModel.removeProvider(.codex)
                    }
                    initialSetupProvider = nil
                },
                isInitialSetup: isInitial,
                latestModel: { viewModel.latestBaseCodexModel },
                save: { functionName, nickname, codex, dangerousPermissionsEnabled in
                    try viewModel.saveCodexSettings(
                        functionName: functionName,
                        nickname: nickname,
                        codex: codex,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled
                    )
                    initialSetupProvider = nil
                }
            )
        }
    }
}

// MARK: - Server Hero

private struct ServerHeroView: View {
    let controlState: ServerControlState
    let statusMessage: String
    let port: Int
    let isActionInProgress: Bool
    let copied: Bool
    let toggleAction: (Bool) -> Void
    let copyEndpoint: () -> Void

    private var isRunning: Bool { controlState == .running }
    private var isTransitioning: Bool { controlState.isTransitioning }
    // Toggle position should reflect intent during transitions, otherwise actual state.
    private var toggleOn: Bool {
        switch controlState {
        case .running, .starting: return true
        case .stopped, .stopping: return false
        case .error: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10, weight: .semibold))
                        Text("SERVER")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        StatusLED(state: ledState, size: 10)
                        if isTransitioning {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(statusTitle)
                            .font(.system(size: 17, weight: .bold))
                    }
                }

                Spacer()

                Toggle("Server", isOn: Binding(
                    get: { toggleOn },
                    set: { toggleAction($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BrandPalette.statusRunning)
                .controlSize(.large)
                .disabled(isTransitioning)
            }

            if isRunning {
                Button(action: copyEndpoint) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 12, height: 12, alignment: .center)
                        Text(verbatim: "http://localhost:\(port)")
                            .font(.system(size: 11.5, design: .monospaced))
                        Spacer(minLength: 4)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 12, height: 12, alignment: .center)
                            .foregroundStyle(copied ? BrandPalette.statusRunning : .secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            } else if !isTransitioning, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isErrorState ? BrandPalette.statusError : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isRunning ? BrandPalette.statusRunning.opacity(0.30) : Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .background(
            // Subtle green wash in the top-right when running
            ZStack {
                if isRunning {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [BrandPalette.statusRunning.opacity(0.18), .clear],
                                center: .topTrailing,
                                startRadius: 0,
                                endRadius: 220
                            )
                        )
                }
            }
        )
    }

    private var isErrorState: Bool {
        if case .error = controlState { return true }
        return false
    }

    private var ledState: StatusLED.State {
        switch controlState {
        case .running, .starting:
            return .running
        case .stopping, .stopped:
            return .stopped
        case .error:
            return .error
        }
    }

    private var statusTitle: String {
        switch controlState {
        case .stopped:    return "Stopped"
        case .starting:   return "Starting"
        case .running:    return "Running"
        case .stopping:   return "Stopping"
        case .error:      return "Error"
        }
    }
}

// MARK: - Account card

private struct ProviderAccountCardView: View {
    let account: DashboardAccountSnapshot
    let connect: () -> Void
    let settings: () -> Void
    let disconnect: () -> Void
    let remove: () -> Void
    @State private var hovering: Bool = false
    @State private var confirmRemove: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderAvatar(providerID: account.id)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                SlugPill(slug: account.commandName)

                HStack(spacing: 6) {
                    StatusLED(state: account.status == .connected ? .running : .stopped, size: 6, pulse: false)
                    Text(account.status == .connected ? account.detail : "Disconnected")
                        .font(.system(size: 11))
                        .foregroundStyle(account.status == .connected ? .secondary : .tertiary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 4)

            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .alert("Remove this account?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("The auth profile will be deleted from CLIProxyAPI. You can reconnect at any time via Add provider.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if account.status == .connected {
            HStack(spacing: 4) {
                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1.0 : 0.55)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "power")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove account", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
            }
        } else {
            HStack(spacing: 4) {
                Button(action: connect) {
                    Text("Connect")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(BrandPalette.accent)
                        )
                }
                .buttonStyle(.plain)

                Menu {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove account", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
            }
        }
    }

}

// MARK: - Add provider card

private struct AddProviderCard: View {
    let action: () -> Void
    @State private var hovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)

                Text("Add provider")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hovering ? BrandPalette.accent.opacity(0.7) : Color.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
