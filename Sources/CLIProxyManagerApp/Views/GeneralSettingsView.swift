import CLIProxyManagerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var confirmRemoveCPM = false

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
                    SettingsSegmentedControl(options: ["English", "Korean"], selected: "English")
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

            SettingsGroup(title: "Command Line") {
                SettingsRow(label: "cpm", description: cpmDescription) {
                    if viewModel.isCPMInstallationActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        switch viewModel.cpmInstallationStatus {
                        case .notInstalled:
                            Button("Install cpm") {
                                Task { await viewModel.installOrUpdateCPM() }
                            }
                            .controlSize(.small)
                        case .installedCurrent, .installedOutdated:
                            HStack(spacing: 8) {
                                Button("Update cpm") {
                                    Task { await viewModel.installOrUpdateCPM() }
                                }
                                Button("Remove cpm…", role: .destructive) {
                                    confirmRemoveCPM = true
                                }
                            }
                            .controlSize(.small)
                        case .unmanaged:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .onAppear { viewModel.refreshCPMInstallationStatus() }
        .confirmationDialog(
            "Remove cpm?",
            isPresented: $confirmRemoveCPM,
            titleVisibility: .visible
        ) {
            Button("Remove cpm", role: .destructive) {
                Task { await viewModel.removeCPM() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only /usr/local/bin/cpm. Your app, accounts, proxy, and shell functions are unchanged.")
        }
    }

    private var cpmDescription: String {
        switch viewModel.cpmInstallationStatus {
        case .notInstalled:
            "Install cpm so it is available in Terminal and SSH sessions."
        case .installedCurrent(let version):
            "Installed at /usr/local/bin/cpm (version \(version))."
        case .installedOutdated(let installedVersion, let availableVersion):
            "Installed version \(installedVersion); app includes \(availableVersion)."
        case .unmanaged:
            "An existing cpm file is managed outside CLIProxyManager."
        }
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

            SettingsGroup(title: "Subscription Usage (Experimental)") {
                SettingsRow(
                    label: "Show subscription usage",
                    description: "Displays Claude and Codex account usage in the menu bar. A local management key is created in protected app-managed storage automatically and removed when this setting is turned off."
                ) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.config.subscriptionUsage.isEnabled },
                        set: { value in viewModel.saveSetting { try viewModel.saveSubscriptionUsageEnabled(value) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
            }

            SettingsGroup(title: "Routing") {
                RoundRobinSettingsView(viewModel: viewModel)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
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
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.2"
    let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "6"
    return "Version \(version) (\(build))"
}

func cliproxyAPIUpdateDescription(
    currentVersion: String,
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String {
    switch state {
    case .checking:
        return "Current version: \(currentVersion) · Checking for updates…"
    case .downloading:
        return "Current version: \(currentVersion) · Downloading and verifying update…"
    case .failed(let message):
        if message.isEmpty {
            return "Current version: \(currentVersion) · Last check failed."
        }
        return "Current version: \(currentVersion) · Last check failed: \(message)"
    default:
        break
    }
    if let pendingUpdate {
        return "Current version: \(currentVersion) · Pending version: \(pendingUpdate.version)"
    }
    if let availableUpdate {
        return "Current version: \(currentVersion) · Available version: \(availableUpdate.version.description)"
    }
    return "Current version: \(currentVersion)"
}

func cliproxyAPIUpdateActionTitle(
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String {
    if state == .checking { return "Checking…" }
    if state == .downloading { return "Updating…" }
    if let pendingUpdate { return "Apply \(pendingUpdate.version) now" }
    if let availableUpdate { return "Download \(availableUpdate.version.description)" }
    return "Check now"
}

func cliProxyAPIAvailableUpdatePromptTitle(
    currentVersion: String,
    availableUpdate: CLIProxyAPIRelease?
) -> String {
    guard let availableUpdate else { return "CLIProxyAPI update available" }
    return "Update CLIProxyAPI from \(currentVersion) to \(availableUpdate.version.description)?"
}

func cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: CLIProxyAPIBinaryManifest?) -> String {
    guard let pendingUpdate else { return "Apply CLIProxyAPI update?" }
    return "Apply CLIProxyAPI \(pendingUpdate.version)?"
}

func cliProxyAPIPendingUpdatePromptMessage(currentVersion: String) -> String {
    "Current version: \(currentVersion)"
}

func cliProxyAPIApplyButtonTitle(
    pendingUpdate: CLIProxyAPIBinaryManifest?,
    isServerRunning: Bool
) -> String {
    guard let pendingUpdate else {
        return isServerRunning ? "Apply now and restart server" : "Apply now"
    }
    if isServerRunning {
        return "Apply \(pendingUpdate.version) and restart server"
    }
    return "Apply \(pendingUpdate.version) now"
}

struct AboutSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    @State private var showLicenses: Bool = false
    @State private var showApplyPrompt = false

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
                SettingsRow(label: UpdateSettingsCopy.automaticChecksLabel, description: UpdateSettingsCopy.automaticChecksDescription) {
                    Toggle("", isOn: Binding(
                        get: { updaterService.automaticallyChecksForUpdates },
                        set: { updaterService.automaticallyChecksForUpdates = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: UpdateSettingsCopy.checkNowButtonTitle, description: "Check GitHub releases for a newer CLIProxyManager version.", isEnabled: updaterService.canCheckForUpdates) {
                    Button(UpdateSettingsCopy.checkNowButtonTitle) {
                        updaterService.checkForUpdates()
                    }
                    .controlSize(.small)
                }
                SettingsRow(
                    label: "CLIProxyAPI binary",
                    description: cliproxyAPIUpdateDescription(
                        currentVersion: cliProxyAPIUpdateService.currentVersionText,
                        state: cliProxyAPIUpdateService.state,
                        availableUpdate: cliProxyAPIUpdateService.availableUpdate,
                        pendingUpdate: cliProxyAPIUpdateService.pendingUpdate
                    ),
                    isEnabled: !cliProxyAPIUpdateService.isChecking && !cliProxyAPIUpdateService.isUpdating
                ) {
                    HStack(spacing: 8) {
                        if cliProxyAPIUpdateService.isChecking || cliProxyAPIUpdateService.isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(cliproxyAPIUpdateActionTitle(
                            state: cliProxyAPIUpdateService.state,
                            availableUpdate: cliProxyAPIUpdateService.availableUpdate,
                            pendingUpdate: cliProxyAPIUpdateService.pendingUpdate
                        )) {
                            if cliProxyAPIUpdateService.pendingUpdate != nil {
                                showApplyPrompt = true
                            } else if cliProxyAPIUpdateService.availableUpdate != nil {
                                Task {
                                    await cliProxyAPIUpdateService.downloadAvailableUpdate()
                                    if cliProxyAPIUpdateService.pendingUpdate != nil {
                                        showApplyPrompt = true
                                    } else if case let .failed(message) = cliProxyAPIUpdateService.state {
                                        viewModel.settingsMessage = "CLIProxyAPI update failed: \(message)"
                                    }
                                }
                            } else {
                                Task { await cliProxyAPIUpdateService.checkNow() }
                            }
                        }
                        .controlSize(.small)
                    }
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
        .confirmationDialog(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: cliProxyAPIUpdateService.pendingUpdate),
            isPresented: $showApplyPrompt,
            titleVisibility: .visible
        ) {
            Button(cliProxyAPIApplyButtonTitle(
                pendingUpdate: cliProxyAPIUpdateService.pendingUpdate,
                isServerRunning: viewModel.serverControlState.isRunning
            )) {
                Task { await viewModel.applyCLIProxyAPIPendingUpdate(using: cliProxyAPIUpdateService) }
            }
            Button("Apply on next server start") {
                viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cliProxyAPIPendingUpdatePromptMessage(currentVersion: cliProxyAPIUpdateService.currentVersionText))
        }
    }
}
