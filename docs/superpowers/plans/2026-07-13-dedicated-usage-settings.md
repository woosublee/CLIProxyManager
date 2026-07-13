# Dedicated Usage Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated `Usage` settings tab where menu-bar usage and the Usage HUD can be enabled independently while sharing an automatically managed subscription-usage backend.

**Architecture:** Replace the persisted `SubscriptionUsage.isEnabled` flag with `showInMenuBar`, and make `AppConfig.isSubscriptionUsageEnabled` the single computed source of truth (`showInMenuBar || usageOverlay.isVisible`). Route both display-setting mutations through one ViewModel lifecycle helper so the management key, refresh state, cache, and proxy restart change only when the computed backend state crosses enabled/disabled. Keep HUD window-session hiding separate from its persisted visibility preference.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, Combine, Swift Package Manager, XCTest, existing `AppConfigStore`, `SubscriptionUsageManagementKeyFileStore`, `UsageOverlayWindowController`, and Makefile app bundling.

## Global Constraints

- Work only in the existing isolated worktree on branch `worktree-issue-63-usage-settings`.
- Read and apply the `apple-design` skill before editing the settings UI; preserve the existing restrained macOS material, typography, row density, and control alignment rather than redesigning the whole window.
- Keep the settings window exactly `720×500` (`AppWindowMetrics.settingsWidth/settingsHeight`).
- Use tab order `General`, `Usage`, `Server`, `Advanced`, `About` and SF Symbol `chart.bar.xaxis` for Usage.
- Keep current 12pt horizontal padding on each settings tab.
- Keep all user-facing copy in the app’s existing concise English style.
- Preserve existing stored values, opacity live preview, and session-only HUD close/hide behavior.
- Do not add a user-visible or persisted backend master switch.
- Do not change usage refresh intervals, provider support, account ordering, or HUD content design.
- Follow TDD for every behavior change: failing focused test, minimal implementation, passing focused test.
- Run the complete `swift test` suite and a development app build; app launch and manual visual inspection remain the user’s responsibility.

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/CLIProxyManagerCore/Config/AppConfig.swift` | Persist `showInMenuBar`, migrate legacy `isEnabled`, and expose `isSubscriptionUsageEnabled`. |
| `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift` | Use the computed backend state; `quota key set` enables the menu-bar display preference for backward compatibility. |
| `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift` | Generate proxy management configuration from the computed backend state. |
| `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` | Apply independent display preferences through one atomic backend lifecycle transition. |
| `Sources/CLIProxyManagerApp/Models/SettingsTab.swift` | Add Usage navigation metadata. |
| `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift` | Carry whether menu-bar usage presentation is enabled into account rows. |
| `Sources/CLIProxyManagerApp/Views/SettingsView.swift` | Route the Usage tab to `UsageSettingsView`. |
| `Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift` | Own Menu Bar and Usage HUD controls and explanatory copy. |
| `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift` | Remove the relocated General and Server usage groups and their bindings. |
| `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift` | Hide only menu-bar usage details when `showInMenuBar` is false. |
| `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` | Verify migration, precedence, encoding, and four-way computed state. |
| `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift` | Verify default and store round-trip with the new preference. |
| `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift` | Verify quota CLI behavior uses the computed state and remains backward compatible. |
| `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` | Verify lifecycle transitions, rollback, cache/key retention, and reset. |
| `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift` | Verify the five tabs and Usage copy/metadata. |
| `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift` | Verify menu-bar presentation can be hidden independently from fetched HUD data. |
| `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift` | Preserve session-only hide semantics. |

---

### Task 1: Migrate the Subscription Usage Config Model

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:294-330,354-474`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

**Interfaces:**
- Consumes: existing `AppConfig.UsageOverlay.isVisible: Bool`.
- Produces: `AppConfig.SubscriptionUsage.showInMenuBar: Bool`, `AppConfig.isSubscriptionUsageEnabled: Bool`, and legacy JSON migration from `subscriptionUsage.isEnabled`.

- [ ] **Step 1: Write failing migration and computed-state tests**

Add focused tests to `AppConfigTests`:

```swift
func testLegacySubscriptionUsageEnabledMigratesToMenuBarVisibility() throws {
    let enabled = try decodeConfig(subscriptionUsageJSON: #"{"isEnabled":true}"#, usageOverlayJSON: #"{"isVisible":false}"#)
    let disabled = try decodeConfig(subscriptionUsageJSON: #"{"isEnabled":false}"#, usageOverlayJSON: #"{"isVisible":false}"#)

    XCTAssertTrue(enabled.subscriptionUsage.showInMenuBar)
    XCTAssertFalse(disabled.subscriptionUsage.showInMenuBar)
}

func testNewMenuBarVisibilityTakesPrecedenceOverLegacyEnabledField() throws {
    let config = try decodeConfig(
        subscriptionUsageJSON: #"{"showInMenuBar":false,"isEnabled":true}"#,
        usageOverlayJSON: #"{"isVisible":false}"#
    )

    XCTAssertFalse(config.subscriptionUsage.showInMenuBar)
    XCTAssertFalse(config.isSubscriptionUsageEnabled)
}

func testSubscriptionUsageEnabledIsComputedFromEitherDisplayPreference() {
    var config = AppConfig.default
    XCTAssertFalse(config.isSubscriptionUsageEnabled)

    config.subscriptionUsage.showInMenuBar = true
    XCTAssertTrue(config.isSubscriptionUsageEnabled)

    config.subscriptionUsage.showInMenuBar = false
    config.usageOverlay.isVisible = true
    XCTAssertTrue(config.isSubscriptionUsageEnabled)

    config.subscriptionUsage.showInMenuBar = true
    config.usageOverlay.isVisible = true
    XCTAssertTrue(config.isSubscriptionUsageEnabled)
}

func testSubscriptionUsageEncodesOnlyNewMenuBarVisibilityField() throws {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true

    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    let usage = try XCTUnwrap(object["subscriptionUsage"] as? [String: Any])

    XCTAssertEqual(usage["showInMenuBar"] as? Bool, true)
    XCTAssertNil(usage["isEnabled"])
}
```

Add a private test helper that builds a complete valid config JSON while injecting the two nested JSON fragments:

```swift
private func decodeConfig(subscriptionUsageJSON: String, usageOverlayJSON: String) throws -> AppConfig {
    let json = """
    {
      "port": 18317,
      "commands": {"cc":"","ccapi":"","ccodex":""},
      "ccapi": {"model":"claude-opus-4-8"},
      "ccodex": {
        "opus": {"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"},
        "sonnet": {"model":"gpt-5.5","reasoning":"medium","contextWindow":"auto"},
        "haiku": {"model":"gpt-5.5","reasoning":"low","contextWindow":"auto"}
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true,
      "subscriptionUsage": \(subscriptionUsageJSON),
      "usageOverlay": \(usageOverlayJSON)
    }
    """
    return try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
}
```

Update `AppConfigStoreTests` assertions to use `subscriptionUsage.showInMenuBar` and `isSubscriptionUsageEnabled`, and set `showInMenuBar = true` in the save/load round-trip.

- [ ] **Step 2: Run the focused config tests and confirm failure**

Run:

```bash
swift test --filter 'AppConfigTests|AppConfigStoreTests'
```

Expected: compilation fails because `showInMenuBar` and `isSubscriptionUsageEnabled` do not exist.

- [ ] **Step 3: Implement the new persisted field and legacy decoder**

Replace `SubscriptionUsage` with:

```swift
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public var showInMenuBar: Bool

    public init(showInMenuBar: Bool = false) {
        self.showInMenuBar = showInMenuBar
    }

    private enum CodingKeys: String, CodingKey {
        case showInMenuBar
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) {
            self.showInMenuBar = showInMenuBar
        } else {
            self.showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showInMenuBar, forKey: .showInMenuBar)
    }
}
```

Add to `AppConfig`:

```swift
public var isSubscriptionUsageEnabled: Bool {
    subscriptionUsage.showInMenuBar || usageOverlay.isVisible
}
```

Replace default and round-trip test assumptions about `subscriptionUsage.isEnabled` with the new property names.

- [ ] **Step 4: Run focused config tests**

Run:

```bash
swift test --filter 'AppConfigTests|AppConfigStoreTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the config migration**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "refactor: derive subscription usage from display settings

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Route Core and CLI Consumers Through the Computed State

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:390-463`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:252-303`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift:145-177,193-450`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

**Interfaces:**
- Consumes: `AppConfig.isSubscriptionUsageEnabled` and `AppConfig.SubscriptionUsage.showInMenuBar` from Task 1.
- Produces: quota and generated proxy management configuration that work when either menu-bar display or HUD display requires usage data.

- [ ] **Step 1: Write failing CLI tests for HUD-only backend enablement**

Add to `CLIProxyManagerCommandTests`:

```swift
func testQuotaFetchesWhenOnlyUsageHUDIsEnabled() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox)
    let configStore = AppConfigStore(paths: paths)
    var config = AppConfig.default
    config.usageOverlay.isVisible = true
    try configStore.save(config)

    let authDirectory = paths.authDirectory
    try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
    try Data(#"{"type":"codex","disabled":false}"#.utf8)
        .write(to: authDirectory.appendingPathComponent("codex.json"))
    let quotaClient = FixedSubscriptionQuotaClient(states: [
        "codex.json": .available(.init(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 0)
        ))
    ])
    let output = OutputDouble(isInteractive: false)
    let command = CLIProxyManagerCommand(
        secretStore: InMemorySecretStore(),
        configStore: configStore,
        authProfileStore: AuthProfileStore(authDirectory: authDirectory),
        output: output,
        subscriptionQuotaClient: quotaClient
    )

    try await command.run(arguments: ["quota", "--json"])

    XCTAssertTrue(output.stdout.joined().contains("available"))
}
```

Update existing test setup from `config.subscriptionUsage.isEnabled = true` to `config.subscriptionUsage.showInMenuBar = true`. Change the quota-key compatibility assertion to:

```swift
XCTAssertTrue(try configStore.load().subscriptionUsage.showInMenuBar)
XCTAssertTrue(try configStore.load().isSubscriptionUsageEnabled)
```

Add or adapt a `ProxyServiceManagerTests` case that uses the real default config provider with `showInMenuBar == false` and `usageOverlay.isVisible == true`, then verifies the generated config includes `remote-management` when a key is present.

- [ ] **Step 2: Run core consumer tests and confirm failure**

Run:

```bash
swift test --filter 'CLIProxyManagerCommandTests|ProxyServiceManagerTests'
```

Expected: compilation or assertions fail because core consumers still read/write legacy `isEnabled`.

- [ ] **Step 3: Replace core reads and preserve CLI key-set compatibility**

In `runQuota`, use:

```swift
if config.isSubscriptionUsageEnabled {
    report = await subscriptionQuotaClient.fetchUsage(port: config.port, profiles: profiles)
} else {
    report = SubscriptionUsageReport(
        statesByProfileID: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, .disabled) }),
        fetchedAt: Date()
    )
}
```

Rename `enableSubscriptionUsage()` to `enableSubscriptionUsageMenuBarDisplay()` and implement:

```swift
private func enableSubscriptionUsageMenuBarDisplay() throws {
    var config = try configStore.load()
    guard !config.subscriptionUsage.showInMenuBar else { return }
    config.subscriptionUsage.showInMenuBar = true
    try configStore.save(config)
}
```

Call it from `quota key set --stdin`. This retains the existing headless CLI behavior: explicitly setting a quota key opts into a persistent usage consumer through the menu-bar preference.

In both `ProxyServiceManager` default providers, replace:

```swift
(try? AppConfigStore(paths: paths).load().subscriptionUsage.isEnabled) ?? false
```

with:

```swift
(try? AppConfigStore(paths: paths).load().isSubscriptionUsageEnabled) ?? false
```

- [ ] **Step 4: Run focused core consumer tests**

Run:

```bash
swift test --filter 'CLIProxyManagerCommandTests|ProxyServiceManagerTests'
```

Expected: all selected tests pass.

- [ ] **Step 5: Confirm no production legacy config reads remain**

Run:

```bash
rg -n 'subscriptionUsage\.isEnabled' Sources/CLIProxyManagerCore
```

Expected: no output.

- [ ] **Step 6: Commit core consumer migration**

```bash
git add Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "refactor: share usage activation across core consumers

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Make Display Preference Transitions Atomic in the ViewModel

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:145-148,275-283,323-425,428-555,638-643,2217`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:2118-2453,2455-3320,3362-3388,3571-3626`

**Interfaces:**
- Consumes: `AppConfig.isSubscriptionUsageEnabled`, `subscriptionUsage.showInMenuBar`, and existing `savePrivacyOnlyConfig(_:)` rollback behavior.
- Produces: `saveSubscriptionUsageMenuBarVisible(_:) throws`, lifecycle-aware `saveUsageOverlay(_:) throws`, and a shared transition helper that only changes backend resources on false/true boundary crossings.

- [ ] **Step 1: Replace legacy test setup and write failing independent-transition tests**

Mechanically replace test setup and assertions:

```swift
config.subscriptionUsage.isEnabled = true
```

with:

```swift
config.subscriptionUsage.showInMenuBar = true
```

and replace reads with either `subscriptionUsage.showInMenuBar` for display intent or `isSubscriptionUsageEnabled` for backend state.

Rename existing enable/disable tests to mention menu-bar visibility. Add these tests using `subscriptionUsageViewModel(...)`:

```swift
func testEnablingHUDAsFirstConsumerCreatesKeyAndRestartsReadyProxy() async throws {
    let config = AppConfig.default
    let store = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble()
    let proxy = StubProxyServiceStarter()
    let viewModel = subscriptionUsageViewModel(config: config, configStore: store, keyStore: keyStore, proxyService: proxy)
    await viewModel.refresh()

    try viewModel.saveUsageOverlay(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))
    await waitForRestart(proxy)

    XCTAssertTrue(viewModel.config.usageOverlay.isVisible)
    XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
    XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertEqual(keyStore.createCallCount, 1)
    XCTAssertEqual(proxy.restartPorts, [config.port])
}

