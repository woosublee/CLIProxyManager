# Provider Settings and Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the app named CLIProxyManager while reworking its main window into a macOS settings-style provider manager plus menu bar companion for provider connection state, function names, models, permissions, server controls, start-at-login, and Dock/menu bar visibility.

**Architecture:** Keep the config, shell renderer, health/model clients, app-managed server lifecycle, and shell install safety work already implemented. Replace the current 1-page option-row Dashboard with a settings-style main window, provider list, automatic shell install service, menu bar item, and quit confirmation flow.

**Tech Stack:** Swift 5.10, SwiftUI, Combine, AppKit/NSApplication, ServiceManagement, Foundation, XCTest, macOS menu bar APIs, local zsh profile files.

---

## Current State Notes

The current working tree already contains:

- App-managed defaults: port `18317`, functions `ccm`, `ccmapi`, `ccmcodex`
- Role-based Codex config: model, reasoning, context window
- `AppConfigStore`
- Authenticated `/v1/models` health/model checks
- Shell function conflict detection
- App-managed-only stop policy
- A temporary 1-page Dashboard UI

This plan replaces the temporary 1-page Dashboard UI with the user-requested provider-centric Settings UI and menu bar behavior.

Spec:

- `docs/superpowers/specs/2026-05-09-configurable-settings-install-design.md`

---

## File Structure

Create:

- `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
  - Provider row view state and provider identifiers.
- `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
  - Installs default shell functions on first launch and reapplies after settings changes.
- `Sources/CLIProxyManagerApp/Services/LoginItemService.swift`
  - Wraps start-at-login behavior.
- `Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift`
  - Applies Dock/menu bar visibility policy via activation policy where possible.
- `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
  - Settings-style main window: Providers, General, Licenses.
- `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
  - Provider list with `+` button and provider rows.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
  - Claude, Claude API, Codex provider settings sheets.
- `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - Port, server toggle, start-at-login, Dock/menu bar visibility, shell install status.
- `Sources/CLIProxyManagerApp/MenuBar/CLIProxyMenuBar.swift`
  - Menu bar item content and server start/stop/open settings/quit actions.
- `Sources/CLIProxyManagerApp/AppDelegate.swift`
  - AppKit delegate for close/quit behavior and confirmation.

Modify:

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - Add `startAtLogin`, `showDockIcon`, `showMenuBarIcon`.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Rename conceptually or extend into SettingsViewModel with provider rows and automatic shell install.
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - Replace with `SettingsView` usage or remove Dashboard naming from visible UI.
- `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
  - Add menu bar scene, Settings command behavior, app delegate, launch-time auto install.

Tests:

- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
- `Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift`
- Update `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` or migrate assertions to SettingsViewModel tests.

---

### Task 1: Extend config for app behavior options

**Files:**

- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

- [ ] **Step 1: Write failing config tests**

Add assertions:

```swift
XCTAssertFalse(config.startAtLogin)
XCTAssertTrue(config.showDockIcon)
XCTAssertTrue(config.showMenuBarIcon)
```

Add round-trip values in `AppConfigStoreTests`:

```swift
startAtLogin: true,
showDockIcon: false,
showMenuBarIcon: true
```

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AppConfigTests
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AppConfigStoreTests
```

Expected: FAIL because fields do not exist.

- [ ] **Step 3: Implement fields**

Add to `AppConfig`:

```swift
public var startAtLogin: Bool
public var showDockIcon: Bool
public var showMenuBarIcon: Bool
```

Update initializer and `.default`:

```swift
startAtLogin: false,
showDockIcon: true,
showMenuBarIcon: true
```

- [ ] **Step 4: Update all `AppConfig(...)` call sites**

Every explicit `AppConfig` construction must include:

```swift
startAtLogin: false,
showDockIcon: true,
showMenuBarIcon: true
```

- [ ] **Step 5: Verify**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AppConfigTests
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AppConfigStoreTests
```

Expected: PASS.

---

### Task 2: Add provider row state and SettingsViewModel provider actions

**Files:**

- Create: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Create: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`

- [ ] **Step 1: Write failing provider row tests**

Create tests that assert:

```swift
XCTAssertEqual(viewModel.providerRows.map(\.name), ["Claude", "Claude API", "Codex"])
XCTAssertEqual(viewModel.providerRows.map(\.functionName), ["ccm", "ccmapi", "ccmcodex"])
```

Add tests for `+` action:

```swift
viewModel.addProvider()
XCTAssertEqual(viewModel.settingsMessage, "추가 provider는 추후 지원됩니다.")
```

Add tests for provider settings save:

```swift
try viewModel.saveClaudeFunctionName("myclaude")
try viewModel.saveClaudeAPISettings(functionName: "myapi", model: "claude-sonnet-4-6", permissionMode: .safe)
try viewModel.saveCodexSettings(...)
```

Expected: config saves and automatic shell install is invoked.

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProviderSettingsViewModelTests
```

