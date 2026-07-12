import CLIProxyManagerCore
import SwiftUI

struct ClaudeRoleRoutingFields: View {
    @Binding var routing: ClaudeRouting
    let options: [ClaudeModelOption]

    var body: some View {
        GroupCard {
            ClaudeModelRoleRow(
                label: "Opus",
                role: .opus,
                selection: $routing.opus,
                options: options,
                isLast: false
            )
            ClaudeModelRoleRow(
                label: "Sonnet",
                role: .sonnet,
                selection: $routing.sonnet,
                options: options,
                isLast: false
            )
            ClaudeModelRoleRow(
                label: "Haiku",
                role: .haiku,
                selection: $routing.haiku,
                options: options,
                isLast: true
            )
        }
    }
}

private struct ClaudeModelRoleRow: View {
    let label: String
    let role: ClaudeModelFamily
    @Binding var selection: ClaudeModelSelection
    let options: [ClaudeModelOption]
    let isLast: Bool

    var body: some View {
        CardRow(
            label: label,
            description: "Select Automatic to use this account’s latest available \(label) model.",
            isLast: isLast
        ) {
            Picker(label, selection: $selection) {
                ForEach(ClaudeRoleRoutingOptions.rows(
                    role: role,
                    selection: selection,
                    options: options
                )) { row in
                    Text(row.label).tag(row.selection)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: ProviderSettingsSheetMetrics.claudeModelPickerWidth, alignment: .leading)
        }
    }
}