func testTurningOffMenuBarKeepsBackendWhenHUDIsVisible() throws {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    config.usageOverlay.isVisible = true
    let store = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let proxy = StubProxyServiceStarter()
    let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: ["saved": .init(
        profileID: "saved", provider: .codex, windows: [], fetchedAt: .distantPast
    )])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: store,
        keyStore: keyStore,
        proxyService: proxy,
        subscriptionUsageSnapshotCache: cache
    )

    try viewModel.saveSubscriptionUsageMenuBarVisible(false)

    XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
    XCTAssertTrue(viewModel.config.usageOverlay.isVisible)
    XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertEqual(keyStore.deleteCallCount, 0)
    XCTAssertTrue(keyStore.isConfigured())
    XCTAssertTrue(proxy.restartPorts.isEmpty)
    XCTAssertFalse(cache.isEmpty)
}

func testTurningOffHUDKeepsBackendWhenMenuBarIsVisible() throws {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    config.usageOverlay.isVisible = true
    let store = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let proxy = StubProxyServiceStarter()
    let viewModel = subscriptionUsageViewModel(config: config, configStore: store, keyStore: keyStore, proxyService: proxy)

    try viewModel.saveUsageOverlay(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))

    XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
    XCTAssertFalse(viewModel.config.usageOverlay.isVisible)
    XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertEqual(keyStore.deleteCallCount, 0)
    XCTAssertTrue(proxy.restartPorts.isEmpty)
}

func testTurningOffLastConsumerDeletesKeyClearsCacheAndRestarts() async throws {
    var config = AppConfig.default
    config.usageOverlay.isVisible = true
    let store = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let proxy = StubProxyServiceStarter()
    let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: ["saved": .init(
        profileID: "saved", provider: .codex, windows: [], fetchedAt: .distantPast
    )])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: store,
        keyStore: keyStore,
        proxyService: proxy,
        subscriptionUsageSnapshotCache: cache
    )
    await viewModel.refresh()

    try viewModel.saveUsageOverlay(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))
    await waitForRestart(proxy)

    XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertEqual(keyStore.deleteCallCount, 1)
    XCTAssertTrue(cache.isEmpty)
    XCTAssertEqual(proxy.restartPorts, [config.port])
}
```

Extend `SubscriptionUsageSnapshotCacheDouble` with:

```swift
var isEmpty: Bool { snapshots.isEmpty }
```

Retain and adapt existing failure tests to exercise both `saveSubscriptionUsageMenuBarVisible(false)` and `saveUsageOverlay(isVisible: false, ...)`.

- [ ] **Step 2: Run the ViewModel subscription tests and confirm failure**

Run:

```bash
swift test --filter 'DashboardViewModelTests.*(SubscriptionUsage|UsageHUD|MenuBar|LastConsumer)'
```

Expected: compilation fails because the new menu-bar API and computed lifecycle behavior are not implemented.

- [ ] **Step 3: Add a single lifecycle transition helper**

Add:

```swift
func saveSubscriptionUsageMenuBarVisible(_ isVisible: Bool) throws {
    var updatedConfig = config
    updatedConfig.subscriptionUsage.showInMenuBar = isVisible
    try saveUsageDisplayConfig(updatedConfig)
}

func saveUsageOverlay(_ usageOverlay: AppConfig.UsageOverlay) throws {
    var updatedConfig = config
    updatedConfig.usageOverlay = usageOverlay
    try saveUsageDisplayConfig(updatedConfig)
}

