import CLIProxyManagerCore
import SwiftUI

// MARK: - Shared sheet chrome

enum ProviderSettingsSheetMetrics {
    static let defaultMinHeight: CGFloat = 360
    static let defaultMaxHeight: CGFloat = 720
    static let codexWidth: CGFloat = 680
    static let codexHeight: CGFloat = 720
    static let claudeHeight: CGFloat = 620
    static let claudeModelPickerWidth: CGFloat = 225
    static let footerActionButtonControlSize = ControlSize.regular
}

enum CodexProviderModelOptions {
    static func modelsAfterGlobalAvailableModelsChange(
        currentScopedModels: [CodexModelOption],
        globalAvailableModels _: [CodexModelOption]
    ) -> [CodexModelOption] {
        currentScopedModels
    }
}

enum CodexAPIModelOptions {
    static func initialModels(
        codex: AppConfig.Codex,
        availableModels: [CodexModelOption]
    ) -> [CodexModelOption] {
        if !availableModels.isEmpty {
            return availableModels
        }
        return baseModels(from: [codex.opus.model, codex.sonnet.model, codex.haiku.model])
            .map { CodexModelOption(id: $0) }
    }

    static func baseModels(from models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let unprefixed = model.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? model
            let baseModel = unprefixed.replacingOccurrences(
                of: #"\((?:auto|low|medium|high|xhigh|max)\)$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalModel = CodexFastMode.canonicalModel(from: baseModel)
            guard !canonicalModel.isEmpty, seen.insert(canonicalModel).inserted else { return nil }
            return canonicalModel
        }
    }

    static func normalized(_ codex: AppConfig.Codex) -> AppConfig.Codex {
        AppConfig.Codex(
            opus: normalized(codex.opus),
            sonnet: normalized(codex.sonnet),
            haiku: normalized(codex.haiku)
        )
    }

    private static func normalized(_ role: AppConfig.CodexRole) -> AppConfig.CodexRole {
        var role = role
        role.model = baseModels(from: [role.model]).first ?? ""
        return role
    }
}

enum CodexAPIInitialDefaults {
    static func shouldApply(isConfigured: Bool, didApply: Bool) -> Bool {
        !isConfigured && !didApply
    }
}

enum CodexProviderModelLoadingPresentation {
    static func isRefreshDisabled(modelLoadingState: CodexModelLoadingState, isReloading: Bool) -> Bool {
        modelLoadingState.isLoading || isReloading
    }

    static func message(modelLoadingState: CodexModelLoadingState, isReloading: Bool) -> String? {
        if isReloading {
            return CodexModelLoadingState.loadingModels.message
        }
        return modelLoadingState.message
    }

    static func isError(modelLoadingState: CodexModelLoadingState, isReloading: Bool) -> Bool {
        isReloading ? false : modelLoadingState.isError
    }
}

private struct AccountSheetChrome<Content: View, Footer: View>: View {
    let providerID: ProviderRowState.ID
    var providerType: AuthProfileType? = nil
    let title: String
    let width: CGFloat
    var minHeight: CGFloat = ProviderSettingsSheetMetrics.defaultMinHeight
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(18)
            }
            Divider()
            footer()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial)
        }
        .frame(width: width)
        .frame(minHeight: minHeight, maxHeight: ProviderSettingsSheetMetrics.defaultMaxHeight)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderAvatar(providerID: providerID, providerType: providerType, size: 28)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

// MARK: - Reusable sheet bits

private struct GroupTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

struct CardRow<Control: View>: View {
    let label: String
    var description: String?
    var warning: String?
    var isLast: Bool = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                    if let description {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning {
                        Text("⚠ \(warning)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.04))
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                control()
                    .padding(.top, 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if !isLast {
                Divider().padding(.leading, 14)
            }
        }
    }
}

private struct ClaudeOAuthConnectionModeSection: View {
    @Binding var connectionMode: AppConfig.ConnectionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupTitle(text: "Connection")
            Picker("Connection", selection: $connectionMode) {
                Text("CLIProxyAPI").tag(AppConfig.ConnectionMode.proxy)
                Text("Direct").tag(AppConfig.ConnectionMode.direct)
            }
            .pickerStyle(.segmented)
            Text(connectionMode == .proxy
                 ? "Routes this registered OAuth account through CLIProxyAPI."
                 : "Runs Claude Code directly with its current official login.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FixedCLIProxyAPIConnectionSection: View {
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupTitle(text: "Connection")
            GroupCard {
                CardRow(label: "CLIProxyAPI", description: description, isLast: true) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BrandPalette.statusRunning)
                }
            }
        }
    }
}

