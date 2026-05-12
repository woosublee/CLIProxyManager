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
            TextField("18317", text: $portText)
                .textFieldStyle(.roundedBorder)
            Text("Use an available port between 1024 and 65535. Use 18317 to keep it separate from the legacy 8317 port.")
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
            Button("Default") { portText = "18317" }
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

struct ShellFunctionsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cc: String
    @State private var ccapi: String
    @State private var ccodex: String
    @State private var errorMessage: String?
    let save: (AppConfig.Commands) throws -> Void

    init(commands: AppConfig.Commands, save: @escaping (AppConfig.Commands) throws -> Void) {
        _cc = State(initialValue: commands.cc)
        _ccapi = State(initialValue: commands.ccapi)
        _ccodex = State(initialValue: commands.ccodex)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shell Functions")
                .font(.title2.bold())
            TextField("Claude subscription", text: $cc)
                .textFieldStyle(.roundedBorder)
            TextField("Claude API", text: $ccapi)
                .textFieldStyle(.roundedBorder)
            TextField("Codex proxy", text: $ccodex)
                .textFieldStyle(.roundedBorder)
            Text("Use only names that are safe for zsh functions. Installation stops if a name conflicts with an existing alias.")
                .font(.callout)
                .foregroundStyle(.secondary)
            footer {
                try save(AppConfig.Commands(cc: cc, ccapi: ccapi, ccodex: ccodex))
            }
        }
        .padding(24)
        .frame(width: 460)
        .settingsErrorAlert(message: $errorMessage)
    }

    private func footer(saveAction: @escaping () throws -> Void) -> some View {
        HStack {
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
    @State private var claudeModel: String
    @State private var opus: AppConfig.CodexRole
    @State private var sonnet: AppConfig.CodexRole
    @State private var haiku: AppConfig.CodexRole
    @State private var errorMessage: String?
    let availableModels: [String]
    let refreshModels: () -> Void
    let save: (AppConfig.ClaudeAPI, AppConfig.Codex) throws -> Void

    init(
        config: AppConfig,
        availableModels: [String],
        refreshModels: @escaping () -> Void,
        save: @escaping (AppConfig.ClaudeAPI, AppConfig.Codex) throws -> Void
    ) {
        _claudeModel = State(initialValue: config.ccapi.model)
        _opus = State(initialValue: config.ccodex.opus)
        _sonnet = State(initialValue: config.ccodex.sonnet)
        _haiku = State(initialValue: config.ccodex.haiku)
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

            TextField("Claude API model", text: $claudeModel)
                .textFieldStyle(.roundedBorder)

            roleEditor(title: "Opus role", role: $opus)
            roleEditor(title: "Sonnet role", role: $sonnet)
            roleEditor(title: "Haiku role", role: $haiku)

            Text("1M context passes the requested value only. Actual support depends on the Codex account, model, OAuth session, and CLIProxyAPI support.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        try save(
                            AppConfig.ClaudeAPI(model: claudeModel),
                            AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku)
                        )
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .settingsErrorAlert(message: $errorMessage)
    }

    private func roleEditor(title: String, role: Binding<AppConfig.CodexRole>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            HStack {
                if availableModels.isEmpty {
                    TextField("Model", text: role.model)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Model", selection: role.model) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .frame(width: 180)
                }

                Picker("Reasoning", selection: role.reasoning) {
                    ForEach(AppConfig.CodexReasoning.allCases, id: \.self) { reasoning in
                        Text(reasoning.rawValue).tag(reasoning)
                    }
                }
                .frame(width: 170)

                Picker("Context", selection: role.contextWindow) {
                    ForEach(AppConfig.CodexContextWindow.allCases, id: \.self) { context in
                        Text(context.rawValue).tag(context)
                    }
                }
                .frame(width: 140)
            }
        }
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
