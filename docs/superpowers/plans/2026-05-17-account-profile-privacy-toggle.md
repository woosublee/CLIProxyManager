# Account Profile Privacy Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-account eye toggle that blurs each connected account email by default and persists each provider's visibility state across app launches.

**Architecture:** Store provider-specific privacy flags in `AppConfig`, pass the flags through `ProviderRowState` and `DashboardAccountSnapshot`, and render a SwiftUI eye button next to connected account details. The view calls `DashboardViewModel.toggleAccountDetailVisibility(_:)`, which updates only the selected provider's flag and persists the config.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Package Manager, XCTest, existing `CLIProxyManagerCore` and `CLIProxyManagerApp` targets.

---

## File Structure

- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - Add `AppConfig.AccountPrivacy` with default hidden values.
  - Persist `accountPrivacy` through `Codable`.
  - Preserve backward compatibility by defaulting missing `accountPrivacy` to hidden.
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
  - Add `accountDetailHidden` so provider rows carry the privacy state.
- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift`
  - Add `isAccountDetailHidden` and `showsAccountPrivacyToggle` for card rendering.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Set privacy state while rebuilding provider rows.
  - Add `toggleAccountDetailVisibility(_:)` to update and save provider-specific state.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - Pass the toggle callback to account cards.
  - Render the eye button and blur the email text when hidden.
- Modify tests:
  - `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift`
  - `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

---

### Task 1: Persist account privacy in AppConfig

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

- [ ] **Step 1: Write failing config tests**

Add these tests to `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` after `testDefaultConfigMatchesMVPDecisions()`:

```swift
func testDefaultAccountPrivacyHidesProviderDetails() {
    let config = AppConfig.default

    XCTAssertTrue(config.accountPrivacy.claudeHidden)
    XCTAssertTrue(config.accountPrivacy.codexHidden)
}

func testDecodedConfigDefaultsMissingAccountPrivacyToHidden() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
      "ccapi": { "model": "claude-opus-4-7" },
      "ccodex": {
        "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
        "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
        "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true
    }
    """#.utf8)

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertTrue(config.accountPrivacy.claudeHidden)
    XCTAssertTrue(config.accountPrivacy.codexHidden)
}

func testDecodedConfigPreservesAccountPrivacy() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
      "ccapi": { "model": "claude-opus-4-7" },
      "ccodex": {
        "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
        "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
        "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true,
      "accountPrivacy": { "claudeHidden": false, "codexHidden": true }
    }
    """#.utf8)

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertFalse(config.accountPrivacy.claudeHidden)
    XCTAssertTrue(config.accountPrivacy.codexHidden)
}
```

- [ ] **Step 2: Run config tests and verify failure**

Run:

```bash
swift test --filter AppConfigTests/testDefaultAccountPrivacyHidesProviderDetails
```

Expected: FAIL to compile with an error like `value of type 'AppConfig' has no member 'accountPrivacy'`.

- [ ] **Step 3: Implement AppConfig account privacy**

In `Sources/CLIProxyManagerCore/Config/AppConfig.swift`, add this nested struct after `Nicknames`:

```swift
public struct AccountPrivacy: Codable, Equatable, Sendable {
    public var claudeHidden: Bool
    public var codexHidden: Bool

    public init(claudeHidden: Bool = true, codexHidden: Bool = true) {
        self.claudeHidden = claudeHidden
        self.codexHidden = codexHidden
    }
}
```

Add this stored property after `public var nicknames: Nicknames`:

```swift
public var accountPrivacy: AccountPrivacy
```

Update the public initializer signature so the final parameters are:

```swift
appearance: AppearanceMode = .system,
nicknames: Nicknames = Nicknames(),
accountPrivacy: AccountPrivacy = AccountPrivacy(),
bindAddress: String = "127.0.0.1",
autostartServer: Bool = false,
roundRobinEnabled: Bool = false,
logLevel: LogLevel = .info
```

Inside the initializer, assign the property after `self.nicknames = nicknames`:

```swift
self.accountPrivacy = accountPrivacy
```

Update `CodingKeys` to include `accountPrivacy`:

```swift
private enum CodingKeys: String, CodingKey {
    case port, commands, ccapi, ccodex
    case includeDangerouslySkipPermissions
    case startAtLogin, showDockIcon, showMenuBarIcon
    case showNotifications
    case appearance
    case nicknames
    case accountPrivacy
    case bindAddress, autostartServer, roundRobinEnabled
    case logLevel
}
```

Update `init(from:)` after decoding `nicknames`:

```swift
self.accountPrivacy = try c.decodeIfPresent(AccountPrivacy.self, forKey: .accountPrivacy) ?? AccountPrivacy()
```

- [ ] **Step 4: Run config tests and verify pass**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: PASS for all `AppConfigTests`.

- [ ] **Step 5: Commit config persistence**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "$(cat <<'EOF'
Add account privacy config

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Pass privacy state through provider row snapshots

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift`
- Test: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift`

- [ ] **Step 1: Write failing snapshot tests**

Add these tests to `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift` before `testWhitespaceOnlyNicknameFallsBackToProviderName()`:

```swift
func testConnectedProviderShowsPrivacyToggleAndHiddenState() {
    let row = ProviderRowState(
        id: .claude,
        name: "Claude OAuth",
        nickname: "",
        functionName: "ccm",
        connectionTitle: "Connected",
        connectionDetail: "claude@example.com",
        isConnected: true,
        accountDetailHidden: true
    )

    let snapshot = DashboardAccountSnapshot(provider: row)

    XCTAssertTrue(snapshot.isAccountDetailHidden)
    XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
}

func testDisconnectedProviderDoesNotShowPrivacyToggle() {
    let row = ProviderRowState(
        id: .codex,
        name: "Codex OAuth",
        nickname: "",
        functionName: "ccmcodex",
        connectionTitle: "Needs connection",
        connectionDetail: "Connect the bundled CLIProxyAPI Codex OAuth profile.",
        isConnected: false,
        accountDetailHidden: true
    )

    let snapshot = DashboardAccountSnapshot(provider: row)

    XCTAssertTrue(snapshot.isAccountDetailHidden)
    XCTAssertFalse(snapshot.showsAccountPrivacyToggle)
}
```

- [ ] **Step 2: Run snapshot tests and verify failure**

Run:

```bash
swift test --filter DashboardAccountSnapshotTests/testConnectedProviderShowsPrivacyToggleAndHiddenState
```

Expected: FAIL to compile with errors for missing `accountDetailHidden`, `isAccountDetailHidden`, and `showsAccountPrivacyToggle`.

- [ ] **Step 3: Implement ProviderRowState privacy field**

In `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`, add this stored property after `let isErrored: Bool`:

```swift
let accountDetailHidden: Bool
```

Update the initializer signature to include a defaulted parameter at the end:

```swift
init(
    id: ID,
    name: String,
    nickname: String,
    functionName: String,
    connectionTitle: String,
    connectionDetail: String,
    isConnected: Bool,
    isErrored: Bool = false,
    accountDetailHidden: Bool = true
) {
```

Assign it inside the initializer after `self.isErrored = isErrored`:

```swift
self.accountDetailHidden = accountDetailHidden
```

- [ ] **Step 4: Implement DashboardAccountSnapshot privacy fields**

In `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift`, add these stored properties after `let showsMoreMenu: Bool`:

```swift
let isAccountDetailHidden: Bool
let showsAccountPrivacyToggle: Bool
```

Update `init(provider:)` after `showsMoreMenu = provider.isConnected`:

```swift
isAccountDetailHidden = provider.accountDetailHidden
showsAccountPrivacyToggle = provider.isConnected
```

- [ ] **Step 5: Run snapshot tests and verify pass**

Run:

```bash
swift test --filter DashboardAccountSnapshotTests
```

Expected: PASS for all `DashboardAccountSnapshotTests`.

- [ ] **Step 6: Commit snapshot plumbing**

```bash
git add Sources/CLIProxyManagerApp/Models/ProviderRowState.swift Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift
git commit -m "$(cat <<'EOF'
Pass account privacy state to snapshots

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add ViewModel provider-specific privacy toggling

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel tests**

Add these tests to `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` after `testProviderRowsShowOAuthProfileEmailsFromAppManagedAuthStore()`:

```swift
func testProviderRowsReflectConfiguredAccountPrivacy() {
    var config = AppConfig.default
    config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true)
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, true)
}