private struct AccountMetaBlock: View {
    let primary: String
    let secondary: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(secondary)
                .font(.system(size: 12))
                .foregroundStyle(isError ? BrandPalette.statusError : .secondary)
        }
    }
}

private struct StyledTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

private enum CommandNameCheckState: Equatable {
    case checking
    case available
    case unavailable(String)

    var isSaveDisabled: Bool {
        switch self {
        case .checking, .unavailable:
            true
        case .available:
            false
        }
    }
}

private struct CommandNameField: View {
    @Binding var value: String
    let checkState: CommandNameCheckState
    var recommendedName: String? = nil

    private var placeholder: String {
        if let recommendedName {
            return "function_name (recommended: \(recommendedName))"
        }
        return "function_name"
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("$")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(BrandPalette.accent)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 0.5),
                    alignment: .trailing
                )
            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 9)
            checkIndicator
                .opacity(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var checkIndicator: some View {
        switch checkState {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandPalette.statusRunning)
        case .unavailable:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandPalette.statusError)
        }
    }
}

private struct SheetFooter: View {
    let removeLabel: String
    let onRemove: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    var saveDisabled: Bool = false

    var body: some View {
        HStack {
            Button(action: onRemove) {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                    Text(removeLabel)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandPalette.statusError)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(ProviderSettingsSheetMetrics.footerActionButtonControlSize)
            Button("Save changes", action: onSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(ProviderSettingsSheetMetrics.footerActionButtonControlSize)
                .disabled(saveDisabled)
        }
    }
}


private struct AccountMeta {
    let primary: String   // email if available, else provider type
    let secondary: String // status line, e.g. "Connected"
    let isError: Bool
}

private func accountMeta(connectionDetail: String, providerName: String, isConnected: Bool) -> AccountMeta {
    let firstLine = connectionDetail
        .split(whereSeparator: { $0.isNewline })
        .first
        .map(String.init) ?? connectionDetail
    let looksLikeEmail = firstLine.contains("@")
    let primary = looksLikeEmail ? firstLine : providerName
    let secondary: String
    if isConnected {
        secondary = looksLikeEmail ? "Connected" : firstLine
    } else {
        secondary = "Disconnected"
    }
    return AccountMeta(primary: primary, secondary: secondary, isError: !isConnected)
}

@ViewBuilder
private func commandNameHelpText(prefix: String, checkState: CommandNameCheckState) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text("\(prefix) Use lowercase ASCII letters, numbers, and underscores.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        if case .unavailable(let message) = checkState {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrandPalette.statusError)
        }
    }
}

private func debouncedCommandNameCheck(
    functionName: String,
    checkCommandName: (String) async -> CommandNameAvailability
) async -> CommandNameCheckState? {
    guard !functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    do {
        try await Task.sleep(nanoseconds: 300_000_000)
    } catch {
        return nil
    }
    guard !Task.isCancelled else { return nil }
    let availability = await checkCommandName(functionName)
    guard !Task.isCancelled else { return nil }
    switch availability {
    case .available:
        return .available
    case .unavailable(let message):
        return .unavailable(message)
    }
}

// MARK: - Claude OAuth sheet

struct OAuthSettingsInitialState: Equatable {
    let functionName: String
    let nickname: String
    let dangerousPermissionsEnabled: Bool
    let claudeRouting: ClaudeRouting

    init(
        functionName: String,
        nickname: String,
        dangerousPermissionsEnabled: Bool,
        claudeRouting: ClaudeRouting = .automatic
    ) {
        self.functionName = functionName
        self.nickname = nickname
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        self.claudeRouting = claudeRouting
    }
}

func oauthSettingsRecommendedFunctionName(provider: ProviderRowState.ID) -> String {
    oauthSettingsRecommendedFunctionName(providerType: provider.inferredProviderType)
}

func oauthSettingsRecommendedFunctionName(providerType: AuthProfileType) -> String {
    providerType == .codex ? AppConfig.default.commands.ccodex : AppConfig.default.commands.cc
}

func oauthSettingsInitialState(config: AppConfig, provider: ProviderRowState.ID, isInitialSetup: Bool) -> OAuthSettingsInitialState {
    if let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }) {
        return OAuthSettingsInitialState(
            functionName: isInitialSetup ? "" : commandProfile.commandName,
            nickname: isInitialSetup ? "" : commandProfile.nickname,
            dangerousPermissionsEnabled: isInitialSetup ? false : commandProfile.dangerousPermissionsEnabled,
            claudeRouting: isInitialSetup ? .automatic : commandProfile.effectiveClaudeRouting
        )
    }
    return oauthSettingsInitialState(config: config, providerType: provider.inferredProviderType, isInitialSetup: isInitialSetup)
}