private func saveUsageDisplayConfig(_ updatedConfig: AppConfig) throws {
    let wasEnabled = config.isSubscriptionUsageEnabled
    let willBeEnabled = updatedConfig.isSubscriptionUsageEnabled

    if !wasEnabled && willBeEnabled {
        let createdKey = try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
        do {
            try savePrivacyOnlyConfig(updatedConfig)
        } catch {
            if createdKey { try? subscriptionUsageKeyStore.deleteManagementKey() }
            throw error
        }
    } else {
        try savePrivacyOnlyConfig(updatedConfig)
        if wasEnabled && !willBeEnabled {
            cancelSubscriptionUsageWork()
            try subscriptionUsageKeyStore.deleteManagementKey()
            setSubscriptionUsageStates(.disabled)
            clearSubscriptionUsageSnapshots()
        }
    }

    guard wasEnabled != willBeEnabled else { return }
    Task { [weak self] in
        guard let self else { return }
        if self.serverControlState.isRunning {
            await self.restartServer()
        } else {
            await self.refreshSubscriptionUsage()
        }
    }
}
```

Delete `saveSubscriptionUsageEnabled(_:)`. Replace all backend guards with `config.isSubscriptionUsageEnabled`, including:

```swift
var canRefreshSubscriptionUsage: Bool
prepareSubscriptionUsage()
restoreSubscriptionUsageSnapshots()
refreshSubscriptionUsage(force:)
scheduleSubscriptionUsagePollingIfNeeded()
subscriptionUsageState fallback near line 2217
resetAllSettings()
```

For reset, calculate deletion from the old computed state:

```swift
let shouldDeleteManagementKey = config.isSubscriptionUsageEnabled || subscriptionUsageKeyStore.isConfigured()
```

- [ ] **Step 4: Preserve atomic failure semantics in both display APIs**

Ensure these exact outcomes remain covered by adapted tests:

```swift
// First consumer config-save failure:
// - created key is deleted
// - original display preferences remain

// Last consumer config-save failure:
// - key remains configured
// - original display preference remains enabled

// Last consumer key-delete failure after successful config save:
// - display preference remains disabled
// - key remains configured
// - the thrown error reaches saveSetting/toast

// true -> true display-only transition:
// - no key create/delete
// - no cache clear
// - no proxy restart
```

Do not attempt to roll back a successfully saved disabled config after key deletion fails; this matches the existing project policy.

- [ ] **Step 5: Run focused ViewModel tests**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: all `DashboardViewModelTests` pass.

- [ ] **Step 6: Confirm production app code no longer references legacy state/API**

Run:

```bash
rg -n 'subscriptionUsage\.isEnabled|saveSubscriptionUsageEnabled' Sources/CLIProxyManagerApp
```

Expected: no output.

- [ ] **Step 7: Commit the ViewModel lifecycle change**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: manage usage backend from display preferences

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Add the Dedicated Usage Settings Tab with Apple-Style Polish

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/SettingsTab.swift:1-34`
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift:7-68`
- Create: `Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:4-24,64-89,156-224`
- Test: `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift:16-19`

**Interfaces:**
- Consumes: `saveSubscriptionUsageMenuBarVisible(_:)`, `saveUsageOverlay(_:)`, and `previewUsageOverlayBackgroundOpacity(_:)` from Task 3.
- Produces: `.usage` tab and `UsageSettingsView(viewModel:)` with Menu Bar and Usage HUD groups.

- [ ] **Step 1: Invoke and apply the Apple design skill before editing UI**

Invoke:

```text
/apple-design
```

Read its current guidance and record the implementation constraints in the working notes before coding:

```text
- Preserve existing SettingsGroup/SettingsRow hierarchy.
- Keep controls right-aligned and labels/descriptions left-aligned.
- Keep explanatory copy secondary and concise.
- Keep disabled HUD detail controls visible so stored values remain spatially stable.
- Do not add decorative cards, gradients, large headers, or motion.
- Confirm five tab buttons fit within 720pt using existing 12pt horizontal button padding.
```

Expected: the UI implementation remains a focused extension of the existing macOS settings design rather than a redesign.

- [ ] **Step 2: Write failing navigation and copy tests**

Update `SettingsNavigationTests`:

```swift
func testSettingsTabsIncludeDedicatedUsageTab() {
    XCTAssertEqual(
        SettingsTab.allCases.map(\.title),
        ["General", "Usage", "Server", "Advanced", "About"]
    )
    XCTAssertEqual(
        SettingsTab.allCases.map(\.systemImage),
        ["slider.horizontal.3", "chart.bar.xaxis", "server.rack", "wrench.and.screwdriver", "info.circle"]
    )
}

