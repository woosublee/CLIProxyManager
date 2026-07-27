import CLIProxyManagerCore
import SwiftUI
import UniformTypeIdentifiers

enum DashboardSheet: Identifiable, Equatable {
    case addProvider
    case newAPIKey(AppConfig.APIKeyProfile)
    case providerSettings(ProviderRowState.ID, isInitialSetup: Bool)

    var id: String {
        switch self {
        case .addProvider:
            "add-provider"
        case .newAPIKey(let profile):
            "new-api-key-\(profile.id)"
        case let .providerSettings(provider, isInitialSetup):
            "provider-settings-\(provider.rawValue)-initial-\(isInitialSetup)"
        }
    }

    static func afterOAuthLoginCompletion(_ provider: ProviderRowState.ID, isInitialSetup: Bool) -> DashboardSheet {
        .providerSettings(provider, isInitialSetup: isInitialSetup)
    }
}

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    let openSettings: () -> Void
    let quit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var activeSheet: DashboardSheet?
    @State private var activeDropIndex: Int?
    @State private var draggingAccountID: ProviderRowState.ID?
    @State private var previewAccountIDs: [ProviderRowState.ID]?
    @State private var accountFrames: [ProviderRowState.ID: CGRect] = [:]
    @State private var copiedEndpoint: Bool = false
    @State private var showCLIProxyAPIUpdatePrompt = false
    @State private var showCLIProxyAPIApplyPrompt = false

    private var preferredHeight: CGFloat {
        min(
            AppWindowMetrics.mainMaxHeight,
            300 + CGFloat(max(viewModel.providerRows.count, 1)) * 88
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

                    let sourceAccounts = viewModel.providerRows.map { DashboardAccountSnapshot(provider: $0) }
                    let accountsByID = Dictionary(
                        sourceAccounts.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let accountIDs = previewAccountIDs ?? sourceAccounts.map(\.id)
                    let accounts = accountIDs.compactMap { accountsByID[$0] }
                    VStack(spacing: 6) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            ProviderAccountCardView(
                                account: account,
                                canReorder: accounts.count > 1,
                                isDropTarget: activeDropIndex == index,
                                isDragging: draggingAccountID == account.id,
                                dragStarted: {
                                    beginAccountDrag(account.id, sourceIDs: sourceAccounts.map(\.id))
                                },
                                connect: {
                                    if account.isAPIKeyProfile {
                                        openProviderSettings(account.id, isInitialSetup: false)
                                    } else {
                                        activeSheet = .addProvider
                                        viewModel.startOAuthLogin(account.id)
                                    }
                                },
                                settings: { openProviderSettings(account.id, isInitialSetup: false) },
                                toggleUsageOverlayVisibility: {
                                    viewModel.saveSetting {
                                        try viewModel.setAccountVisibleInUsageOverlay(
                                            account.id,
                                            isVisible: !account.showsInUsageOverlay
                                        )
                                    }
                                },
                                toggleAccountDetailVisibility: { viewModel.toggleAccountDetailVisibility(account.id) },
                                setEnabled: { enabled in viewModel.setProviderEnabled(account.id, enabled: enabled) },
                                moveUp: { viewModel.moveAccountUp(account.id) },
                                moveDown: { viewModel.moveAccountDown(account.id) },
                                canMoveUp: viewModel.canMoveAccountUp(account.id),
                                canMoveDown: viewModel.canMoveAccountDown(account.id),
                                remove: {
                                    if account.isAPIKeyProfile {
                                        viewModel.removeAPIProvider(account.id)
                                    } else {
                                        viewModel.removeProvider(account.id)
                                    }
                                }
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: AccountFramePreferenceKey.self,
                                        value: [account.id: proxy.frame(in: .named("account-list"))]
                                    )
                                }
                            )
                        }
                    }
                    .coordinateSpace(name: "account-list")
                    .onPreferenceChange(AccountFramePreferenceKey.self) { accountFrames = $0 }
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.plainText],
                        delegate: AccountReorderDropDelegate(
                            activeDropIndex: $activeDropIndex,
                            draggingAccountID: $draggingAccountID,
                            previewAccountIDs: $previewAccountIDs,
                            sourceAccountIDs: sourceAccounts.map(\.id),
                            accountFrames: accountFrames,
                            moveAccount: viewModel.moveAccount
                        )
                    )
                    .animation(
                        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
                        value: accountIDs
                    )

                    AddProviderCard {
                        activeSheet = .addProvider
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            }

            Divider()

            footer
        }
        .task {
            await viewModel.openMainWindow()
            let automaticCheckResult = await cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()
            switch automaticCheckResult {
            case .availableUpdate:
                showCLIProxyAPIUpdatePrompt = true
            case .pendingUpdate:
                showCLIProxyAPIApplyPrompt = true
            case .none:
                break
            }
        }
        .frame(width: AppWindowMetrics.mainWidth, height: preferredHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .settingsToast(message: viewModel.settingsMessage, dismiss: viewModel.clearSettingsMessage)
        .onChange(of: viewModel.providerRows.map(\.id)) { _, accountIDs in
            draggingAccountID = nil
            previewAccountIDs = nil
            activeDropIndex = nil
            accountFrames = accountFrames.filter { accountIDs.contains($0.key) }
        }
        .confirmationDialog(
            cliProxyAPIAvailableUpdatePromptTitle(currentVersion: cliProxyAPIUpdateService.currentVersionText,
                                                  availableUpdate: cliProxyAPIUpdateService.availableUpdate),
            isPresented: $showCLIProxyAPIUpdatePrompt,
            titleVisibility: .visible
        ) {
            // Available updates use a Download button title with the target version.
            Button(cliproxyAPIUpdateActionTitle(
                state: cliProxyAPIUpdateService.state,
                availableUpdate: cliProxyAPIUpdateService.availableUpdate,
                pendingUpdate: nil
            )) {
                Task {
                    await cliProxyAPIUpdateService.downloadAvailableUpdate()
                    if cliProxyAPIUpdateService.pendingUpdate != nil {
                        showCLIProxyAPIApplyPrompt = true
                    } else if case let .failed(message) = cliProxyAPIUpdateService.state {
                        viewModel.settingsMessage = "CLIProxyAPI update failed: \(message)"
                    }
                }
            }
            Button("Later", role: .cancel) {
                cliProxyAPIUpdateService.deferAvailableUpdate()
            }
        }
        .confirmationDialog(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: cliProxyAPIUpdateService.pendingUpdate),
            isPresented: $showCLIProxyAPIApplyPrompt,
            titleVisibility: .visible
        ) {
            Button(cliProxyAPIApplyButtonTitle(
                pendingUpdate: cliProxyAPIUpdateService.pendingUpdate,
                isServerRunning: viewModel.serverControlState.isRunning
            )) {
                Task { await viewModel.applyCLIProxyAPIPendingUpdate(using: cliProxyAPIUpdateService) }
            }
            Button("Apply on next server start") {
                if cliProxyAPIUpdateService.schedulePendingForNextServerStart() {
                    viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
                } else if case let .failed(message) = cliProxyAPIUpdateService.state {
                    viewModel.settingsMessage = "CLIProxyAPI update failed: \(message)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cliProxyAPIPendingUpdatePromptMessage(currentVersion: cliProxyAPIUpdateService.currentVersionText))
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .addProvider:
                    AddProviderModal(
                        activeOAuthLoginProvider: viewModel.activeOAuthLoginProvider,
                        onPick: { choice in
                            switch choice {
                            case .oauth(let provider):
                                viewModel.startOAuthLogin(providerType: provider)
                            case .apiKey(let provider):
                                activeSheet = .newAPIKey(viewModel.newAPIKeyProfile(provider: provider))
                            }
                        },
                        onCancelLogin: {
                            viewModel.cancelOAuthLogin()
                        }
                    )
                case .newAPIKey(let profile):
                    apiKeySettingsSheet(profile: profile, isInitialSetup: true)
                case let .providerSettings(provider, isInitialSetup):
                    providerSettingsSheet(provider, isInitialSetup: isInitialSetup)
                }
            }
            .onChange(of: viewModel.activeOAuthLoginProvider) { _, provider in
                guard provider == nil, let connectedProvider = viewModel.completedOAuthLoginProvider else { return }
                openProviderSettings(
                    connectedProvider,
                    isInitialSetup: viewModel.completedOAuthLoginIsInitialSetup
                )
            }
            .onDisappear {
                if viewModel.activeOAuthLoginProvider != nil {
                    viewModel.cancelOAuthLogin()
                }
            }
            .settingsToast(message: viewModel.settingsMessage, dismiss: viewModel.clearSettingsMessage)
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

    private func beginAccountDrag(_ id: ProviderRowState.ID, sourceIDs: [ProviderRowState.ID]) {
        draggingAccountID = id
        previewAccountIDs = sourceIDs
        activeDropIndex = sourceIDs.firstIndex(of: id)
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

    private func openProviderSettings(_ provider: ProviderRowState.ID, isInitialSetup: Bool) {
        Task {
            if let profile = viewModel.apiKeyProfile(id: provider.rawValue) {
                if profile.provider == .claude {
                    await viewModel.prepareClaudeModels(for: provider)
                } else {
                    await viewModel.prepareCodexAPIModels(for: provider)
                }
            } else if provider.inferredProviderType == .claude {
                await viewModel.prepareClaudeModels(for: provider)
            }
            activeSheet = .providerSettings(provider, isInitialSetup: isInitialSetup)
        }
    }

    @ViewBuilder
    private func providerSettingsSheet(_ provider: ProviderRowState.ID, isInitialSetup: Bool) -> some View {
        let row = viewModel.providerRows.first { $0.id == provider }
        let providerType = row?.providerType ?? provider.inferredProviderType

        if let profile = viewModel.apiKeyProfile(id: provider.rawValue) {
            apiKeySettingsSheet(profile: profile, isInitialSetup: isInitialSetup)
        } else {
            switch providerType {
            case .claude:
                ClaudeOAuthProviderSettingsSheet(
                    config: viewModel.config,
                    providerID: provider,
                    connectionDetail: row?.connectionDetail ?? "",
                    isConnected: row?.isConnected ?? false,
                    onDisconnect: {
                        viewModel.removeProvider(provider)
                        activeSheet = nil
                    },
                    initialModels: viewModel.availableClaudeModelOptionsByProvider[provider] ?? [],
                    checkCommandName: { functionName in
                        await viewModel.commandNameAvailability(provider: provider, functionName: functionName)
                    },
                    refreshModels: {
                        try await viewModel.claudeModels(for: provider)
                    },
                    onCancel: {
                        if isInitialSetup {
                            viewModel.removeInitialProvider(provider)
                        }
                        activeSheet = nil
                    },
                    isInitialSetup: isInitialSetup,
                    save: { functionName, nickname, dangerousPermissionsEnabled, connectionMode, claudeRouting in
                        try viewModel.saveClaudeOAuthSettings(
                            provider: provider,
                            functionName: functionName,
                            nickname: nickname,
                            dangerousPermissionsEnabled: dangerousPermissionsEnabled,
                            connectionMode: connectionMode,
                            claudeRouting: claudeRouting
                        )
                        activeSheet = nil
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
                    onDisconnect: {
                        viewModel.removeProvider(provider)
                        activeSheet = nil
                    },
                    checkCommandName: { functionName in
                        await viewModel.commandNameAvailability(provider: provider, functionName: functionName)
                    },
                    onCancel: {
                        if isInitialSetup {
                            viewModel.removeInitialProvider(provider)
                        }
                        activeSheet = nil
                    },
                    isInitialSetup: isInitialSetup,
                    preferredModel: { viewModel.preferredCodexDefaultModel(in: $0) },
                    save: { functionName, nickname, codex, dangerousPermissionsEnabled in
                        try viewModel.saveCodexSettings(
                            provider: provider,
                            functionName: functionName,
                            nickname: nickname,
                            codex: codex,
                            dangerousPermissionsEnabled: dangerousPermissionsEnabled
                        )
                        activeSheet = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func apiKeySettingsSheet(
        profile: AppConfig.APIKeyProfile,
        isInitialSetup: Bool
    ) -> some View {
        let providerID = ProviderRowState.ID(rawValue: profile.id)
        let isNewProfile = viewModel.apiKeyProfile(id: profile.id) == nil
        let isConfigured = viewModel.isAPIKeyConfigured(profile.secretReference)

        switch profile.provider {
        case .claude:
            ClaudeAPIProviderSettingsSheet(
                profile: profile,
                isConfigured: isConfigured,
                isNewProfile: isNewProfile,
                initialModels: viewModel.availableClaudeModelOptionsByProvider[providerID] ?? [],
                refreshModels: {
                    guard !isNewProfile else { return [] }
                    return try await viewModel.claudeAPIModels(for: providerID)
                },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: providerID, functionName: functionName)
                },
                save: { functionName, nickname, claudeRouting, dangerousPermissionsEnabled, key in
                    try viewModel.saveClaudeAPISettings(
                        profileID: profile.id,
                        secretReference: profile.secretReference,
                        functionName: functionName,
                        nickname: nickname,
                        claudeRouting: claudeRouting,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled,
                        key: key
                    )
                    activeSheet = nil
                },
                remove: {
                    viewModel.removeAPIProvider(providerID)
                    activeSheet = nil
                }
            )
        case .codex:
            let initialModels = isNewProfile
                ? CodexAPIModelOptions.newProfileModels
                : viewModel.availableCodexAPIModelOptionsByProvider[providerID] ?? []
            CodexAPIProviderSettingsSheet(
                profile: profile,
                isConfigured: isConfigured,
                isNewProfile: isNewProfile,
                availableModels: initialModels,
                modelLoadingState: viewModel.codexModelLoadingState,
                refreshModels: {
                    guard !isNewProfile else { return CodexAPIModelOptions.newProfileModels }
                    return try await viewModel.refreshCodexAPIModels(for: providerID)
                },
                preferredModel: { viewModel.preferredCodexDefaultModel(in: $0) },
                checkCommandName: { functionName in
                    await viewModel.commandNameAvailability(provider: providerID, functionName: functionName)
                },
                save: { functionName, nickname, codex, dangerousPermissionsEnabled, key in
                    try viewModel.saveCodexAPISettings(
                        profileID: profile.id,
                        secretReference: profile.secretReference,
                        functionName: functionName,
                        nickname: nickname,
                        codex: codex,
                        dangerousPermissionsEnabled: dangerousPermissionsEnabled,
                        key: key
                    )
                    activeSheet = nil
                },
                remove: {
                    viewModel.removeAPIProvider(providerID)
                    activeSheet = nil
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

            if !isRunning, !isTransitioning, !statusMessage.isEmpty {
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

struct ProviderAccountCardView: View {
    let account: DashboardAccountSnapshot
    let canReorder: Bool
    let isDropTarget: Bool
    let isDragging: Bool
    let dragStarted: () -> Void
    let connect: () -> Void
    let settings: () -> Void
    let toggleUsageOverlayVisibility: () -> Void
    let toggleAccountDetailVisibility: () -> Void
    let setEnabled: (Bool) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let remove: () -> Void
    @State private var hovering: Bool = false
    @State private var confirmRemove: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dragHandle
                .frame(maxHeight: .infinity, alignment: .center)

            ProviderAvatar(providerID: account.id, providerType: account.providerType)
                .frame(maxHeight: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    trailingControls
                        .layoutPriority(1)
                }

                accountDetailRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isDropTarget
                        ? BrandPalette.accent.opacity(0.10)
                        : Color.primary.opacity(hovering ? 0.07 : 0.04)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule()
                    .fill(BrandPalette.accent)
                    .frame(height: 3)
                    .padding(.horizontal, 8)
                    .offset(y: -4.5)
            }
        }
        .opacity(isDragging ? 0.12 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .alert("Remove this account?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("The auth profile will be deleted from CLIProxyAPI. You can reconnect at any time via Add provider.")
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            SlugPill(slug: account.commandName)

            actions
        }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 28)
            .contentShape(Rectangle())
            .onDrag {
                dragStarted()
                return NSItemProvider(object: account.id.rawValue as NSString)
            } preview: {
                ProviderAccountDragPreview(account: account)
            }
            .disabled(!canReorder)
            .opacity(canReorder ? 1 : 0.35)
            .accessibilityLabel("Reorder account")
            .accessibilityHint("Change the position of \(account.title) in the account list")
    }

    private var accountDetailAccessibilityLabel: String {
        if account.status == .connected,
           account.isAccountDetailHidden,
           account.showsAccountPrivacyToggle {
            return "Account detail hidden"
        }
        switch account.status {
        case .connected:
            return account.detail
        case .disabled:
            return "Disabled"
        case .disconnected:
            return "Disconnected"
        }
    }

    private var accountDetailRow: some View {
        HStack(spacing: 6) {
            StatusLED(state: account.status == .connected ? .running : .stopped, size: 6, pulse: false)
            Text(account.status == .connected ? account.detail : account.status == .disabled ? "Disabled" : "Disconnected")
                .font(.system(size: 11))
                .foregroundStyle(account.status == .connected ? .secondary : .tertiary)
                .lineLimit(1)
                .blur(radius: account.status == .connected && account.isAccountDetailHidden && account.showsAccountPrivacyToggle ? 4 : 0)
                .animation(.easeInOut(duration: 0.16), value: account.isAccountDetailHidden)
                .accessibilityLabel(accountDetailAccessibilityLabel)

            if account.showsAccountPrivacyToggle {
                Button(action: toggleAccountDetailVisibility) {
                    Image(systemName: account.isAccountDetailHidden ? "eye.slash" : "eye")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(account.accountPrivacyToggleAccessibilityLabel)
            }
        }
    }

    private var usageOverlayButton: some View {
        let presentation = account.usageOverlayButtonPresentation
        return Button(action: toggleUsageOverlayVisibility) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(
                    presentation.isHighlighted
                        ? BrandPalette.accent
                        : Color.primary.opacity(hovering ? 0.65 : 0.38)
                )
        }
        .buttonStyle(.plain)
        .help(presentation.accessibilityLabel)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var actions: some View {
        if account.status == .connected {
            HStack(spacing: 4) {
                usageOverlayButton

                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1.0 : 0.55)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Move Up", action: moveUp)
                        .disabled(!canMoveUp)
                    Button("Move Down", action: moveDown)
                        .disabled(!canMoveDown)
                    Divider()
                    if !account.isAPIKeyProfile {
                        Button {
                            setEnabled(false)
                        } label: {
                            Label("Disable account", systemImage: "power")
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label(account.isAPIKeyProfile ? "Remove API key profile" : "Remove account", systemImage: "trash")
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
        } else if account.status == .disabled {
            HStack(spacing: 4) {
                usageOverlayButton

                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1.0 : 0.55)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Move Up", action: moveUp)
                        .disabled(!canMoveUp)
                    Button("Move Down", action: moveDown)
                        .disabled(!canMoveDown)
                    Divider()
                    Button {
                        setEnabled(true)
                    } label: {
                        Label("Enable account", systemImage: "power")
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
                usageOverlayButton

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
                    Button("Move Up", action: moveUp)
                        .disabled(!canMoveUp)
                    Button("Move Down", action: moveDown)
                        .disabled(!canMoveDown)
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
        }
    }

}

private struct ProviderAccountDragPreview: View {
    let account: DashboardAccountSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            ProviderAvatar(providerID: account.id, providerType: account.providerType)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    SlugPill(slug: account.commandName)
                }

                Text(account.status == .connected ? account.detail : account.status == .disabled ? "Disabled" : "Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: AppWindowMetrics.mainWidth - 28)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandPalette.accent.opacity(0.5), lineWidth: 1)
        }
        .compositingGroup()
        .opacity(0.68)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 7)
    }
}

private struct AccountFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ProviderRowState.ID: CGRect] = [:]

    static func reduce(
        value: inout [ProviderRowState.ID: CGRect],
        nextValue: () -> [ProviderRowState.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct AccountReorderDropDelegate: DropDelegate {
    @Binding var activeDropIndex: Int?
    @Binding var draggingAccountID: ProviderRowState.ID?
    @Binding var previewAccountIDs: [ProviderRowState.ID]?
    let sourceAccountIDs: [ProviderRowState.ID]
    let accountFrames: [ProviderRowState.ID: CGRect]
    let moveAccount: (ProviderRowState.ID, ProviderRowState.ID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        updatePreview(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(at: info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = draggingAccountID,
              let previewAccountIDs else {
            resetDragState()
            return false
        }

        let previewIDsWithoutDragged = previewAccountIDs.filter { $0 != draggedID }
        let insertionIndex = min(activeDropIndex ?? previewIDsWithoutDragged.count, previewIDsWithoutDragged.count)
        let sourceIDsWithoutDragged = sourceAccountIDs.filter { $0 != draggedID }
        let targetID = insertionIndex < sourceIDsWithoutDragged.count ? sourceIDsWithoutDragged[insertionIndex] : nil
        moveAccount(draggedID, targetID)
        resetDragState()
        return true
    }

    func dropExited(info: DropInfo) {
        activeDropIndex = nil
        previewAccountIDs = sourceAccountIDs
    }

    private func updatePreview(at location: CGPoint) {
        guard let draggedID = draggingAccountID,
              let currentIDs = previewAccountIDs,
              let insertionIndex = AccountOrdering.insertionIndex(
                  for: location.y,
                  orderedIDs: currentIDs,
                  dragging: draggedID,
                  frames: accountFrames
              ) else {
            return
        }

        let sourceIDs = currentIDs.filter { $0 != draggedID }
        let targetID = insertionIndex < sourceIDs.count ? sourceIDs[insertionIndex] : nil
        let updatedIDs = AccountOrdering.moving(currentIDs, id: draggedID, before: targetID)
        activeDropIndex = insertionIndex
        if updatedIDs != currentIDs {
            previewAccountIDs = updatedIDs
        }
    }

    private func resetDragState() {
        activeDropIndex = nil
        draggingAccountID = nil
        previewAccountIDs = nil
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