func oauthSettingsInitialState(config: AppConfig, providerType: AuthProfileType, isInitialSetup: Bool) -> OAuthSettingsInitialState {
    if isInitialSetup {
        return OAuthSettingsInitialState(functionName: "", nickname: "", dangerousPermissionsEnabled: false, claudeRouting: .automatic)
    }

    switch providerType {
    case .claude:
        return OAuthSettingsInitialState(
            functionName: config.commands.cc,
            nickname: config.nicknames.cc,
            dangerousPermissionsEnabled: config.includeDangerouslySkipPermissions,
            claudeRouting: .automatic
        )
    case .codex:
        return OAuthSettingsInitialState(
            functionName: config.commands.ccodex,
            nickname: config.nicknames.ccodex,
            dangerousPermissionsEnabled: config.includeDangerouslySkipPermissions,
            claudeRouting: .automatic
        )
    }
}

func oauthSettingsDangerousPermissionDefault(config: AppConfig, isInitialSetup: Bool) -> Bool {
    oauthSettingsInitialState(config: config, providerType: .claude, isInitialSetup: isInitialSetup).dangerousPermissionsEnabled
}

func oauthSettingsInitialCodex(config: AppConfig, provider: ProviderRowState.ID? = nil, isInitialSetup: Bool) -> AppConfig.Codex {
    if let provider,
       let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }),
       let codex = commandProfile.codex {
        return isInitialSetup ? AppConfig.default.ccodex : codex
    }
    return isInitialSetup ? AppConfig.default.ccodex : config.ccodex
}

func oauthSettingsShouldBlockInitialDisplay(isInitialSetup: Bool, availability: CommandNameAvailability) -> Bool {
    switch availability {
    case .available:
        return false
    case .unavailable:
        return !isInitialSetup
    }
}