func testUsageSettingsCopyExplainsAutomaticSharedBackend() {
    XCTAssertEqual(UsageSettingsCopy.menuBarLabel, "Show subscription usage")
    XCTAssertEqual(UsageSettingsCopy.hudLabel, "Show usage HUD")
    XCTAssertEqual(
        UsageSettingsCopy.footer,
        "Usage data is fetched whenever the menu bar display or Usage HUD is enabled. CLIProxyManager manages the local management key automatically."
    )
}
```

The independent persistence methods are already covered by Task 3's lifecycle tests; do not duplicate those assertions in a UI test or add a UI inspection dependency.

- [ ] **Step 3: Run settings tests and confirm failure**

Run:

```bash
swift test --filter SettingsNavigationTests
```

Expected: compilation fails because `.usage`, `UsageSettingsCopy`, and the new API wiring do not exist.

- [ ] **Step 4: Add the Usage tab and route it**

Update `SettingsTab`:

```swift
enum SettingsTab: CaseIterable, Hashable, Identifiable {
    case general
    case usage
    case server
    case advanced
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .usage: "Usage"
        case .server: "Server"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .usage: "chart.bar.xaxis"
        case .server: "server.rack"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}
```

In `SettingsView` add:

```swift
case .usage:
    UsageSettingsView(viewModel: viewModel)
```

Keep `.padding(.horizontal, 12)` on tab labels and do not change `AppWindowMetrics`.

- [ ] **Step 5: Create `UsageSettingsView.swift`**

Create:

```swift
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
```

- [ ] **Step 6: Remove relocated controls from General and Server**

Delete from `GeneralSettingsView`:

```swift
private func usageOverlayBinding...
private var usageOverlayOpacityBinding...
SettingsGroup(title: "Usage Overlay") { ... }
```

Delete from `ServerSettingsView`:

```swift
SettingsGroup(title: "Subscription Usage (Experimental)") { ... }
```

Do not change Appearance, Behavior, Command Line, Server, or Routing settings.

- [ ] **Step 7: Run settings tests**

Run:

```bash
swift test --filter SettingsNavigationTests
```

Expected: all selected tests pass.

- [ ] **Step 8: Compile the app target to catch SwiftUI layout/type errors**

Run:

```bash
swift build -c debug --product CLIProxyManager
```

Expected: build completes successfully; no exhaustive-switch or SwiftUI generic errors.

- [ ] **Step 9: Commit the dedicated Usage tab**

```bash
git add Sources/CLIProxyManagerApp/Models/SettingsTab.swift \
  Sources/CLIProxyManagerApp/Views/SettingsView.swift \
  Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift
git commit -m "feat: add dedicated usage settings tab

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Hide Menu-Bar Usage Independently from HUD Data

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift:3-71`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift:23-29,146-159,175-239`
- Test: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift`
- Verify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`

**Interfaces:**
- Consumes: `viewModel.config.subscriptionUsage.showInMenuBar` and the unchanged fetched `AccountSubscriptionUsageState`.
- Produces: `MenuBarConnectedProvider.showsSubscriptionUsage: Bool`; menu-bar rows omit usage presentation when false while HUD rows continue using the original state.

- [ ] **Step 1: Write failing snapshot tests for independent menu-bar presentation**

Add to `MenuBarStatusSnapshotTests`:

```swift
func testSnapshotCanHideMenuBarUsageWithoutDiscardingFetchedState() throws {
    let available = AccountSubscriptionUsageState.available(.init(
        profileID: "codex.json",
        provider: .codex,
        windows: [.init(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 0)
    ))
    let snapshot = MenuBarStatusSnapshot(
        serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
        providers: [ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            nickname: "",
            functionName: "cdx",
            connectionTitle: "Connected",
            connectionDetail: "codex@example.com",
            isConnected: true,
            subscriptionUsageState: available
        )],
        showsSubscriptionUsage: false
    )

    let provider = try XCTUnwrap(snapshot.connectedProviders.first)
    XCTAssertFalse(provider.showsSubscriptionUsage)
    XCTAssertEqual(provider.subscriptionUsageState, available)
}

func testSnapshotShowsMenuBarUsageWhenPreferenceIsEnabled() throws {
    let snapshot = MenuBarStatusSnapshot(
        serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
        providers: [connectedCodexProviderWithAvailableUsage()],
        showsSubscriptionUsage: true
    )

    XCTAssertTrue(try XCTUnwrap(snapshot.connectedProviders.first).showsSubscriptionUsage)
}
```

Use or add a local helper to create the provider. The important assertion is that hiding presentation does not mutate the state consumed by `UsageOverlayView`.

- [ ] **Step 2: Run the snapshot tests and confirm failure**

Run:

```bash
swift test --filter MenuBarStatusSnapshotTests
```