Expected: FAIL because provider state/actions do not exist.

- [ ] **Step 3: Add provider state model**

Create:

```swift
import CLIProxyManagerCore

struct ProviderRowState: Identifiable, Equatable {
    enum ID: String {
        case claude
        case claudeAPI
        case codex
    }

    let id: ID
    let name: String
    let functionName: String
    let connectionTitle: String
    let connectionDetail: String
    let isConnected: Bool
}
```

- [ ] **Step 4: Add provider rows to ViewModel**

Add:

```swift
@Published var providerRows: [ProviderRowState] = []
```

Add `rebuildProviderRows(claudeStatus:codexStatus:)` mapping:

- Claude → `config.commands.cc`
- Claude API → `config.commands.ccapi`
- Codex → `config.commands.ccodex`

Connection state can initially use existing statuses:

- Claude status from `ClaudeConnector.status()`
- Claude API key state can be “확인 필요” until Keychain check is wired.
- Codex status from `ProxyHealthClient.status(port:)`

- [ ] **Step 5: Add provider actions**

Add:

```swift
func addProvider() {
    settingsMessage = "추가 provider는 추후 지원됩니다."
}
```

Add save methods that update config then call automatic shell install hook:

```swift
func saveClaudeFunctionName(_ functionName: String) throws
func saveClaudeAPISettings(functionName: String, model: String, permissionMode: PermissionMode) throws
func saveCodexSettings(functionName: String, codex: AppConfig.Codex, permissionMode: PermissionMode) throws
```

If introducing `PermissionMode` is too large, keep using existing `includeDangerouslySkipPermissions` for MVP and expose safe/dangerous globally.

- [ ] **Step 6: Verify**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProviderSettingsViewModelTests
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter DashboardViewModelRefreshTests
```

Expected: PASS.

---

### Task 3: Add automatic shell install service

**Files:**

- Create: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Create: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`

- [ ] **Step 1: Write failing tests**

Tests:

- First launch calls renderer + installer with default names.
- Config change calls install again.
- Conflict error is surfaced as settings message.

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AutomaticShellInstallServiceTests
```

Expected: FAIL because service does not exist.

- [ ] **Step 3: Implement service**

Create service:

```swift
import CLIProxyManagerCore

struct AutomaticShellInstallService: Sendable {
    private let installer: any ShellFunctionInstalling
    private let helperCommand: String

    init(installer: any ShellFunctionInstalling, helperCommand: String = "/usr/local/bin/cliproxy-manager") {
        self.installer = installer
        self.helperCommand = helperCommand
    }

    func apply(config: AppConfig) throws {
        let script = try ShellFunctionRenderer(config: config, helperCommand: helperCommand).render()
        try installer.install(
            functionScript: script,
            functionNames: [config.commands.cc, config.commands.ccapi, config.commands.ccodex]
        )
    }
}
```

- [ ] **Step 4: Wire ViewModel**

On initialization or explicit `performFirstLaunchSetup()`, apply default config once.

After every provider/general setting save, call `automaticShellInstallService.apply(config:)`.

- [ ] **Step 5: Verify**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AutomaticShellInstallServiceTests
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProviderSettingsViewModelTests
```

Expected: PASS.

---

### Task 4: Replace temporary Dashboard with settings-style provider window

**Files:**

- Create: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
- Create: `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
- Create: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
- Create: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift` or stop using it from app entry.
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`

- [ ] **Step 1: Build SettingsView**

Use `TabView`:

```swift
TabView {
    ProviderListView(viewModel: viewModel)
        .tabItem { Label("Providers", systemImage: "rectangle.stack") }
    GeneralSettingsView(viewModel: viewModel)
        .tabItem { Label("General", systemImage: "gearshape") }
    LicensesView()
        .tabItem { Label("Licenses", systemImage: "doc.text") }
}
```

Visible window title should be `Settings`.

- [ ] **Step 2: Implement ProviderListView**

Rows show:

- provider name
- connection title/detail
- function name
- Connect / Disconnect / Settings buttons

`+` button calls `viewModel.addProvider()`.

- [ ] **Step 3: Implement provider sheets**

Reuse existing Codex model/reasoning/context UI from `SettingsSheets.swift`, but split into provider-specific sheets.

- [ ] **Step 4: Implement GeneralSettingsView**

Fields:

- Port
- Server ON/OFF toggle
- Start at login
- Show Dock icon
- Show menu bar icon
- Shell install status
- Reinstall shell functions button

- [ ] **Step 5: Replace app entry view**

Use `SettingsView()` as main window content. Remove visible `Dashboard` naming.

- [ ] **Step 6: Build**

```bash
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
```

Expected: PASS.

---

### Task 5: Add menu bar item and Settings command behavior

**Files:**

- Create: `Sources/CLIProxyManagerApp/MenuBar/CLIProxyMenuBar.swift`
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`