struct ClaudeOAuthProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var nickname: String
    @State private var dangerousPermissionsEnabled: Bool
    @State private var connectionMode: AppConfig.ConnectionMode
    @State private var claudeRouting: ClaudeRouting
    @State private var scopedModels: [ClaudeModelOption]
    @State private var modelLoadError: String?
    @State private var isReloadingModels = false
    @State private var saveErrorMessage: String?
    @State private var commandNameCheckState: CommandNameCheckState = .checking
    @State private var confirmRemove: Bool = false
    let providerID: ProviderRowState.ID
    let connectionDetail: String
    let isConnected: Bool
    let onDisconnect: () -> Void
    let checkCommandName: (String) async -> CommandNameAvailability
    let refreshModels: () async throws -> [ClaudeModelOption]
    var onCancel: () -> Void = {}
    var isInitialSetup: Bool = false
    let save: (String, String, Bool, AppConfig.ConnectionMode, ClaudeRouting) throws -> Void

    init(
        config: AppConfig,
        providerID: ProviderRowState.ID = .claude,
        connectionDetail: String,
        isConnected: Bool,
        onDisconnect: @escaping () -> Void,
        initialModels: [ClaudeModelOption] = [],
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        refreshModels: @escaping () async throws -> [ClaudeModelOption] = { [] },
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        save: @escaping (String, String, Bool, AppConfig.ConnectionMode, ClaudeRouting) throws -> Void
    ) {
        let initialState = oauthSettingsInitialState(config: config, provider: providerID, isInitialSetup: isInitialSetup)
        _functionName = State(initialValue: initialState.functionName)
        _nickname = State(initialValue: initialState.nickname)
        _dangerousPermissionsEnabled = State(initialValue: initialState.dangerousPermissionsEnabled)
        _connectionMode = State(initialValue: config.oauthCommandProfiles.first(where: { $0.id == providerID.rawValue })?.connectionMode ?? .proxy)
        _claudeRouting = State(initialValue: initialState.claudeRouting)
        _scopedModels = State(initialValue: initialModels)
        self.providerID = providerID
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.onDisconnect = onDisconnect
        self.checkCommandName = checkCommandName
        self.refreshModels = refreshModels
        self.onCancel = onCancel
        self.isInitialSetup = isInitialSetup
        self.save = save
    }

    var body: some View {
        let meta = accountMeta(connectionDetail: connectionDetail, providerName: "Claude OAuth", isConnected: isConnected)

        AccountSheetChrome(
            providerID: providerID,
            providerType: .claude,
            title: "Account Settings",
            width: 460,
            minHeight: ProviderSettingsSheetMetrics.claudeHeight,
            onClose: {
                onCancel()
                dismiss()
            }
        ) {
            AccountMetaBlock(primary: meta.primary, secondary: meta.secondary, isError: meta.isError)

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Nickname")
                StyledTextField(placeholder: "e.g. Personal, Work", text: $nickname)
                Text("Shown in the menu bar and account list. Optional.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Command name")
                CommandNameField(
                    value: $functionName,
                    checkState: commandNameCheckState,
                    recommendedName: isInitialSetup ? oauthSettingsRecommendedFunctionName(providerType: .claude) : nil
                )
                commandNameHelpText(
                    prefix: "The terminal command that launches Claude Code with this account.",
                    checkState: commandNameCheckState
                )
            }

            ClaudeOAuthConnectionModeSection(connectionMode: $connectionMode)

            if ClaudeRoleRoutingOptions.showsModels(connectionMode: connectionMode) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        GroupTitle(text: "Models")
                        Spacer()
                        Button {
                            Task { await reloadModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .disabled(isReloadingModels)
                        .help("Refresh models for this Claude account")
                    }
                    ClaudeRoleRoutingFields(routing: $claudeRouting, options: scopedModels)
                    if isReloadingModels {
                        Text("Loading models for this Claude account.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else if let modelLoadError {
                        Text(modelLoadError)
                            .font(.system(size: 11.5))
                            .foregroundStyle(BrandPalette.statusWarning)
                    }
                }
            } else {
                Text("Direct uses Claude Code's current model policy.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Permissions")
                GroupCard {
                    CardRow(
                        label: "Skip permission prompts",
                        description: "Adds --dangerously-skip-permissions when launching. Use only for trusted local work.",
                        warning: dangerousPermissionsEnabled ? "Claude Code will skip every permission confirmation." : nil,
                        isLast: true
                    ) {
                        Toggle("", isOn: $dangerousPermissionsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(BrandPalette.accent)
                            .controlSize(.small)
                    }
                }
            }
        } footer: {
            SheetFooter(
                removeLabel: "Remove account",
                onRemove: { confirmRemove = true },
                onCancel: {
                    onCancel()
                    dismiss()
                },
                onSave: {
                    do {
                        try save(functionName, nickname, dangerousPermissionsEnabled, connectionMode, claudeRouting)
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                },
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandNameCheckState.isSaveDisabled
            )
        }
        .task(id: functionName) {
            await updateCommandNameAvailability()
        }
        .task(id: connectionMode) {
            if connectionMode == .proxy, scopedModels.isEmpty {
                await reloadModels()
            }
        }
        .settingsToast(message: saveErrorMessage, dismiss: { saveErrorMessage = nil })
        .alert("Remove this Claude account?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                onDisconnect()
                dismiss()
            }
        } message: {
            Text("The auth profile will be deleted from CLIProxyAPI. You can reconnect at any time.")
        }
    }

    private func updateCommandNameAvailability() async {
        commandNameCheckState = .checking
        guard let state = await debouncedCommandNameCheck(
            functionName: functionName,
            checkCommandName: checkCommandName
        ) else { return }
        commandNameCheckState = state
    }

    private func reloadModels() async {
        guard connectionMode == .proxy, !isReloadingModels else { return }
        isReloadingModels = true
        defer { isReloadingModels = false }
        do {
            scopedModels = try await refreshModels()
            modelLoadError = nil
        } catch {
            modelLoadError = error.localizedDescription
        }
    }
}

// MARK: - Codex sheet

