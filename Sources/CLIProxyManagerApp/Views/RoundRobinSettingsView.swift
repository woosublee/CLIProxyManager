import CLIProxyManagerCore
import SwiftUI

func roundRobinProviderTitle(_ provider: AuthProfileType) -> String {
    switch provider {
    case .codex:
        return "Codex round-robin"
    case .claude:
        return "Claude round-robin"
    }
}

func roundRobinModelDescription(provider: AuthProfileType) -> String {
    switch provider {
    case .codex:
        return "These model settings belong to the round-robin command. Only the account prefix changes between sessions."
    case .claude:
        return "Claude OAuth round-robin uses the default Claude OAuth model mappings. Only the account prefix changes between sessions."
    }
}

func roundRobinShowsConfigurationDetails(isEnabled: Bool) -> Bool {
    isEnabled
}

func roundRobinSavesImmediatelyAfterToggle(previousIsEnabled: Bool, newIsEnabled: Bool) -> Bool {
    previousIsEnabled && !newIsEnabled
}

struct RoundRobinSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 12) {
            RoundRobinProviderSettingsCard(viewModel: viewModel, provider: .codex)
            RoundRobinProviderSettingsCard(viewModel: viewModel, provider: .claude)
        }
    }
}

private struct RoundRobinProviderSettingsCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let provider: AuthProfileType
    @State private var state: RoundRobinSettingsState
    @State private var commandNameCheckState: CommandNameAvailability = .available
    @State private var codexModels: [CodexModelOption] = []

    init(viewModel: DashboardViewModel, provider: AuthProfileType) {
        self.viewModel = viewModel
        self.provider = provider
        _state = State(initialValue: viewModel.roundRobinSettings(for: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if roundRobinShowsConfigurationDetails(isEnabled: state.profile.isEnabled) {
                availabilityMessage
                commandNameField
                accountSelection
                modelSettings
                permissionsToggle
                saveButton
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10, opacity: 0.04)
        .task(id: state.profile.commandName) {
            await updateCommandAvailability()
        }
        .task(id: state.profile.includedAuthProfileIDs.joined(separator: "\u{1f}") ) {
            await updateCodexModels()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(roundRobinProviderTitle(provider))
                    .font(.caption.weight(.semibold))
                Text("Start each new CLI session with the next selected account. The chosen account stays fixed for that session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.profile.isEnabled },
                set: { value in
                    let previousValue = state.profile.isEnabled
                    state.profile.isEnabled = value
                    if roundRobinSavesImmediatelyAfterToggle(previousIsEnabled: previousValue, newIsEnabled: value) {
                        saveCurrentSettings()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SettingsToggleStyle())
            .disabled(!state.availability.canEnable && !state.profile.isEnabled)
        }
    }

    private var availabilityMessage: some View {
        Text(state.availability.message)
            .font(.caption2.weight(.medium))
            .foregroundStyle(state.availability.canEnable ? BrandPalette.statusRunning : BrandPalette.statusError)
    }

    private var commandNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("function_name", text: Binding(
                get: { state.profile.commandName },
                set: { state.profile.commandName = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            if case .unavailable(let message) = commandNameCheckState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(BrandPalette.statusError)
            }
        }
    }

    private var accountSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accounts")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.accountOptions) { option in
                Toggle(isOn: accountBinding(for: option)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.caption)
                        Text(option.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!option.isEnabled || (!option.hasPrefix && !state.profile.includedAuthProfileIDs.contains(option.id)))
            }
        }
    }

    @ViewBuilder
    private var modelSettings: some View {
        Text(roundRobinModelDescription(provider: provider))
            .font(.caption2)
            .foregroundStyle(.secondary)

        if provider == .codex {
            CodexRoundRobinRoleFields(profile: $state.profile, availableModels: codexModels)
        }
    }

    private var permissionsToggle: some View {
        Toggle(isOn: Binding(
            get: { state.profile.dangerousPermissionsEnabled },
            set: { state.profile.dangerousPermissionsEnabled = $0 }
        )) {
            Text("Skip permission prompts")
                .font(.caption)
        }
    }

    private var saveButton: some View {
        HStack {
            Spacer()
            Button("Save") {
                saveCurrentSettings()
            }
            .disabled(state.profile.isEnabled && (state.profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandNameCheckState != .available))
        }
    }

    private func saveCurrentSettings() {
        let didSave = viewModel.saveSetting { try viewModel.saveRoundRobinSettings(state) }
        if didSave {
            state = viewModel.roundRobinSettings(for: provider)
        }
    }

    private func accountBinding(for option: RoundRobinAccountOption) -> Binding<Bool> {
        Binding(
            get: { state.profile.includedAuthProfileIDs.contains(option.id) },
            set: { isSelected in
                if isSelected {
                    if !state.profile.includedAuthProfileIDs.contains(option.id) {
                        state.profile.includedAuthProfileIDs.append(option.id)
                    }
                } else {
                    state.profile.includedAuthProfileIDs.removeAll { $0 == option.id }
                }
                state = viewModel.roundRobinSettings(updating: state.profile)
                Task { await updateCodexModels() }
            }
        )
    }

    private func updateCodexModels() async {
        guard provider == .codex else { return }
        await viewModel.refreshCodexModels()
        do {
            codexModels = try await viewModel.codexModels(forRoundRobinProfile: state.profile)
        } catch {
            codexModels = []
        }
    }

    private func updateCommandAvailability() async {
        guard !state.profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commandNameCheckState = await viewModel.roundRobinCommandNameAvailability(profileID: state.profile.id, functionName: state.profile.commandName)
    }
}

private struct CodexRoundRobinRoleFields: View {
    @Binding var profile: AppConfig.RoundRobinProfile
    let availableModels: [CodexModelOption]

    var body: some View {
        CodexRoleRoutingFields(
            opus: Binding(get: { codex.opus }, set: { update(\.opus, to: $0) }),
            sonnet: Binding(get: { codex.sonnet }, set: { update(\.sonnet, to: $0) }),
            haiku: Binding(get: { codex.haiku }, set: { update(\.haiku, to: $0) }),
            availableModels: availableModels
        )
    }

    private var codex: AppConfig.Codex {
        profile.codex ?? AppConfig.default.ccodex
    }

    private func update(_ keyPath: WritableKeyPath<AppConfig.Codex, AppConfig.CodexRole>, to value: AppConfig.CodexRole) {
        var updated = codex
        updated[keyPath: keyPath] = value
        profile.codex = updated
    }
}
