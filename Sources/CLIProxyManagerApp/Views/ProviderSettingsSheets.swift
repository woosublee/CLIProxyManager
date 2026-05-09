import CLIProxyManagerCore
import SwiftUI

// MARK: - Shared sheet chrome

private struct AccountSheetChrome<Content: View, Footer: View>: View {
    let providerID: ProviderRowState.ID
    let title: String
    let width: CGFloat
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
        .frame(minHeight: 360, maxHeight: 720)
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

private struct CommandNameField: View {
    @Binding var value: String
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
            TextField("function-name", text: Binding(
                get: { value },
                set: { value = sanitize($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 9)
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = lowered.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(allowed)
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
                .controlSize(.small)
            Button("Save changes", action: onSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(saveDisabled)
        }
    }
}

private struct SaveErrorAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert("Save Failed", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

private extension View {
    func saveErrorAlert(message: Binding<String?>) -> some View {
        modifier(SaveErrorAlert(message: message))
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

// MARK: - Claude OAuth sheet

struct ClaudeOAuthProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var nickname: String
    @State private var dangerousPermissionsEnabled: Bool
    @State private var saveErrorMessage: String?
    @State private var confirmRemove: Bool = false
    let connectionDetail: String
    let isConnected: Bool
    let onDisconnect: () -> Void
    var onCancel: () -> Void = {}
    var isInitialSetup: Bool = false
    let save: (String, String, Bool) throws -> Void

    init(
        config: AppConfig,
        connectionDetail: String,
        isConnected: Bool,
        onDisconnect: @escaping () -> Void,
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        save: @escaping (String, String, Bool) throws -> Void
    ) {
        if isInitialSetup {
            _functionName = State(initialValue: AppConfig.default.commands.cc)
            _nickname = State(initialValue: "")
        } else {
            _functionName = State(initialValue: config.commands.cc)
            _nickname = State(initialValue: config.nicknames.cc)
        }
        _dangerousPermissionsEnabled = State(initialValue: config.includeDangerouslySkipPermissions)
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.onDisconnect = onDisconnect
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
                CommandNameField(value: $functionName)
                Text("The terminal command that launches Claude Code with this account. Lowercase, hyphens only.")
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
                        try save(functionName, nickname, dangerousPermissionsEnabled)
                        dismiss()
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                },
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .saveErrorAlert(message: $saveErrorMessage)
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
    @State private var confirmRemove: Bool = false
    let connectionDetail: String
    let isConnected: Bool
    let availableModels: [String]
    let refreshModels: () -> Void
    let onDisconnect: () -> Void
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
        refreshModels: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onCancel: @escaping () -> Void = {},
        isInitialSetup: Bool = false,
        latestModel: @escaping () -> String? = { nil },
        save: @escaping (String, String, AppConfig.Codex, Bool) throws -> Void
    ) {
        if isInitialSetup {
            _functionName = State(initialValue: AppConfig.default.commands.ccodex)
            _nickname = State(initialValue: "")
        } else {
            _functionName = State(initialValue: config.commands.ccodex)
            _nickname = State(initialValue: config.nicknames.ccodex)
        }
        _opus = State(initialValue: config.ccodex.opus)
        _sonnet = State(initialValue: config.ccodex.sonnet)
        _haiku = State(initialValue: config.ccodex.haiku)
        _dangerousPermissionsEnabled = State(initialValue: config.includeDangerouslySkipPermissions)
        self.connectionDetail = connectionDetail
        self.isConnected = isConnected
        self.availableModels = availableModels
        self.refreshModels = refreshModels
        self.onDisconnect = onDisconnect
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
                CommandNameField(value: $functionName)
                Text("Lowercase, hyphens only. The terminal command launches Claude Code routed through Codex.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
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
                }
                Text("Map each Claude model tier to a GPT model, reasoning, and context window.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

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
                saveDisabled: functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .saveErrorAlert(message: $saveErrorMessage)
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
        .saveErrorAlert(message: $saveErrorMessage)
    }
}