struct CodexProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var nickname: String
    @State private var opus: AppConfig.CodexRole
    @State private var sonnet: AppConfig.CodexRole
    @State private var haiku: AppConfig.CodexRole
    @State private var dangerousPermissionsEnabled: Bool
    @State private var saveErrorMessage: String?
    @State private var commandNameCheckState: CommandNameCheckState = .checking
    @State private var confirmRemove: Bool = false
    @State private var scopedAvailableModels: [CodexModelOption]
    @State private var isReloading: Bool = false
    let providerID: ProviderRowState.ID
    let connectionDetail: String
    let isConnected: Bool
    let availableModels: [CodexModelOption]
    let modelLoadingState: CodexModelLoadingState
    let refreshModels: () async throws -> [CodexModelOption]
    let onDisconnect: () -> Void
    let checkCommandName: (String) async -> CommandNameAvailability
    var onCancel: () -> Void = {}
    var isInitialSetup: Bool = false
    let preferredModel: ([CodexModelOption]) -> String?
    let save: (String, String, AppConfig.Codex, Bool) throws -> Void
    @State private var didApplyInitialDefaults: Bool = false

    init(
        config: AppConfig,
        providerID: ProviderRowState.ID = .codex,
        connectionDetail: String,
        isConnected: Bool,
        availableModels: [CodexModelOption],
        modelLoadingState: CodexModelLoadingState,
        refreshModels: @escaping () async throws -> [CodexModelOption],
        onDisconnect: @escaping () -> Void,
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        preferredModel: @escaping ([CodexModelOption]) -> String?,
        save: @escaping (String, String, AppConfig.Codex, Bool) throws -> Void
    ) {
        let initialState = oauthSettingsInitialState(config: config, provider: providerID, isInitialSetup: isInitialSetup)
        let initialCodex = oauthSettingsInitialCodex(config: config, provider: providerID, isInitialSetup: isInitialSetup)
        _functionName = State(initialValue: initialState.functionName)
        _nickname = State(initialValue: initialState.nickname)
        _opus = State(initialValue: initialCodex.opus)
        _sonnet = State(initialValue: initialCodex.sonnet)
        _haiku = State(initialValue: initialCodex.haiku)
        _dangerousPermissionsEnabled = State(initialValue: initialState.dangerousPermissionsEnabled)
        _scopedAvailableModels = State(initialValue: availableModels)
        self.providerID = providerID
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.availableModels = availableModels
        self.modelLoadingState = modelLoadingState
        self.refreshModels = refreshModels
        self.onDisconnect = onDisconnect
        self.checkCommandName = checkCommandName
        self.onCancel = onCancel
        self.isInitialSetup = isInitialSetup
        self.preferredModel = preferredModel
        self.save = save
    }

    var body: some View {
        let meta = accountMeta(connectionDetail: connectionDetail, providerName: "Codex OAuth", isConnected: isConnected)

        AccountSheetChrome(
            providerID: providerID,
            providerType: .codex,
            title: "Account Settings",
            width: ProviderSettingsSheetMetrics.codexWidth,
            minHeight: ProviderSettingsSheetMetrics.codexHeight,
            onClose: {
                onCancel()
                dismiss()
            }
        ) {
            AccountMetaBlock(primary: meta.primary, secondary: meta.secondary, isError: meta.isError)

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Nickname")
                StyledTextField(placeholder: "e.g. Personal, Work", text: $nickname)
                Text("Shown in the menu bar and account list. Optional.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Command name")
                CommandNameField(
                    value: $functionName,
                    checkState: commandNameCheckState,
                    recommendedName: isInitialSetup ? oauthSettingsRecommendedFunctionName(providerType: .codex) : nil
                )
                commandNameHelpText(
                    prefix: "The terminal command launches Claude Code routed through Codex.",
                    checkState: commandNameCheckState
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    GroupTitle(text: "Routing")
                    Spacer()
                    Button {
                        Task { await reloadModels() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(CodexProviderModelLoadingPresentation.isRefreshDisabled(modelLoadingState: modelLoadingState, isReloading: isReloading))
                }
                Text(CodexProviderModelLoadingPresentation.message(modelLoadingState: modelLoadingState, isReloading: isReloading) ?? "Map each Claude model tier to a GPT model, reasoning, and context window.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexProviderModelLoadingPresentation.isError(modelLoadingState: modelLoadingState, isReloading: isReloading) ? BrandPalette.statusError : .secondary)

                GroupCard {
                    CodexRoleRoutingFields(
                        opus: $opus,
                        sonnet: $sonnet,
                        haiku: $haiku,
                        availableModels: scopedAvailableModels
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Permissions")
                GroupCard {
                    CardRow(
                        label: "Skip permission prompts",
                        description: "Adds --dangerously-skip-permissions when launching. Use only for trusted local work.",
                        warning: dangerousPermissionsEnabled ? "Claude Code will skip every permission confirmation." : nil,
                        isLast: true
                    ) {
                        Toggle("", isOn: $dangerousPermissionsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(BrandPalette.accent)
                            .controlSize(.small)
                    }
                }
            }
        } footer: {
            SheetFooter(
                removeLabel: "Remove account",
                onRemove: { confirmRemove = true },
                onCancel: {
                    onCancel()
                    dismiss()
                },
                onSave: {
                    do {
                        let codex = CodexRoleRoutingOptions.normalizedCodex(
                            AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
                            options: scopedAvailableModels
                        )
                        try save(
                            functionName,
                            nickname,
                            codex,
                            dangerousPermissionsEnabled
                        )
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                },
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandNameCheckState.isSaveDisabled
            )
        }
        .task(id: functionName) {
            await updateCommandNameAvailability()
        }
        .settingsToast(message: saveErrorMessage, dismiss: { saveErrorMessage = nil })
        .alert("Remove this Codex account?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                onDisconnect()
                dismiss()
            }
        } message: {
            Text("The auth profile will be deleted from CLIProxyAPI. You can reconnect at any time.")
        }
        .task {
            await reloadModels()
            applyInitialDefaultsIfNeeded()
        }
        .onChange(of: availableModels) { _, models in
            scopedAvailableModels = CodexProviderModelOptions.modelsAfterGlobalAvailableModelsChange(
                currentScopedModels: scopedAvailableModels,
                globalAvailableModels: models
            )
            applyDefaultModel(from: scopedAvailableModels)
            applyInitialDefaultsIfNeeded()
        }
    }

    private func updateCommandNameAvailability() async {
        commandNameCheckState = .checking
        guard let state = await debouncedCommandNameCheck(
            functionName: functionName,
            checkCommandName: checkCommandName
        ) else { return }
        commandNameCheckState = state
    }

    private func reloadModels() async {
        isReloading = true
        defer { isReloading = false }
        do {
            scopedAvailableModels = try await refreshModels()
            applyDefaultModel(from: scopedAvailableModels)
        } catch {
            scopedAvailableModels = availableModels
        }
    }

    private func applyInitialDefaultsIfNeeded() {
        guard isInitialSetup, !didApplyInitialDefaults,
              let defaultModel = preferredModel(scopedAvailableModels) else { return }
        opus.model = defaultModel
        sonnet.model = defaultModel
        haiku.model = defaultModel
        didApplyInitialDefaults = true
    }

    private func applyDefaultModel(from models: [CodexModelOption]) {
        guard let defaultModel = preferredModel(models) else { return }
        if opus.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { opus.model = defaultModel }
        if sonnet.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sonnet.model = defaultModel }
        if haiku.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { haiku.model = defaultModel }
    }
}

// MARK: - API key sheets

struct ClaudeAPIProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var nickname: String
    @State private var claudeRouting: ClaudeRouting
    @State private var scopedModels: [ClaudeModelOption]
    @State private var isReloadingModels = false
    @State private var modelLoadError: String?
    @State private var dangerousPermissionsEnabled: Bool
    @State private var apiKey = ""
    @State private var saveErrorMessage: String?
    @State private var commandNameCheckState: CommandNameCheckState = .checking
    let isConfigured: Bool
    let refreshModels: () async throws -> [ClaudeModelOption]
    let checkCommandName: (String) async -> CommandNameAvailability
    let save: (String, String, ClaudeRouting, Bool, String?) throws -> Void
    let remove: () -> Void

    init(
        config: AppConfig,
        isConfigured: Bool,
        initialModels: [ClaudeModelOption] = [],
        refreshModels: @escaping () async throws -> [ClaudeModelOption],
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        save: @escaping (String, String, ClaudeRouting, Bool, String?) throws -> Void,
        remove: @escaping () -> Void
    ) {
        _functionName = State(initialValue: config.commands.ccapi)
        _nickname = State(initialValue: config.ccapi.nickname)
        _claudeRouting = State(initialValue: config.ccapi.claude)
        _scopedModels = State(initialValue: initialModels)
        _dangerousPermissionsEnabled = State(initialValue: config.ccapi.dangerousPermissionsEnabled)
        self.isConfigured = isConfigured
        self.refreshModels = refreshModels
        self.checkCommandName = checkCommandName
        self.save = save
        self.remove = remove
    }

    var body: some View {
        AccountSheetChrome(
            providerID: .claudeAPI,
            providerType: .claude,
            title: "Claude API Key",
            width: 460,
            minHeight: ProviderSettingsSheetMetrics.claudeHeight,
            onClose: { dismiss() }
        ) {
            Text(isConfigured ? "API key configured" : "Add an Anthropic API key")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isConfigured ? BrandPalette.statusRunning : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "API key")
                SecureField(isConfigured ? "Enter a new key to replace it" : "sk-ant-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in a private local file and used only by CLIProxyAPI.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Nickname")
                StyledTextField(placeholder: "e.g. Personal, Work", text: $nickname)
                Text("Shown in the menu bar and account list. Optional.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Command name")
                CommandNameField(value: $functionName, checkState: commandNameCheckState)
                commandNameHelpText(
                    prefix: "The terminal command that launches Claude Code with this API key.",
                    checkState: commandNameCheckState
                )
            }

            FixedCLIProxyAPIConnectionSection(
                description: "API key requests always route through CLIProxyAPI to keep them separate from the current OAuth subscription login."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    GroupTitle(text: "Models")
                    Spacer()
                    Button {
                        Task { await reloadModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(isReloadingModels)
                    .help("Refresh models for this Claude API key")
                }
                ClaudeRoleRoutingFields(routing: $claudeRouting, options: scopedModels)
                if isReloadingModels {
                    Text("Loading models for this Claude API key.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if let modelLoadError {
                    Text(modelLoadError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BrandPalette.statusWarning)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Permissions")
                GroupCard {
                    CardRow(
                        label: "Skip permission prompts",
                        description: "Adds --dangerously-skip-permissions when launching. Use only for trusted local work.",
                        warning: dangerousPermissionsEnabled ? "Claude Code will skip every permission confirmation." : nil,
                        isLast: true
                    ) {
                        Toggle("", isOn: $dangerousPermissionsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(BrandPalette.accent)
                            .controlSize(.small)
                    }
                }
            }
        } footer: {
            SheetFooter(
                removeLabel: "Remove key",
                onRemove: { remove(); dismiss() },
                onCancel: { dismiss() },
                onSave: {
                    do {
                        try save(functionName, nickname, claudeRouting, dangerousPermissionsEnabled, apiKey.isEmpty ? nil : apiKey)
                        apiKey = ""
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                },
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || commandNameCheckState.isSaveDisabled
                    || (!isConfigured && apiKey.isEmpty)
            )
        }
        .task {
            if scopedModels.isEmpty {
                await reloadModels()
            }
        }
        .task(id: functionName) {
            commandNameCheckState = .checking
            guard let state = await debouncedCommandNameCheck(
                functionName: functionName,
                checkCommandName: checkCommandName
            ) else { return }
            commandNameCheckState = state
        }
        .settingsToast(message: saveErrorMessage, dismiss: { saveErrorMessage = nil })
    }

    private func reloadModels() async {
        guard !isReloadingModels else { return }
        isReloadingModels = true
        defer { isReloadingModels = false }
        do {
            scopedModels = try await refreshModels()
            modelLoadError = nil
        } catch {
            modelLoadError = error.localizedDescription
        }
    }
}

struct CodexAPIProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var nickname: String
    @State private var opus: AppConfig.CodexRole
    @State private var sonnet: AppConfig.CodexRole
    @State private var haiku: AppConfig.CodexRole
    @State private var dangerousPermissionsEnabled: Bool
    @State private var scopedAvailableModels: [CodexModelOption]
    @State private var isReloading = false
    @State private var didApplyInitialDefaults = false
    @State private var apiKey = ""
    @State private var saveErrorMessage: String?
    @State private var commandNameCheckState: CommandNameCheckState = .checking
    let isConfigured: Bool
    let modelLoadingState: CodexModelLoadingState
    let refreshModels: () async throws -> [CodexModelOption]
    let preferredModel: ([CodexModelOption]) -> String?
    let checkCommandName: (String) async -> CommandNameAvailability
    let save: (String, String, AppConfig.Codex, Bool, String?) throws -> Void
    let remove: () -> Void

    init(
        config: AppConfig,
        isConfigured: Bool,
        availableModels: [CodexModelOption],
        modelLoadingState: CodexModelLoadingState,
        refreshModels: @escaping () async throws -> [CodexModelOption],
        preferredModel: @escaping ([CodexModelOption]) -> String?,
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        save: @escaping (String, String, AppConfig.Codex, Bool, String?) throws -> Void,
        remove: @escaping () -> Void
    ) {
        let normalizedCodex = CodexAPIModelOptions.normalized(config.codexAPI.codex)
        let normalizedModels = CodexAPIModelOptions.initialModels(
            codex: normalizedCodex,
            availableModels: availableModels
        )
        _functionName = State(initialValue: config.commands.ccodexapi)
        _nickname = State(initialValue: config.codexAPI.nickname)
        _opus = State(initialValue: normalizedCodex.opus)
        _sonnet = State(initialValue: normalizedCodex.sonnet)
        _haiku = State(initialValue: normalizedCodex.haiku)
        _dangerousPermissionsEnabled = State(initialValue: config.codexAPI.dangerousPermissionsEnabled)
        _scopedAvailableModels = State(initialValue: normalizedModels)
        self.isConfigured = isConfigured
        self.modelLoadingState = modelLoadingState
        self.refreshModels = refreshModels
        self.preferredModel = preferredModel
        self.checkCommandName = checkCommandName
        self.save = save
        self.remove = remove
    }

    var body: some View {
        AccountSheetChrome(providerID: .codexAPI, providerType: .codex, title: "OpenAI API Key", width: ProviderSettingsSheetMetrics.codexWidth, minHeight: ProviderSettingsSheetMetrics.codexHeight, onClose: { dismiss() }) {
            Text(isConfigured ? "API key configured" : "Add an OpenAI API key")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isConfigured ? BrandPalette.statusRunning : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "API key")
                SecureField(isConfigured ? "Enter a new key to replace it" : "sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("This provider always routes through CLIProxyAPI.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Nickname")
                StyledTextField(placeholder: "e.g. Personal, Work", text: $nickname)
                Text("Shown in the menu bar and account list. Optional.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Command name")
                CommandNameField(value: $functionName, checkState: commandNameCheckState)
                commandNameHelpText(
                    prefix: "The terminal command that launches Claude Code with this API key.",
                    checkState: commandNameCheckState
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    GroupTitle(text: "Routing")
                    Spacer()
                    Button {
                        Task { await reloadModels() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(CodexProviderModelLoadingPresentation.isRefreshDisabled(modelLoadingState: modelLoadingState, isReloading: isReloading))
                }
                Text(CodexProviderModelLoadingPresentation.message(modelLoadingState: modelLoadingState, isReloading: isReloading) ?? "Map each Claude model tier to a GPT model, reasoning, and context window.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexProviderModelLoadingPresentation.isError(modelLoadingState: modelLoadingState, isReloading: isReloading) ? BrandPalette.statusError : .secondary)
                GroupCard {
                    CodexRoleRoutingFields(opus: $opus, sonnet: $sonnet, haiku: $haiku, availableModels: scopedAvailableModels)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GroupTitle(text: "Permissions")
                GroupCard {
                    CardRow(
                        label: "Skip permission prompts",
                        description: "Adds --dangerously-skip-permissions when launching. Use only for trusted local work.",
                        warning: dangerousPermissionsEnabled ? "Claude Code will skip every permission confirmation." : nil,
                        isLast: true
                    ) {
                        Toggle("", isOn: $dangerousPermissionsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(BrandPalette.accent)
                            .controlSize(.small)
                    }
                }
            }
        } footer: {
            SheetFooter(
                removeLabel: "Remove key",
                onRemove: { remove(); dismiss() },
                onCancel: { dismiss() },
                onSave: {
                    do {
                        let codex = CodexRoleRoutingOptions.normalizedCodex(
                            CodexAPIModelOptions.normalized(AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku)),
                            options: scopedAvailableModels
                        )
                        try save(
                            functionName,
                            nickname,
                            codex,
                            dangerousPermissionsEnabled,
                            apiKey.isEmpty ? nil : apiKey
                        )
                        apiKey = ""
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                },
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || commandNameCheckState.isSaveDisabled
                    || (!isConfigured && apiKey.isEmpty)
            )
        }
        .task {
            await reloadModels()
            applyInitialDefaultsIfNeeded()
        }
        .task(id: functionName) {
            commandNameCheckState = .checking
            guard let state = await debouncedCommandNameCheck(
                functionName: functionName,
                checkCommandName: checkCommandName
            ) else { return }
            commandNameCheckState = state
        }
        .settingsToast(message: saveErrorMessage, dismiss: { saveErrorMessage = nil })
    }

    private func reloadModels() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        do {
            scopedAvailableModels = try await refreshModels()
            applyDefaultModel(from: scopedAvailableModels)
            if !isConfigured {
                applyInitialDefaultsIfNeeded()
            }
        } catch {
            // Keep the current API-key-scoped options; OAuth/global models are not valid fallbacks.
        }
    }

    private func applyInitialDefaultsIfNeeded() {
        guard CodexAPIInitialDefaults.shouldApply(
            isConfigured: isConfigured,
            didApply: didApplyInitialDefaults
        ), let defaultModel = preferredModel(scopedAvailableModels) else { return }
        opus.model = defaultModel
        sonnet.model = defaultModel
        haiku.model = defaultModel
        didApplyInitialDefaults = true
    }

    private func applyDefaultModel(from models: [CodexModelOption]) {
        guard let defaultModel = preferredModel(models) else { return }
        if opus.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { opus.model = defaultModel }
        if sonnet.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sonnet.model = defaultModel }
        if haiku.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { haiku.model = defaultModel }
    }
}