func testToggleClaudeAccountDetailVisibilityPersistsOnlyClaudePrivacy() {
    var config = AppConfig.default
    config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: false)
    let store = StubConfigStore(config: config)
    let viewModel = DashboardViewModel(
        configStore: store,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    viewModel.toggleAccountDetailVisibility(.claude)

    XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
    XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, false)
}

func testToggleCodexAccountDetailVisibilityPersistsOnlyCodexPrivacy() {
    var config = AppConfig.default
    config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true)
    let store = StubConfigStore(config: config)
    let viewModel = DashboardViewModel(
        configStore: store,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    viewModel.toggleAccountDetailVisibility(.codex)

    XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
    XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, false)
}

func testToggleAccountDetailVisibilityShowsSettingsMessageWhenSaveFails() {
    var config = AppConfig.default
    config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: true)
    let store = StubConfigStore(
        config: config,
        saveError: NSError(domain: "AccountPrivacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed"])
    )
    let viewModel = DashboardViewModel(
        configStore: store,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    viewModel.toggleAccountDetailVisibility(.claude)

    XCTAssertEqual(store.savedConfigs, [])
    XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: true))
    XCTAssertEqual(viewModel.settingsMessage, "Account privacy update failed: Save failed")
}
```

- [ ] **Step 2: Run ViewModel tests and verify failure**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests/testProviderRowsReflectConfiguredAccountPrivacy
```

Expected: FAIL because `ProviderRowState.accountDetailHidden` is not populated from config or `toggleAccountDetailVisibility(_:)` does not exist.

- [ ] **Step 3: Populate privacy state in provider rows**

In `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`, update the Claude row inside `rebuildProviderRows(claudeStatus:codexStatus:)` so the initializer ends with:

```swift
isConnected: claudeEnabled != nil,
isErrored: isExpired(claudeAny) || claudeStatus?.severity == .error,
accountDetailHidden: config.accountPrivacy.claudeHidden
```

Update the Codex row so the initializer ends with:

```swift
isConnected: codexEnabled != nil,
isErrored: isExpired(codexAny) || codexStatus?.severity == .error,
accountDetailHidden: config.accountPrivacy.codexHidden
```

- [ ] **Step 4: Add the toggle method**

In `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`, add this method after `func addProvider()`:

```swift
func toggleAccountDetailVisibility(_ provider: ProviderRowState.ID) {
    var updatedConfig = config
    switch provider {
    case .claude:
        updatedConfig.accountPrivacy.claudeHidden.toggle()
    case .codex:
        updatedConfig.accountPrivacy.codexHidden.toggle()
    }

    do {
        try saveConfig(updatedConfig)
    } catch {
        settingsMessage = "Account privacy update failed: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 5: Run ViewModel tests and verify pass**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests
```

Expected: PASS for all `DashboardViewModelRefreshTests`.

- [ ] **Step 6: Commit ViewModel behavior**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "$(cat <<'EOF'
Add account privacy toggle behavior

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Render the eye toggle and blur account details

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Test: existing app and snapshot/viewmodel tests from Tasks 2-3

- [ ] **Step 1: Pass the toggle callback from DashboardView**

In `Sources/CLIProxyManagerApp/Views/DashboardView.swift`, update the `ProviderAccountCardView` call inside the `ForEach` so it includes `toggleAccountDetailVisibility` between `settings` and `disconnect`:

```swift
ProviderAccountCardView(
    account: account,
    connect: {
        activeSheet = .addProvider
        viewModel.startOAuthLogin(account.id)
    },
    settings: { activeSheet = .providerSettings(account.id, isInitialSetup: false) },
    toggleAccountDetailVisibility: { viewModel.toggleAccountDetailVisibility(account.id) },
    disconnect: { viewModel.disconnectProvider(account.id) },
    remove: { viewModel.removeProvider(account.id) }
)
```

- [ ] **Step 2: Add the callback property to ProviderAccountCardView**

In the `ProviderAccountCardView` property list, add this after `let settings: () -> Void`:

```swift
let toggleAccountDetailVisibility: () -> Void
```