- [ ] **Step 1: Add menu bar scene**

Use SwiftUI `MenuBarExtra`:

```swift
MenuBarExtra("CLIProxyManager", systemImage: "terminal") {
    CLIProxyMenuBar(viewModel: viewModel)
}
```

Share the same ViewModel instance between Settings window and menu bar.

- [ ] **Step 2: Implement menu content**

Show:

- Server status
- connected providers and function names
- Start Server / Stop Server
- Open Settings
- Quit...

- [ ] **Step 3: Add Settings command**

Add commands so `Command + ,` opens the Settings window.

- [ ] **Step 4: Build**

```bash
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
```

Expected: PASS.

---

### Task 6: Add start-at-login and Dock/menu bar visibility services

**Files:**

- Create: `Sources/CLIProxyManagerApp/Services/LoginItemService.swift`
- Create: `Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Create: `Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift`

- [ ] **Step 1: Add tests**

Tests:

- Cannot save config with both `showDockIcon == false` and `showMenuBarIcon == false`.
- Toggling start-at-login calls login service.
- Toggling Dock/menu visibility saves config.

- [ ] **Step 2: Implement LoginItemService**

Wrap `SMAppService.mainApp.register()` and `.unregister()`.

- [ ] **Step 3: Implement AppAppearanceService**

Use `NSApplication.shared.setActivationPolicy(.regular)` when Dock is shown and `.accessory` when hidden.

- [ ] **Step 4: Wire ViewModel general settings methods**

Add:

```swift
func saveGeneralSettings(port:startAtLogin:showDockIcon:showMenuBarIcon:) throws
```

Validate at least one of Dock/menu bar is visible.

- [ ] **Step 5: Verify**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter AppAppearanceServiceTests
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
```

Expected: PASS.

---

### Task 7: Add close/quit behavior and quit confirmation

**Files:**

- Create: `Sources/CLIProxyManagerApp/AppDelegate.swift`
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`

- [ ] **Step 1: Implement app delegate**

Responsibilities:

- `Command + W` closes window only.
- `Command + Q` triggers quit confirmation.
- Confirmed quit stops app-managed server then terminates app.

- [ ] **Step 2: Add quit confirmation dialog**

Dialog text:

```text
CLIProxyManager를 종료할까요?
앱이 시작한 CLIProxyAPI 서버도 함께 종료됩니다.
```

Buttons:

- Cancel
- Stop Server and Quit

- [ ] **Step 3: Ensure menu bar Quit uses same flow**

Menu bar Quit should call the same app delegate or shared coordinator.

- [ ] **Step 4: Manual verify**

Run app and check:

- `Command + W` closes settings window.
- Menu bar item remains.
- `Command + ,` reopens Settings.
- `Command + Q` shows confirmation.

---

### Task 8: Final verification

- [ ] **Step 1: Run full tests**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager"
```

Expected: PASS.

- [ ] **Step 2: Build app**

```bash
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
```

Expected: PASS.

- [ ] **Step 3: Launch app**

```bash
"/Users/woosublee/Documents/dev/CLIProxyManager/.build/debug/CLIProxyManager"
```

Manual checks:

- Dock icon appears by default.
- Menu bar item appears by default.
- Settings window title is Settings.
- Providers/General/Licenses tabs exist.
- Providers list contains Claude, Claude API, Codex.
- `+` shows future-support message.
- Provider rows show function names.
- General has server ON/OFF, port, start at login, Dock/menu bar toggles.
- Menu bar shows provider/function summary.
- Menu bar start/stop controls app-managed server.
- `Command + W` closes only the window.
- `Command + ,` reopens settings.
- `Command + Q` shows quit confirmation.

- [ ] **Step 4: Git status**

```bash
git status --short --branch
```

Expected: Only intended changes remain.
