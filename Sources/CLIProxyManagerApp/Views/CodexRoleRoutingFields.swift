import CLIProxyManagerCore
import SwiftUI

struct CodexRoleRoutingFields: View {
    @Binding var opus: AppConfig.CodexRole
    @Binding var sonnet: AppConfig.CodexRole
    @Binding var haiku: AppConfig.CodexRole
    let availableModels: [String]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.leading, 14)
            row(label: "Opus", role: $opus, last: false)
            row(label: "Sonnet", role: $sonnet, last: false)
            row(label: "Haiku", role: $haiku, last: true)
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
}