- [ ] **Step 3: Replace the inline account detail row with a helper view**

In `ProviderAccountCardView.body`, replace this block:

```swift
HStack(spacing: 6) {
    StatusLED(state: account.status == .connected ? .running : .stopped, size: 6, pulse: false)
    Text(account.status == .connected ? account.detail : "Disconnected")
        .font(.system(size: 11))
        .foregroundStyle(account.status == .connected ? .secondary : .tertiary)
        .lineLimit(1)
}
.padding(.top, 2)
```

with:

```swift
accountDetailRow
    .padding(.top, 2)
```

Add this helper property before `actions`:

```swift
private var accountDetailRow: some View {
    HStack(spacing: 6) {
        StatusLED(state: account.status == .connected ? .running : .stopped, size: 6, pulse: false)
        Text(account.status == .connected ? account.detail : "Disconnected")
            .font(.system(size: 11))
            .foregroundStyle(account.status == .connected ? .secondary : .tertiary)
            .lineLimit(1)
            .blur(radius: account.isAccountDetailHidden && account.showsAccountPrivacyToggle ? 4 : 0)
            .animation(.easeInOut(duration: 0.16), value: account.isAccountDetailHidden)

        if account.showsAccountPrivacyToggle {
            Button(action: toggleAccountDetailVisibility) {
                Image(systemName: account.isAccountDetailHidden ? "eye.slash" : "eye")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(account.isAccountDetailHidden ? "Account detail hidden" : "Account detail visible")
        }
    }
}
```

- [ ] **Step 4: Run app tests and verify compile/pass**

Run:

```bash
swift test --filter CLIProxyManagerAppTests
```

Expected: PASS for all `CLIProxyManagerAppTests`.

- [ ] **Step 5: Commit UI rendering**

```bash
git add Sources/CLIProxyManagerApp/Views/DashboardView.swift
git commit -m "$(cat <<'EOF'
Render account privacy eye toggle

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Full verification and manual UI check

**Files:**
- Verify all changed files from Tasks 1-4.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Launch the app for manual UI validation**

Run:

```bash
swift run CLIProxyManager
```

Expected: the macOS app launches. Open the account dashboard from the app/menu bar.

- [ ] **Step 3: Validate connected account behavior**

With at least one connected Claude or Codex auth profile visible:

```text
1. Confirm the connected account email is blurred by default if the provider has no saved privacy state.
2. Confirm the icon next to the blurred email is eye.slash.
3. Click the icon.
4. Confirm only that account's email becomes readable.
5. Confirm the icon changes to eye.
6. Click the icon again.
7. Confirm only that account's email becomes blurred again.
```

- [ ] **Step 4: Validate persistence**

```text
1. Leave one provider visible and one provider hidden if both Claude and Codex are connected.
2. Quit the app.
3. Relaunch with swift run CLIProxyManager.
4. Confirm each provider keeps its own previous visibility state.
```

- [ ] **Step 5: Validate disconnected account behavior**

```text
1. Disable or disconnect a provider from its account card menu.
2. Confirm the card shows Disconnected or Needs connection text.
3. Confirm no eye icon is shown for that disconnected account row.
```

- [ ] **Step 6: Commit final verification marker if manual changes were required**

If manual validation required code changes, commit those changes with this message:

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Sources/CLIProxyManagerApp/Models/ProviderRowState.swift Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "$(cat <<'EOF'
Polish account privacy toggle validation

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

If manual validation required no code changes, do not create an empty commit.

---

## Self-Review

- Spec coverage: Tasks 1-4 cover persisted provider-specific state, default hidden behavior, full-email blur, current-state eye icons, connected-only toggles, and provider-independent toggling. Task 5 covers app relaunch persistence and manual UI behavior.
- Placeholder scan: The plan has no incomplete markers, vague test instructions, or deferred implementation steps.
- Type consistency: The plan consistently uses `AppConfig.AccountPrivacy`, `accountPrivacy`, `claudeHidden`, `codexHidden`, `ProviderRowState.accountDetailHidden`, `DashboardAccountSnapshot.isAccountDetailHidden`, `DashboardAccountSnapshot.showsAccountPrivacyToggle`, and `DashboardViewModel.toggleAccountDetailVisibility(_:)`.
