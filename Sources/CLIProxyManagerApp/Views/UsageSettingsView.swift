import CLIProxyManagerCore
import SwiftUI

enum UsageSettingsCopy {
    static let menuBarLabel = "Show subscription usage"
    static let menuBarDescription = "Show Claude and Codex account usage beneath connected accounts in the menu bar."
    static let hudLabel = "Show usage HUD"
    static let hudDescription = "Keep subscription usage visible in a separate window."
    static let footer = "Usage data is fetched whenever the menu bar display or Usage HUD is enabled. CLIProxyManager manages the local management key automatically."
}

struct UsageSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    private func usageOverlayBinding<Value>(_ keyPath: WritableKeyPath<AppConfig.UsageOverlay, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.config.usageOverlay[keyPath: keyPath] },
            set: { value in
                var usageOverlay = viewModel.config.usageOverlay
                usageOverlay[keyPath: keyPath] = value
                viewModel.saveSetting { try viewModel.saveUsageOverlay(usageOverlay) }
            }
        )
    }

    private var usageOverlayOpacityBinding: Binding<Double> {
        Binding(
            get: { viewModel.config.usageOverlay.backgroundOpacity },
            set: { viewModel.previewUsageOverlayBackgroundOpacity($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Menu Bar") {
                SettingsRow(
                    label: UsageSettingsCopy.menuBarLabel,
                    description: UsageSettingsCopy.menuBarDescription
                ) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.subscriptionUsage.showInMenuBar },
                        set: { value in
                            viewModel.saveSetting {
                                try viewModel.saveSubscriptionUsageMenuBarVisible(value)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
            }

            SettingsGroup(title: "Usage HUD") {
                SettingsRow(label: UsageSettingsCopy.hudLabel, description: UsageSettingsCopy.hudDescription) {
                    Toggle("", isOn: usageOverlayBinding(\.isVisible))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(
                    label: "Always on top",
                    description: "Keep the usage HUD above other windows.",
                    isEnabled: viewModel.config.usageOverlay.isVisible
                ) {
                    Toggle("", isOn: usageOverlayBinding(\.alwaysOnTop))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(
                    label: "Background opacity",
                    description: "Adjust the usage HUD background transparency.",
                    isEnabled: viewModel.config.usageOverlay.isVisible
                ) {
                    Slider(
                        value: usageOverlayOpacityBinding,
                        in: 0.2...1,
                        step: 0.05,
                        onEditingChanged: { isEditing in
                            guard !isEditing else { return }
                            viewModel.saveSetting {
                                try viewModel.saveUsageOverlay(viewModel.config.usageOverlay)
                            }
                        }
                    )
                    .frame(width: 136)
                }
            }

            Text(UsageSettingsCopy.footer)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 12)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}
