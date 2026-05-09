import CLIProxyManagerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Appearance") {
                SettingsRow(label: "Appearance", description: "Follow the system theme for now.", isEnabled: false) {
                    SettingsSegmentedControl(options: ["System", "Light", "Dark"], selected: "System")
                }
                SettingsRow(label: "Language", description: "Language switching is a design placeholder.", isEnabled: false) {
                    SettingsSegmentedControl(options: ["English", "한국어"], selected: "English")
                }
            }

            SettingsGroup(title: "Behavior") {
                SettingsRow(label: "Start at login", description: "Launch CLIProxyManager automatically after signing in.") {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.startAtLogin },
                        set: { value in try? viewModel.saveStartAtLogin(value) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Show Dock icon", description: "Keep the app visible in the macOS Dock.") {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.showDockIcon },
                        set: { value in try? viewModel.saveDockIconVisible(value) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Show menu bar icon", description: "Show the compact status menu in the menu bar.") {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.showMenuBarIcon },
                        set: { value in try? viewModel.saveMenuBarIconVisible(value) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Notifications", description: "OAuth and server status notifications are not wired yet.", isEnabled: false) {
                    Toggle("", isOn: .constant(true))
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
    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Server") {
                SettingsRow(label: viewModel.serverStatus.title, description: viewModel.serverStatus.message) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.serverStatus.severity == .ready },
                        set: { isOn in Task { await viewModel.setServerEnabled(isOn) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                    .disabled(viewModel.isServerActionInProgress)
                }
                SettingsRow(label: "Port", description: "Local CLIProxyAPI listening port.") {
                    HStack(spacing: 8) {
                        TextField("18317", text: Binding(
                            get: { portText.isEmpty ? String(viewModel.config.port) : portText },
                            set: { portText = $0 }
                        ))
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        Button("Save") {
                            if let port = Int(portText.isEmpty ? String(viewModel.config.port) : portText) {
                                try? viewModel.savePort(port)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                SettingsRow(label: "Restart", description: "Restart the bundled proxy runtime with the current settings.") {
                    Button("Restart") {
                        Task { await viewModel.restartServer() }
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isServerActionInProgress)
                }
                SettingsRow(label: "Bind address", description: "Network bind selection is a design placeholder.", isEnabled: false) {
                    SettingsSegmentedControl(options: ["127.0.0.1", "0.0.0.0"], selected: "127.0.0.1")
                }
                SettingsRow(label: "Autostart server", description: "Automatic server start will be wired later.", isEnabled: false) {
                    Toggle("", isOn: .constant(false))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
            }

            SettingsGroup(title: "Routing") {
                SettingsRow(label: "Round robin", description: "Multi-account routing is a design placeholder.", isEnabled: false) {
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
    @State private var activeSheet: AdvancedSettingsSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Shell") {
                SettingsRow(label: "Install status", description: "Current shell integration state.") {
                    Text(viewModel.optionRows.first { $0.id == "install" }?.value ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SettingsRow(label: "Shell functions", description: "Review or reinstall the generated launcher functions.") {
                    HStack(spacing: 8) {
                        Button("View…") { activeSheet = .functions }
                            .controlSize(.small)
                        Button("Reinstall") { try? viewModel.installShellFunctions() }
                            .controlSize(.small)
                    }
                }
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsRow(label: "Log level", description: "Detailed log level control is a design placeholder.", isEnabled: false) {
                    SettingsSegmentedControl(options: ["Error", "Warn", "Info", "Debug"], selected: "Info")
                }
                SettingsRow(label: "Reveal logs", description: "Log folder reveal action will be wired later.", isEnabled: false) {
                    Button("Reveal") {}
                        .controlSize(.small)
                }
            }

            SettingsGroup(title: "Models and permissions") {
                SettingsRow(label: "Models", description: "Configure default model mappings.") {
                    Button("Models…") { activeSheet = .models }
                        .controlSize(.small)
                }
                SettingsRow(label: "Permissions", description: "Opt in to dangerous skip-permissions launch arguments.") {
                    Button("Permissions…") { activeSheet = .permissions }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .functions:
                ShellFunctionsSettingsSheet(commands: viewModel.config.commands) { try viewModel.saveCommands($0) }
            case .models:
                ModelsSettingsSheet(
                    config: viewModel.config,
                    availableModels: viewModel.availableCodexModels,
                    refreshModels: { Task { await viewModel.loadCodexModels() } },
                    save: { ccapi, ccodex in try viewModel.saveModels(ccapi: ccapi, ccodex: ccodex) }
                )
            case .permissions:
                PermissionsSettingsSheet(isEnabled: viewModel.config.includeDangerouslySkipPermissions) {
                    try viewModel.saveDangerousPermissionsEnabled($0)
                }
            }
        }
    }
}

private enum AdvancedSettingsSheet: Identifiable {
    case functions
    case models
    case permissions

    var id: String { String(describing: self) }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "About") {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                    Text("CLIProxyManager")
                        .font(.title2.bold())
                    Text("CLIProxyAPI Manager for Claude Code profiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            SettingsGroup(title: "Updates") {
                SettingsRow(label: "Automatically check for updates", description: "Updater integration is a design placeholder.", isEnabled: false) {
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .toggleStyle(SettingsToggleStyle())
                }
            }

            SettingsGroup(title: "Licenses") {
                LicensesView()
                    .frame(minHeight: 220)
                    .padding(12)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}
