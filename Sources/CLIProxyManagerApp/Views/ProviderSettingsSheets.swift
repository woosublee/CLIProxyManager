import CLIProxyManagerCore
import SwiftUI

// MARK: - Shared sheet chrome

enum ProviderSettingsSheetMetrics {
    static let defaultMinHeight: CGFloat = 360
    static let defaultMaxHeight: CGFloat = 720
    static let codexHeight: CGFloat = 700
    static let footerActionButtonControlSize = ControlSize.regular
}

private struct AccountSheetChrome<Content: View, Footer: View>: View {
    let providerID: ProviderRowState.ID
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
            ProviderAvatar(providerID: providerID, size: 28)
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

private struct GroupCard<Content: View>: View {
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

private struct CardRow<Control: View>: View {
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
            TextField("function_name", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 9)
            checkIndicator
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

// MARK: - Claude OAuth sheet

struct OAuthSettingsInitialState: Equatable {
    let functionName: String
    let nickname: String
    let dangerousPermissionsEnabled: Bool
}

func oauthSettingsInitialState(config: AppConfig, provider: ProviderRowState.ID, isInitialSetup: Bool) -> OAuthSettingsInitialState {
    if isInitialSetup {
        switch provider {
        case .claude:
            return OAuthSettingsInitialState(functionName: AppConfig.default.commands.cc, nickname: "", dangerousPermissionsEnabled: false)
        case .codex:
            return OAuthSettingsInitialState(functionName: AppConfig.default.commands.ccodex, nickname: "", dangerousPermissionsEnabled: false)
        }
    }

    switch provider {
    case .claude:
        return OAuthSettingsInitialState(
            functionName: config.commands.cc,
            nickname: config.nicknames.cc,
            dangerousPermissionsEnabled: config.includeDangerouslySkipPermissions
        )
    case .codex:
        return OAuthSettingsInitialState(
            functionName: config.commands.ccodex,
            nickname: config.nicknames.ccodex,
            dangerousPermissionsEnabled: config.includeDangerouslySkipPermissions
        )
    }
}

func oauthSettingsDangerousPermissionDefault(config: AppConfig, isInitialSetup: Bool) -> Bool {
    oauthSettingsInitialState(config: config, provider: .claude, isInitialSetup: isInitialSetup).dangerousPermissionsEnabled
}

func oauthSettingsInitialCodex(config: AppConfig, isInitialSetup: Bool) -> AppConfig.Codex {
    isInitialSetup ? AppConfig.default.ccodex : config.ccodex
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
    @State private var saveErrorMessage: String?
    @State private var commandNameCheckState: CommandNameCheckState = .checking
    @State private var confirmRemove: Bool = false
    let connectionDetail: String
    let isConnected: Bool
    let onDisconnect: () -> Void
    let checkCommandName: (String) async -> CommandNameAvailability
    var onCancel: () -> Void = {}
    var isInitialSetup: Bool = false
    let save: (String, String, Bool) throws -> Void

    init(
        config: AppConfig,
        connectionDetail: String,
        isConnected: Bool,
        onDisconnect: @escaping () -> Void,
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        save: @escaping (String, String, Bool) throws -> Void
    ) {
        let initialState = oauthSettingsInitialState(config: config, provider: .claude, isInitialSetup: isInitialSetup)
        _functionName = State(initialValue: initialState.functionName)
        _nickname = State(initialValue: initialState.nickname)
        _dangerousPermissionsEnabled = State(initialValue: initialState.dangerousPermissionsEnabled)
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.onDisconnect = onDisconnect
        self.checkCommandName = checkCommandName
        self.onCancel = onCancel
        self.isInitialSetup = isInitialSetup
        self.save = save
    }

    var body: some View {
        let meta = accountMeta(connectionDetail: connectionDetail, providerName: "Claude OAuth", isConnected: isConnected)

        AccountSheetChrome(
            providerID: .claude,
            title: "Account Settings",
            width: 460,
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
                CommandNameField(value: $functionName, checkState: commandNameCheckState)
                commandNameHelpText(
                    prefix: "The terminal command that launches Claude Code with this account.",
                    checkState: commandNameCheckState
                )
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
                        try save(functionName, nickname, dangerousPermissionsEnabled)
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
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return
        }

        switch await checkCommandName(functionName) {
        case .available:
            commandNameCheckState = .available
        case .unavailable(let message):
            commandNameCheckState = .unavailable(message)
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
    let connectionDetail: String
    let isConnected: Bool
    let availableModels: [String]
    let modelLoadingState: CodexModelLoadingState
    let refreshModels: () -> Void
    let onDisconnect: () -> Void
    let checkCommandName: (String) async -> CommandNameAvailability
    var onCancel: () -> Void = {}
    var isInitialSetup: Bool = false
    var latestModel: () -> String? = { nil }
    let save: (String, String, AppConfig.Codex, Bool) throws -> Void
    @State private var didApplyInitialDefaults: Bool = false

    init(
        config: AppConfig,
        connectionDetail: String,
        isConnected: Bool,
        availableModels: [String],
        modelLoadingState: CodexModelLoadingState,
        refreshModels: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        checkCommandName: @escaping (String) async -> CommandNameAvailability,
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        latestModel: @escaping () -> String? = { nil },
        save: @escaping (String, String, AppConfig.Codex, Bool) throws -> Void
    ) {
        let initialState = oauthSettingsInitialState(config: config, provider: .codex, isInitialSetup: isInitialSetup)
        let initialCodex = oauthSettingsInitialCodex(config: config, isInitialSetup: isInitialSetup)
        _functionName = State(initialValue: initialState.functionName)
        _nickname = State(initialValue: initialState.nickname)
        _opus = State(initialValue: initialCodex.opus)
        _sonnet = State(initialValue: initialCodex.sonnet)
        _haiku = State(initialValue: initialCodex.haiku)
        _dangerousPermissionsEnabled = State(initialValue: initialState.dangerousPermissionsEnabled)
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.availableModels = availableModels
        self.modelLoadingState = modelLoadingState
        self.refreshModels = refreshModels
        self.onDisconnect = onDisconnect
        self.checkCommandName = checkCommandName
        self.onCancel = onCancel
        self.isInitialSetup = isInitialSetup
        self.latestModel = latestModel
        self.save = save
    }

    var body: some View {
        let meta = accountMeta(connectionDetail: connectionDetail, providerName: "Codex OAuth", isConnected: isConnected)

        AccountSheetChrome(
            providerID: .codex,
            title: "Account Settings",
            width: 600,
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
                CommandNameField(value: $functionName, checkState: commandNameCheckState)
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
                        refreshModels()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(modelLoadingState.isLoading)
                }
                Text(modelLoadingState.message ?? "Map each Claude model tier to a GPT model, reasoning, and context window.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(modelLoadingState.isError ? BrandPalette.statusError : .secondary)

                GroupCard {
                    routingHeader
                    Divider().padding(.leading, 14)
                    routingRow(label: "Opus", role: $opus, last: false)
                    routingRow(label: "Sonnet", role: $sonnet, last: false)
                    routingRow(label: "Haiku", role: $haiku, last: true)
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
                        try save(
                            functionName,
                            nickname,
                            AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
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
            if availableModels.isEmpty {
                refreshModels()
            }
            applyInitialDefaultsIfNeeded()
        }
        .onChange(of: availableModels) { models in
            applyDefaultModel(from: models)
            applyInitialDefaultsIfNeeded()
        }
    }

    private func updateCommandNameAvailability() async {
        commandNameCheckState = .checking
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return
        }

        switch await checkCommandName(functionName) {
        case .available:
            commandNameCheckState = .available
        case .unavailable(let message):
            commandNameCheckState = .unavailable(message)
        }
    }

    private func applyInitialDefaultsIfNeeded() {
        guard isInitialSetup, !didApplyInitialDefaults else { return }
        guard let latest = latestModel() else { return }
        opus.model = latest
        sonnet.model = latest
        haiku.model = latest
        didApplyInitialDefaults = true
    }

    private var routingHeader: some View {
        HStack(spacing: 8) {
            Text("Claude")
                .frame(width: 64, alignment: .leading)
            Text("GPT model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Reasoning")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Context")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func routingRow(label: String, role: Binding<AppConfig.CodexRole>, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 64, alignment: .leading)

                Picker("", selection: role.model) {
                    ForEach(ModelSelectionOptions.options(currentModel: role.wrappedValue.model, availableModels: availableModels), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: role.reasoning) {
                    ForEach(AppConfig.CodexReasoning.allCases, id: \.self) { reasoning in
                        Text(reasoning.rawValue).tag(reasoning)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: role.contextWindow) {
                    ForEach(AppConfig.CodexContextWindow.allCases, id: \.self) { context in
                        Text(context.rawValue).tag(context)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if !last {
                Divider().padding(.leading, 14)
            }
        }
    }

    private func applyDefaultModel(from models: [String]) {
        guard let firstModel = models.first else { return }
        if opus.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { opus.model = firstModel }
        if sonnet.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sonnet.model = firstModel }
        if haiku.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { haiku.model = firstModel }
    }
}

// MARK: - Claude API sheet (kept; not used by main popover anymore)

struct ClaudeAPIProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var model: String
    @State private var saveErrorMessage: String?
    let save: (String, String) throws -> Void

    init(config: AppConfig, save: @escaping (String, String) throws -> Void) {
        _functionName = State(initialValue: config.commands.ccapi)
        _model = State(initialValue: config.ccapi.model)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude API")
                .font(.title2.bold())
            TextField("Function name", text: $functionName)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $model)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        try save(functionName, model)
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .settingsToast(message: saveErrorMessage, dismiss: { saveErrorMessage = nil })
    }
}