Expected: compilation fails because `showsSubscriptionUsage` does not exist.

- [ ] **Step 3: Carry the display preference into menu-bar account rows**

Add to `MenuBarConnectedProvider`:

```swift
let showsSubscriptionUsage: Bool
```

Extend the snapshot initializer with a default to minimize unrelated call-site churn:

```swift
init(
    serverStatus: DiagnosticStatus,
    serverControlState: ServerControlState = .stopped,
    providers: [ProviderRowState],
    port: Int = 18_317,
    showsSubscriptionUsage: Bool = true
)
```

Set the property while mapping providers:

```swift
subscriptionUsageState: provider.subscriptionUsageState,
showsSubscriptionUsage: showsSubscriptionUsage
```

In `MenuBarStatusView.snapshot`, pass:

```swift
showsSubscriptionUsage: viewModel.config.subscriptionUsage.showInMenuBar
```

In `MenuBarAccountRow.subscriptionUsage`, add the outer guard:

```swift
@ViewBuilder
private var subscriptionUsage: some View {
    if !provider.showsSubscriptionUsage {
        EmptyView()
    } else if case .unavailable(.proxyUnavailable) = provider.subscriptionUsageState {
        EmptyView()
    } else {
        // existing display-state switch unchanged
    }
}
```

Do not change `UsageOverlayView`; it must continue rendering directly from `subscriptionUsageState` whenever the HUD exists.

- [ ] **Step 4: Run menu-bar and HUD controller tests**

Run:

```bash
swift test --filter 'MenuBarStatusSnapshotTests|UsageOverlayWindowControllerTests'
```

Expected: all selected tests pass, including the existing test that closing the HUD hides it only for the current session.

- [ ] **Step 5: Commit independent presentation**

