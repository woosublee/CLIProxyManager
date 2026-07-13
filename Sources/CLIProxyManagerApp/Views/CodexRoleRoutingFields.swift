import CLIProxyManagerCore
import SwiftUI

struct CodexRoleRoutingFields: View {
    @Binding var opus: AppConfig.CodexRole
    @Binding var sonnet: AppConfig.CodexRole
    @Binding var haiku: AppConfig.CodexRole
    let availableModels: [CodexModelOption]
    private let fastColumnWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                header
                Divider().padding(.leading, 14)
                row(label: "Opus", role: $opus, last: false)
                row(label: "Sonnet", role: $sonnet, last: false)
                row(label: "Haiku", role: $haiku, last: true)
            }

            Text(CodexRoleRoutingOptions.fastModeHelpText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
        .task(id: availableModels) {
            normalizeRoles(for: availableModels)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude")
                .frame(width: 64, alignment: .leading)
            Text("GPT model")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Reasoning")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Context")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Fast")
                .frame(width: fastColumnWidth, alignment: .center)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func row(label: String, role: Binding<AppConfig.CodexRole>, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 64, alignment: .leading)

                Picker("", selection: modelBinding(for: role)) {
                    ForEach(
                        CodexRoleRoutingOptions.modelIDs(
                            currentModel: role.wrappedValue.model,
                            options: availableModels
                        ),
                        id: \.self
                    ) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: role.reasoning) {
                    ForEach(
                        CodexRoleRoutingOptions.reasoningValues(
                            currentReasoning: role.wrappedValue.reasoning,
                            model: role.wrappedValue.model,
                            options: availableModels
                        ),
                        id: \.self
                    ) { reasoning in
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

                Toggle("", isOn: fastModeBinding(for: role))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(BrandPalette.accent)
                    .controlSize(.small)
                    .frame(width: fastColumnWidth, alignment: .center)
                    .disabled(!CodexRoleRoutingOptions.supportsFastMode(
                        model: role.wrappedValue.model,
                        options: availableModels
                    ))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if !last {
                Divider().padding(.leading, 14)
            }
        }
    }

    private func normalizeRoles(for models: [CodexModelOption]) {
        guard !models.isEmpty else { return }
        let normalized = CodexRoleRoutingOptions.normalizedCodex(
            AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
            options: models
        )
        opus = normalized.opus
        sonnet = normalized.sonnet
        haiku = normalized.haiku
    }

    private func modelBinding(for role: Binding<AppConfig.CodexRole>) -> Binding<String> {
        Binding(
            get: { CodexFastMode.canonicalModel(from: role.wrappedValue.model) },
            set: { model in
                role.wrappedValue = CodexRoleRoutingOptions.normalizedRole(
                    role.wrappedValue,
                    model: model,
                    options: availableModels
                )
            }
        )
    }

    private func fastModeBinding(for role: Binding<AppConfig.CodexRole>) -> Binding<Bool> {
        CodexRoleRoutingOptions.fastModeBinding(role: role, options: availableModels)
    }
}
