import CLIProxyManagerCore
import SwiftUI

struct PortSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var portText: String
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
            Text("1024부터 65535 사이의 빈 포트를 사용하세요. 기존 8317과 분리하려면 18317을 권장합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            actionButtons {
                guard let port = Int(portText) else { return }
                try? save(port)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func actionButtons(saveAction: @escaping () -> Void) -> some View {
        HStack {
            Button("기본값") { portText = "18317" }
            Spacer()
            Button("취소") { dismiss() }
            Button("저장") {
                saveAction()
                dismiss()
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
            Text("zsh function으로 안전한 이름만 사용할 수 있습니다. 기존 alias와 충돌하면 설치가 중단됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            footer {
                try? save(AppConfig.Commands(cc: cc, ccapi: ccapi, ccodex: ccodex))
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func footer(saveAction: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("취소") { dismiss() }
            Button("저장") {
                saveAction()
                dismiss()
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
                Button("모델 목록 새로고침", action: refreshModels)
            }

            TextField("Claude API model", text: $claudeModel)
                .textFieldStyle(.roundedBorder)

            roleEditor(title: "Opus role", role: $opus)
            roleEditor(title: "Sonnet role", role: $sonnet)
            roleEditor(title: "Haiku role", role: $haiku)

            Text("1M context는 요청값만 전달합니다. 실제 지원 여부는 Codex 계정, 모델, OAuth 세션, CLIProxyAPI 지원 여부에 따라 달라집니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장") {
                    try? save(
                        AppConfig.ClaudeAPI(model: claudeModel),
                        AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
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
    let save: (Bool) throws -> Void

    init(isEnabled: Bool, save: @escaping (Bool) throws -> Void) {
        _isEnabled = State(initialValue: isEnabled)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())
            Toggle("--dangerously-skip-permissions 사용", isOn: $isEnabled)
            if isEnabled {
                Text("이 옵션은 Claude Code의 권한 확인을 건너뛰므로 신뢰하는 로컬 작업에만 사용하세요.")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장") {
                    try? save(isEnabled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct ShellInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let commandsSummary: String
    let install: () throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shell Install")
                .font(.title2.bold())
            Text("설치될 함수: \(commandsSummary)")
            Text("~/.cliproxy-manager/functions.zsh를 생성하고, ~/.zshrc에는 CLIProxyAPI Manager managed block만 추가하거나 갱신합니다.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("Install / Update") {
                    try? install()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