```bash
git add Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift \
  Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift \
  Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift
git commit -m "feat: control menu bar usage presentation independently

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Complete Migration Sweep and Regression Coverage

**Files:**
- Modify: any remaining test files reported by the legacy-symbol search, principally `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` and `Tests/CLIProxyManagerCoreTests/*.swift`
- Verify: all files under `Sources/` and `Tests/`

**Interfaces:**
- Consumes: all interfaces from Tasks 1-5.
- Produces: a codebase with no legacy `subscriptionUsage.isEnabled` or `saveSubscriptionUsageEnabled` references and explicit regression coverage for reset/startup/HUD-only migration.

- [ ] **Step 1: Search for legacy API references**

Run:

```bash
rg -n 'subscriptionUsage\.isEnabled|saveSubscriptionUsageEnabled' Sources Tests
```

Expected: no output. If test setup still uses the old field, replace each assignment according to its intent:

```swift
// Tests backend enabled through menu bar:
config.subscriptionUsage.showInMenuBar = true

// Tests backend enabled through HUD:
config.usageOverlay.isVisible = true

// Tests backend state regardless of display location:
XCTAssertTrue(config.isSubscriptionUsageEnabled)
```

- [ ] **Step 2: Add startup migration and reset regression tests if not already covered**

Ensure `DashboardViewModelTests` includes these explicit cases:

```swift
func testPrepareSubscriptionUsageRepairsHUDOnlyEnabledConfigWithMissingKey() async throws {
    var config = AppConfig.default
    config.usageOverlay.isVisible = true
    let keyStore = SubscriptionUsageManagementKeyDouble()
    let proxy = StubProxyServiceStarter()
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: keyStore,
        proxyService: proxy
    )
    await viewModel.refresh()

    await viewModel.prepareSubscriptionUsage()
    await waitForRestart(proxy)

    XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertTrue(keyStore.isConfigured())
    XCTAssertEqual(keyStore.createCallCount, 1)
}

func testResetAllSettingsTurnsOffBothUsageDisplaysAndDeletesKey() async {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    config.usageOverlay = .init(isVisible: true, alwaysOnTop: true, backgroundOpacity: 0.45)
    let store = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let proxy = StubProxyServiceStarter()
    let viewModel = subscriptionUsageViewModel(config: config, configStore: store, keyStore: keyStore, proxyService: proxy)
    await viewModel.refresh()

    viewModel.resetAllSettings()
    await waitForRestart(proxy)

    XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
    XCTAssertFalse(viewModel.config.usageOverlay.isVisible)
    XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
    XCTAssertFalse(keyStore.isConfigured())
}
```

- [ ] **Step 3: Run all focused suites for the feature**

Run:

```bash
swift test --filter 'AppConfigTests|AppConfigStoreTests|CLIProxyManagerCommandTests|ProxyServiceManagerTests|DashboardViewModelTests|SettingsNavigationTests|MenuBarStatusSnapshotTests|UsageOverlayWindowControllerTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 4: Review the final feature diff for scope and copy**

Run:

```bash
git diff HEAD~5 -- Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Models/SettingsTab.swift \
  Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift \
  Sources/CLIProxyManagerApp/Views/SettingsView.swift \
  Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift
```

Expected review checklist:

```text
- No unrelated settings redesign.
- No new persisted master switch.
- No refresh interval/provider/order changes.
- No HUD close behavior changes.
- No "Experimental" usage heading remains in settings.
- Menu-bar and HUD labels clearly name their destination.
```

- [ ] **Step 5: Commit any migration-only cleanup**

If Step 1 or Step 2 changed files:

```bash
git add Sources Tests
git commit -m "test: cover independent usage display migration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If there were no changes, do not create an empty commit.

---

### Task 7: Run Full Verification and Build the Development App

**Files:**
- Verify: entire repository
- Output: `build-development/CLIProxyManager.app`

**Interfaces:**
- Consumes: completed implementation from Tasks 1-6.
- Produces: test and development-build evidence; no source API.

- [ ] **Step 1: Run formatting and repository-state checks**

Run:

```bash
git diff --check
git status --short
```

Expected: `git diff --check` exits 0. `git status --short` shows only intentional uncommitted changes, or no output if every task commit is complete.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures. The baseline before implementation was 714 tests; the final total must be greater because this plan adds coverage.

- [ ] **Step 3: Build the development app bundle and bundled helpers**

Run:

```bash
make bundle CONFIGURATION=debug BUILD_DIR=build-development
```

Expected:

```text
- command exits 0
- build-development/CLIProxyManager.app exists
- Contents/MacOS/CLIProxyManager is executable
- Contents/Helpers/cpm is executable
- Contents/Helpers/cliproxy-manager is executable
- Contents/Frameworks/Sparkle.framework exists
```

- [ ] **Step 4: Verify the development bundle structure without launching it**

Run:

```bash
test -x build-development/CLIProxyManager.app/Contents/MacOS/CLIProxyManager
test -x build-development/CLIProxyManager.app/Contents/Helpers/cpm
test -x build-development/CLIProxyManager.app/Contents/Helpers/cliproxy-manager
test -d build-development/CLIProxyManager.app/Contents/Frameworks/Sparkle.framework
plutil -lint build-development/CLIProxyManager.app/Contents/Info.plist
```

Expected: every command exits 0 and `plutil` reports `OK`.

- [ ] **Step 5: Report the user-owned manual UI checklist**

Do not launch the app automatically. Report the development bundle path and ask the user to inspect:

```text
1. Open build-development/CLIProxyManager.app.
2. Confirm tab order General / Usage / Server / Advanced / About.
3. Confirm all five tabs fit at the fixed 720×500 size without clipping.
4. Confirm General no longer has Usage Overlay.
5. Confirm Server no longer has Subscription Usage (Experimental).
6. Toggle menu-bar usage without changing HUD visibility.
7. Toggle HUD visibility without changing menu-bar usage.
8. Close the HUD with × and confirm its setting remains on; use the menu-bar action to show it again.
9. Drag Background opacity and confirm live preview plus persisted value after release.
10. Confirm disabled Always on top and Background opacity rows remain visible and aligned when HUD is off.
```

- [ ] **Step 6: Capture final status**

Run:

```bash
git status --short --branch
git log --oneline -8
```

Expected: feature commits are present on `worktree-issue-63-usage-settings`; report any uncommitted files truthfully.

## Plan Self-Review

- **Spec coverage:** Tasks 1-2 cover migration and the common core/CLI/proxy activation source. Task 3 covers independent preference transitions, key/cache/polling atomicity, startup repair, reset, and failure policy. Task 4 covers the dedicated Apple-informed Usage tab, fixed window size, copy, relocation, and opacity behavior. Task 5 covers independent menu-bar presentation while preserving HUD data and session hiding. Tasks 6-7 cover migration sweep, focused/full tests, development bundle, and the user-owned manual UI check.
- **Placeholder scan:** No TBD/TODO/“similar to” steps remain; each code-changing step includes exact signatures or code.
- **Type consistency:** The plan consistently defines and consumes `SubscriptionUsage.showInMenuBar`, `AppConfig.isSubscriptionUsageEnabled`, `saveSubscriptionUsageMenuBarVisible(_:)`, `saveUsageOverlay(_:)`, and `MenuBarConnectedProvider.showsSubscriptionUsage`.
