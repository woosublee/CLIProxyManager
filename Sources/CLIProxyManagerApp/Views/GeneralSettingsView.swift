import CLIProxyManagerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Appearance") {
                SettingsRow(label: "Appearance", description: "Match the macOS system theme or pick one.") {
                    AppearancePicker(
                        selection: viewModel.config.appearance,
                        onChange: { mode in viewModel.saveSetting { try viewModel.saveAppearance(mode) } }
                    )
                }
                SettingsRow(label: "Language", description: "Language switching is a design placeholder.", isEnabled: false) {
                    SettingsSegmentedControl(options: ["English", "한국어"], selected: "English")
                }
            }

            SettingsGroup(title: "Behavior") {
                SettingsRow(label: "Launch at login", description: "Start CLIProxyManager when you log in.") {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.startAtLogin },
                        set: { value in viewModel.saveSetting { try viewModel.saveStartAtLogin(value) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Menu bar only", description: "Hide the Dock icon — runs as a menu bar app.") {
                    Toggle("", isOn: Binding(
                        get: { !viewModel.config.showDockIcon },
                        set: { value in viewModel.saveSetting { try viewModel.saveMenuBarOnly(value) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Show notifications", description: "Notification delivery is a design placeholder.", isEnabled: false) {
                    Toggle("", isOn: .constant(false))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

struct ServerSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Server") {
                SettingsRow(label: "Listen port", description: "Local port the proxy server binds to.") {
                    SettingsStepper(
                        value: Binding(
                            get: { viewModel.config.port },
                            set: { _ in }
                        ),
                        range: 1024...65_535,
                        commit: { newPort in
                            let didSave = viewModel.saveSetting { try viewModel.savePort(newPort) }
                            if didSave, viewModel.serverControlState.isRunning, !viewModel.isServerActionInProgress {
                                Task { await viewModel.restartServer() }
                            }
                        }
                    )
                }
                SettingsRow(label: "Bind address", description: "Use 0.0.0.0 to allow access from other devices on the LAN.") {
                    SettingsSegmentedPicker(
                        options: [
                            (value: "127.0.0.1", label: "127.0.0.1"),
                            (value: "0.0.0.0", label: "0.0.0.0")
                        ],
                        selection: Binding(
                            get: { viewModel.config.bindAddress },
                            set: { newValue in
                                viewModel.saveSetting { try viewModel.saveBindAddress(newValue) }
                            }
                        )
                    )
                }
                SettingsRow(label: "Start server on launch", description: "Automatically begin proxying when the app opens.") {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.autostartServer },
                        set: { value in viewModel.saveSetting { try viewModel.saveAutostartServer(value) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
            }

            SettingsGroup(title: "Routing") {
                SettingsRow(label: "Round-robin balancing", description: "Distribute requests across connected accounts of the same provider.", isEnabled: false) {
                    Toggle("", isOn: .constant(false))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var confirmReset: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Advanced") {
                SettingsRow(label: "Log level", description: "Verbosity for in-app logs and the diagnostics file.") {
                    SettingsSegmentedPicker<LogLevel>(
                        options: [
                            (value: .error, label: "Error"),
                            (value: .warn, label: "Warn"),
                            (value: .info, label: "Info"),
                            (value: .debug, label: "Debug")
                        ],
                        selection: Binding(
                            get: { viewModel.config.logLevel },
                            set: { newValue in
                                viewModel.saveSetting { try viewModel.saveLogLevel(newValue) }
                            }
                        )
                    )
                }
                SettingsRow(label: "Diagnostics", description: "Reveal log file in Finder for troubleshooting.") {
                    Button("Reveal") {
                        viewModel.revealLogsInFinder()
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup(title: "Reset") {
                SettingsRow(label: "Reset all settings", description: "Clears preferences but keeps connected accounts.") {
                    Button(action: { confirmReset = true }) {
                        Text("Reset…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BrandPalette.statusError)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                viewModel.resetAllSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Preferences (appearance, server, behavior) will return to defaults. Connected accounts and command names are preserved.")
        }
    }
}

func aboutVersionText(bundle: Bundle = .main) -> String {
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.2(beta)"
    let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "3"
    return "Version \(version) (\(build))"
}

struct AboutSettingsView: View {
    @State private var showLicenses: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                AppIconView(size: 72)
                VStack(spacing: 4) {
                    Text("CLIProxyManager")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Built for the people who proxy")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(verbatim: aboutVersionText())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            SettingsGroup(title: "Updates") {
                SettingsRow(label: "Check for updates", description: "Automatically check for new versions on launch.", isEnabled: false) {
                    Toggle("", isOn: .constant(false))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Check now", description: "Updater integration is a design placeholder.", isEnabled: false) {
                    Button("Check now") {}
                        .controlSize(.small)
                }
            }

            VStack(spacing: 6) {
                Text(verbatim: "© 2026 CLIProxyManager")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Text("Includes CLIProxyAPI — MIT license.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button("View") {
                        showLicenses = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .sheet(isPresented: $showLicenses) {
            LicensesSheet(onClose: { showLicenses = false })
        }
    }
}
