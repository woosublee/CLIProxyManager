import CLIProxyManagerCore
import SwiftUI

struct ClaudeOAuthProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var dangerousPermissionsEnabled: Bool
    let save: (String, Bool) throws -> Void

    init(config: AppConfig, save: @escaping (String, Bool) throws -> Void) {
        _functionName = State(initialValue: config.commands.cc)
        _dangerousPermissionsEnabled = State(initialValue: config.includeDangerouslySkipPermissions)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude OAuth")
                .font(.title2.bold())
            TextField("Function name", text: $functionName)
                .textFieldStyle(.roundedBorder)
            Toggle("--dangerously-skip-permissions 사용", isOn: $dangerousPermissionsEnabled)
            Text("이 옵션은 생성된 Claude CLI 실행 함수에 적용됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            footer
        }
        .padding(24)
        .frame(width: 460)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                try? save(functionName, dangerousPermissionsEnabled)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct ClaudeAPIProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var model: String
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
            footer
        }
        .padding(24)
        .frame(width: 460)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") {
                try? save(functionName, model)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct CodexProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var functionName: String
    @State private var opus: AppConfig.CodexRole
    @State private var sonnet: AppConfig.CodexRole
    @State private var haiku: AppConfig.CodexRole
    @State private var dangerousPermissionsEnabled: Bool
    let availableModels: [String]
    let refreshModels: () -> Void
    let save: (String, AppConfig.Codex, Bool) throws -> Void

    init(
        config: AppConfig,
        availableModels: [String],
        refreshModels: @escaping () -> Void,
        save: @escaping (String, AppConfig.Codex, Bool) throws -> Void
    ) {
        _functionName = State(initialValue: config.commands.ccodex)
        _opus = State(initialValue: config.ccodex.opus)
        _sonnet = State(initialValue: config.ccodex.sonnet)
        _haiku = State(initialValue: config.ccodex.haiku)
        _dangerousPermissionsEnabled = State(initialValue: config.includeDangerouslySkipPermissions)
        self.availableModels = availableModels
        self.refreshModels = refreshModels
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Codex")
                    .font(.title2.bold())
                Spacer()
                Button("Refresh Models", action: refreshModels)
            }

            TextField("Function name", text: $functionName)
                .textFieldStyle(.roundedBorder)

            Toggle("--dangerously-skip-permissions 사용", isOn: $dangerousPermissionsEnabled)
            Text("이 옵션은 생성된 Claude CLI 실행 함수에 적용됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            roleEditor(title: "Opus role", role: $opus)
            roleEditor(title: "Sonnet role", role: $sonnet)
            roleEditor(title: "Haiku role", role: $haiku)

            Text("1M context는 요청값만 전달합니다. 실제 지원 여부는 Codex 계정, 모델, OAuth 세션, CLIProxyAPI 지원 여부에 따라 달라집니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    try? save(functionName, AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku), dangerousPermissionsEnabled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task {
            if availableModels.isEmpty {
                refreshModels()
            }
        }
        .onChange(of: availableModels) { models in
            applyDefaultModel(from: models)
        }
    }

    private func applyDefaultModel(from models: [String]) {
        guard let firstModel = models.first else { return }
        if opus.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { opus.model = firstModel }
        if sonnet.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sonnet.model = firstModel }
        if haiku.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { haiku.model = firstModel }
    }

    private func roleEditor(title: String, role: Binding<AppConfig.CodexRole>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            HStack {
                Picker("Model", selection: role.model) {
                    ForEach(ModelSelectionOptions.options(currentModel: role.wrappedValue.model, availableModels: availableModels), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(width: 180)

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
