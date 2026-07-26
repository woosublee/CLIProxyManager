import CLIProxyManagerCore
import SwiftUI

private enum SettingsSheetError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Port must be a number."
        }
    }
}

private extension View {
    func settingsErrorAlert(title: String = "Save Failed", message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct PortSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var portText: String
    @State private var errorMessage: String?
    let save: (Int) throws -> Void

    init(port: Int, save: @escaping (Int) throws -> Void) {
        _portText = State(initialValue: String(port))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Port")
                .font(.title2.bold())
            TextField(String(AppConfig.default.port), text: $portText)
                .textFieldStyle(.roundedBorder)
            Text("Use an available port between 1024 and 65535. Use \(AppConfig.default.port) to keep it separate from the legacy 8317 port.")
                .font(.callout)
                .foregroundStyle(.secondary)
            actionButtons {
                guard let port = Int(portText) else {
                    throw SettingsSheetError.invalidPort
                }
                try save(port)
            }
        }
        .padding(24)
        .frame(width: 420)
        .settingsErrorAlert(message: $errorMessage)
    }

    private func actionButtons(saveAction: @escaping () throws -> Void) -> some View {
        HStack {
            Button("Default") { portText = String(AppConfig.default.port) }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                do {
                    try saveAction()
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct ModelsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var opus: AppConfig.CodexRole
    @State private var sonnet: AppConfig.CodexRole
    @State private var haiku: AppConfig.CodexRole
    @State private var errorMessage: String?
    let availableModels: [CodexModelOption]
    let refreshModels: () -> Void
    let save: (AppConfig.Codex) throws -> Void

    init(
        codex: AppConfig.Codex,
        availableModels: [CodexModelOption],
        refreshModels: @escaping () -> Void,
        save: @escaping (AppConfig.Codex) throws -> Void
    ) {
        _opus = State(initialValue: codex.opus)
        _sonnet = State(initialValue: codex.sonnet)
        _haiku = State(initialValue: codex.haiku)
        self.availableModels = availableModels
        self.refreshModels = refreshModels
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Models")
                    .font(.title2.bold())
                Spacer()
                Button("Refresh model list", action: refreshModels)
            }

            CodexRoleRoutingFields(
                opus: $opus,
                sonnet: $sonnet,
                haiku: $haiku,
                availableModels: availableModels
            )

            Text("1M context passes the requested value only. Actual support depends on the Codex account, model, OAuth session, and CLIProxyAPI support.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        let codex = CodexRoleRoutingOptions.normalizedCodex(
                            AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
                            options: availableModels
                        )
                        try save(codex)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: ProviderSettingsSheetMetrics.codexWidth)
        .settingsErrorAlert(message: $errorMessage)
    }
}

struct PermissionsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool
    @State private var errorMessage: String?
    let save: (Bool) throws -> Void

    init(isEnabled: Bool, save: @escaping (Bool) throws -> Void) {
        _isEnabled = State(initialValue: isEnabled)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())
            Toggle("Use --dangerously-skip-permissions", isOn: $isEnabled)
            if isEnabled {
                Text("This option skips Claude Code permission prompts. Use it only for trusted local work.")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        try save(isEnabled)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .settingsErrorAlert(message: $errorMessage)
    }
}

struct ShellInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    let commandsSummary: String
    let install: () throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shell Install")
                .font(.title2.bold())
            Text("Functions to install: \(commandsSummary)")
            Text("Creates ~/.cliproxy-manager/functions.zsh and only adds or updates the CLIProxyAPI Manager managed block in ~/.zshrc.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Install / Update") {
                    do {
                        try install()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .settingsErrorAlert(title: "Install Failed", message: $errorMessage)
    }
}
