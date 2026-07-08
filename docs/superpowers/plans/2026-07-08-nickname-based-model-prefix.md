# Nickname-based Model Prefix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace verbose auth-file-derived OAuth model prefixes with short, routable prefixes based on account nickname, falling back to a short auth profile token when nickname is blank.

**Architecture:** `DashboardViewModel` remains the single owner of OAuth command profile reconciliation and persistence preparation. It recomputes every `OAuthCommandProfile.modelPrefix` from provider + nickname/fallback, enforces uniqueness with numeric suffixes, and syncs the resulting prefix into the matching auth JSON through `AuthProfileManaging.setPrefix(_:id:)`. `ShellFunctionRenderer` continues to render `<modelPrefix>/<model>` unchanged; tests assert it receives short provider-qualified prefixes.

**Tech Stack:** Swift 6, SwiftPM, XCTest, SwiftUI view-model code, existing `CLIProxyManagerCore` config/auth/shell types.

## Global Constraints

- Keep CLIProxyAPI account routing based on model prefix.
- Do not change CLIProxyAPI.
- Do not hide or transform model names inside Claude Code separately from the actual environment model value; the actual value must remain routable as `<prefix>/<model>`.
- Prefer the app-level account nickname for the prefix.
- When nickname is blank, use a deterministic short fallback derived from the auth profile ID.
- Prefix includes provider identity: examples include `claude-work`, `codex-team`, `codex-classting-team`, `codex-18c2ca10`.
- Slug rules: lowercase; ASCII letters and digits are kept; any other run of characters becomes one `-`; leading/trailing `-` is trimmed; no `/` is allowed in the prefix.
- Empty nickname slug falls back to the auth-profile fallback.
- Prefixes are unique across all command profiles; duplicates receive `-2`, `-3`, etc.
- Existing long auth-file-derived prefixes are replaced on reconciliation/save.
- Development build launch/verification must use `/Users/woosublee/.cliproxy-manager/dev` settings, not `/Users/woosublee/.cliproxy-manager`.
- Do not commit unless the user explicitly authorizes commits in the execution phase. If commits are authorized, every commit message must end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

---

## File Structure

- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Responsibility: OAuth command profile reconciliation, nickname/fallback route prefix computation, uniqueness, save-time recomputation, auth JSON prefix sync.
  - Keep helper methods private/static inside the existing file because prefix generation is only used by the view model today.
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
  - Responsibility: settings-save behavior, prefix recomputation, auth store prefix sync, same-provider profile regression expectations.
  - Extend the local `StubAuthProfileStore` with prefix-update recording.
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
  - Responsibility: shell renderer regression coverage that short provider-qualified `modelPrefix` values are emitted unchanged as `<prefix>/<model>`.
- Optional modify if a focused test already exists there and is easier to extend: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - Prefer `ProviderSettingsViewModelTests.swift` for prefix reconciliation tests because its auth store stub already supports ID-based `setPrefix(_:id:)`.

---

### Task 1: Recompute model prefixes during OAuth command profile reconciliation

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:852-971`

**Interfaces:**
- Consumes: `AppConfig.OAuthCommandProfile` fields `provider`, `authProfileID`, `nickname`, `modelPrefix`.
- Produces: private static helpers in `DashboardViewModel`:
  - `commandProfilesWithRecomputedModelPrefixes(_:) -> [AppConfig.OAuthCommandProfile]`
  - `uniqueModelPrefix(provider:nickname:authProfileID:usedPrefixes:) -> String`
  - `modelPrefixBase(provider:nickname:authProfileID:) -> String`
  - `shortAuthProfileSlug(provider:authProfileID:) -> String`
  - `nonEmptySlug(for:) -> String?`

- [ ] **Step 1: Add failing reconciliation tests**

Add these tests inside `ProviderSettingsViewModelTests`, near `testSameProviderCanHaveTwoAccountsAndCommandProfiles()`:

```swift
func testReconciliationUsesNicknameBasedModelPrefixesWithDuplicateSuffixes() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            nickname: "Work",
            modelPrefix: "claude-claude-work-json"
        ),
        AppConfig.OAuthCommandProfile(
            id: "codex-team",
            provider: .codex,
            authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
            nickname: "Team",
            modelPrefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"
        ),
        AppConfig.OAuthCommandProfile(
            id: "codex-team-secondary",
            provider: .codex,
            authProfileID: "codex-dntjqdlekd-gmail-com-pro.json",
            nickname: "Team",
            modelPrefix: "codex-codex-dntjqdlekd-gmail-com-pro-json"
        )
    ]

    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-claude-work-json"),
            AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"),
            AuthProfile(fileName: "codex-dntjqdlekd-gmail-com-pro.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-dntjqdlekd-gmail-com-pro-json")
        ]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), [
        "claude-work",
        "codex-team",
        "codex-team-2"
    ])
}

func testBlankNicknameFallsBackToShortAuthProfileModelPrefix() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(
            id: "codex-team",
            provider: .codex,
            authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
            nickname: "   ",
            modelPrefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"
        )
    ]

    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-18c2ca10-woosub-classting-com-team-json")
        ]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
}
```

- [ ] **Step 2: Update the existing same-provider expectation**

In `testSameProviderCanHaveTwoAccountsAndCommandProfiles()`, change the model prefix assertion from the old auth-file-derived values to the new short fallback values:

```swift
XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["claude-work", "claude-personal"])
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testReconciliationUsesNicknameBasedModelPrefixesWithDuplicateSuffixes
```

Expected before production changes: FAIL because `modelPrefix` remains the stored long value such as `claude-claude-work-json`.

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testBlankNicknameFallsBackToShortAuthProfileModelPrefix
```

Expected before production changes: FAIL because `modelPrefix` remains the stored long value instead of `codex-18c2ca10`.

- [ ] **Step 4: Implement nickname/fallback prefix helpers**

In `DashboardViewModel.swift`, replace the existing `modelPrefix(provider:authProfileID:)` helper with these helpers. Keep `commandProfileID(...)` as-is except that it continues to call `slug(for:)`.

```swift
private static func commandProfilesWithRecomputedModelPrefixes(
    _ commandProfiles: [AppConfig.OAuthCommandProfile]
) -> [AppConfig.OAuthCommandProfile] {
    var usedPrefixes: Set<String> = []
    return commandProfiles.map { commandProfile in
        var updatedProfile = commandProfile
        updatedProfile.modelPrefix = uniqueModelPrefix(
            provider: commandProfile.provider,
            nickname: commandProfile.nickname,
            authProfileID: commandProfile.authProfileID,
            usedPrefixes: &usedPrefixes
        )
        return updatedProfile
    }
}

private static func uniqueModelPrefix(
    provider: AuthProfileType,
    nickname: String,
    authProfileID: String,
    usedPrefixes: inout Set<String>
) -> String {
    let basePrefix = modelPrefixBase(provider: provider, nickname: nickname, authProfileID: authProfileID)
    var candidate = basePrefix
    var suffix = 2
    while usedPrefixes.contains(candidate) {
        candidate = "\(basePrefix)-\(suffix)"
        suffix += 1
    }
    usedPrefixes.insert(candidate)
    return candidate
}

private static func modelPrefixBase(provider: AuthProfileType, nickname: String, authProfileID: String) -> String {
    let suffix = nonEmptySlug(for: nickname) ?? shortAuthProfileSlug(provider: provider, authProfileID: authProfileID)
    return "\(provider.rawValue)-\(suffix)"
}

private static func shortAuthProfileSlug(provider: AuthProfileType, authProfileID: String) -> String {
    let fileName = URL(fileURLWithPath: authProfileID).deletingPathExtension().lastPathComponent
    let fullSlug = slug(for: fileName)
    let providerPrefix = "\(provider.rawValue)-"
    let suffixSource: String
    if fullSlug == provider.rawValue {
        suffixSource = "account"
    } else if fullSlug.hasPrefix(providerPrefix) {
        suffixSource = String(fullSlug.dropFirst(providerPrefix.count))
    } else {
        suffixSource = fullSlug
    }

    let firstSegment = suffixSource.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    return firstSegment.isEmpty ? "account" : firstSegment
}

private static func nonEmptySlug(for value: String) -> String? {
    let slug = rawSlug(for: value)
    return slug.isEmpty ? nil : slug
}

private static func slug(for value: String) -> String {
    let slug = rawSlug(for: value)
    return slug.isEmpty ? "account" : slug
}

private static func rawSlug(for value: String) -> String {
    let lowercasedValue = value.lowercased()
    var result = ""
    var previousWasSeparator = false
    for scalar in lowercasedValue.unicodeScalars {
        let isAllowed = (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value))
        if isAllowed {
            result.unicodeScalars.append(scalar)
            previousWasSeparator = false
        } else if !previousWasSeparator {
            result.append("-")
            previousWasSeparator = true
        }
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
```

- [ ] **Step 5: Recompute prefixes from reconciliation**

In `reconciledOAuthCommandProfiles(in:authProfiles:)`, change the appended profile’s `modelPrefix` argument from:

```swift
modelPrefix: authProfile.prefix ?? modelPrefix(provider: authProfile.type, authProfileID: authProfile.id),
```

to:

```swift
modelPrefix: "",
```

Then replace the end of the method from:

```swift
updatedConfig.oauthCommandProfiles = commandProfiles
return mirroredLegacyFields(in: updatedConfig)
```

to:

```swift
updatedConfig.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(commandProfiles)
return mirroredLegacyFields(in: updatedConfig)
```

- [ ] **Step 6: Stop preserving long auth JSON prefix after OAuth login**

In `reconcileOAuthLoginCompletion(providerType:beforeProfiles:)`, remove this block:

```swift
if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.authProfileID == selectedProfile.id }) {
    updatedConfig.oauthCommandProfiles[index].isEnabled = true
    updatedConfig.oauthCommandProfiles[index].modelPrefix = selectedProfile.prefix
        ?? updatedConfig.oauthCommandProfiles[index].modelPrefix
}
```

Replace it with:

```swift
if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.authProfileID == selectedProfile.id }) {
    updatedConfig.oauthCommandProfiles[index].isEnabled = true
}
```

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testReconciliationUsesNicknameBasedModelPrefixesWithDuplicateSuffixes
swift test --filter ProviderSettingsViewModelTests/testBlankNicknameFallsBackToShortAuthProfileModelPrefix
swift test --filter ProviderSettingsViewModelTests/testSameProviderCanHaveTwoAccountsAndCommandProfiles
```

Expected: all three pass.

- [ ] **Step 8: Commit if authorized**

Only if the user has explicitly authorized commits for this execution phase, run:

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "feat: derive OAuth model prefixes from nicknames

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If commits are not authorized, do not commit; record this task as changed but uncommitted.

---

### Task 2: Recompute and sync model prefixes on settings save

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:1028-1097`

**Interfaces:**
- Consumes from Task 1: `commandProfilesWithRecomputedModelPrefixes(_:)`.
- Produces save-time behavior:
  - `saveConfig(...)` persists recomputed `modelPrefix` values.
  - `savePrivacyOnlyConfig(...)` also preserves recomputed `modelPrefix` values.
  - `saveConfig(...)` calls `reconcileAuthProfilePrefixes()` after local config state updates so auth JSON receives the new short prefix.

- [ ] **Step 1: Extend the ProviderSettings auth store stub to record prefix updates**

In `ProviderSettingsViewModelTests.swift`, add this property to `StubAuthProfileStore`:

```swift
private(set) var prefixUpdates: [PrefixUpdate] = []
```

Change `setPrefix(_ prefix:id:)` from:

```swift
func setPrefix(_ prefix: String?, id: String) throws -> Bool {
    guard let index = profilesValue.firstIndex(where: { $0.id == id }) else { return false }
    let profile = profilesValue[index]
    profilesValue[index] = AuthProfile(
        fileName: profile.fileName,
        type: profile.type,
        email: profile.email,
        accountID: profile.accountID,
        expired: profile.expired,
        disabled: profile.disabled,
        prefix: prefix
    )
    return true
}
```

to:

```swift
func setPrefix(_ prefix: String?, id: String) throws -> Bool {
    guard let index = profilesValue.firstIndex(where: { $0.id == id }) else { return false }
    prefixUpdates.append(PrefixUpdate(id: id, prefix: prefix))
    let profile = profilesValue[index]
    profilesValue[index] = AuthProfile(
        fileName: profile.fileName,
        type: profile.type,
        email: profile.email,
        accountID: profile.accountID,
        expired: profile.expired,
        disabled: profile.disabled,
        prefix: prefix
    )
    return true
}
```

Add this struct near `DisabledIDUpdate`:

```swift
private struct PrefixUpdate: Equatable {
    let id: String
    let prefix: String?
}
```

- [ ] **Step 2: Add failing save-time recompute/sync tests**

Add these tests near the existing `testSaveClaudeOAuthSettingsPersistsFunctionNameAndPermission()` and `testSaveCodexSettingsPersistsFunctionNameRolesAndPermission()` tests:

```swift
func testSaveClaudeOAuthSettingsRecomputesModelPrefixFromNicknameAndSyncsAuthProfilePrefix() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            nickname: "Old Team",
            modelPrefix: "claude-old-team"
        )
    ]
    let store = StubConfigStore(config: config)
    let authStore = StubAuthProfileStore(profiles: [
        AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-old-team")
    ])
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: authStore,
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    try viewModel.saveClaudeOAuthSettings(
        provider: ProviderRowState.ID(rawValue: "claude-work"),
        functionName: "ccwork",
        nickname: "Work Team",
        dangerousPermissionsEnabled: false
    )

    XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.modelPrefix), ["claude-work-team"])
    XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["claude-work-team"])
    XCTAssertEqual(authStore.prefixUpdates, [PrefixUpdate(id: "claude-work.json", prefix: "claude-work-team")])
}

func testSaveCodexSettingsFallsBackToShortAuthProfilePrefixWhenNicknameIsBlankAndSyncsAuthProfilePrefix() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(
            id: "codex-team",
            provider: .codex,
            authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
            commandName: "ccteam",
            nickname: "Team",
            codex: testCodex(),
            modelPrefix: "codex-team"
        )
    ]
    let store = StubConfigStore(config: config)
    let authStore = StubAuthProfileStore(profiles: [
        AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-team")
    ])
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: authStore,
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    try viewModel.saveCodexSettings(
        provider: ProviderRowState.ID(rawValue: "codex-team"),
        functionName: "ccteam",
        nickname: "   ",
        codex: testCodex(),
        dangerousPermissionsEnabled: false
    )

    XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
    XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
    XCTAssertEqual(authStore.prefixUpdates, [PrefixUpdate(id: "codex-18c2ca10-woosub-classting-com-team.json", prefix: "codex-18c2ca10")])
}
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testSaveClaudeOAuthSettingsRecomputesModelPrefixFromNicknameAndSyncsAuthProfilePrefix
swift test --filter ProviderSettingsViewModelTests/testSaveCodexSettingsFallsBackToShortAuthProfilePrefixWhenNicknameIsBlankAndSyncsAuthProfilePrefix
```

Expected before production changes: FAIL because save-time config does not recompute `modelPrefix` from the changed nickname and does not call `reconcileAuthProfilePrefixes()` after save.

- [ ] **Step 4: Add a persistence-preparation helper**

In `DashboardViewModel.swift`, add this helper near `availableConfig(_:)`:

```swift
private static func persistedConfig(_ config: AppConfig) -> AppConfig {
    var updatedConfig = availableConfig(config)
    updatedConfig.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(updatedConfig.oauthCommandProfiles)
    return mirroredLegacyFields(in: updatedConfig)
}
```

- [ ] **Step 5: Use the helper in `saveConfig(...)`**

Change the first line inside `saveConfig(...)` from:

```swift
let updatedConfig = Self.mirroredLegacyFields(in: Self.availableConfig(updatedConfig))
```

to:

```swift
let updatedConfig = Self.persistedConfig(updatedConfig)
```

After these existing lines:

```swift
lastPersistedConfig = updatedConfig
config = updatedConfig
cards = ProfileCard.makeDefaultCards(config: updatedConfig)
rebuildOptionRows()
rebuildProviderRows(claudeStatus: nil, codexStatus: nil)
```

insert:

```swift
reconcileAuthProfilePrefixes()
```

Keep the shell apply call after prefix reconciliation:

```swift
try automaticShellInstallService.apply(config: updatedConfig, enabledFunctions: enabledShellFunctions(in: updatedConfig))
```

- [ ] **Step 6: Use the helper in `savePrivacyOnlyConfig(...)`**

Change this line:

```swift
let availableConfig = Self.mirroredLegacyFields(in: Self.availableConfig(updatedConfig))
```

to:

```swift
let availableConfig = Self.persistedConfig(updatedConfig)
```

After `rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)`, insert:

```swift
reconcileAuthProfilePrefixes()
```

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testSaveClaudeOAuthSettingsRecomputesModelPrefixFromNicknameAndSyncsAuthProfilePrefix
swift test --filter ProviderSettingsViewModelTests/testSaveCodexSettingsFallsBackToShortAuthProfilePrefixWhenNicknameIsBlankAndSyncsAuthProfilePrefix
swift test --filter ProviderSettingsViewModelTests/testSaveCodexSettingsKeepsViewModelStateAlignedWithPersistedConfigWhenShellApplyFails
swift test --filter ProviderSettingsViewModelTests/testToggleAccountDetailVisibilityDoesNotInstallShellFunctions
```

Expected: all pass.

- [ ] **Step 8: Commit if authorized**

Only if the user has explicitly authorized commits for this execution phase, run:

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "fix: sync nickname model prefixes on settings save

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If commits are not authorized, do not commit; record this task as changed but uncommitted.

---

### Task 3: Lock shell-renderer coverage to short provider-qualified prefixes

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift:128-189`

**Interfaces:**
- Consumes: `ShellFunctionRenderer.render()` and `AppConfig.OAuthCommandProfile.modelPrefix`.
- Produces: regression coverage that shell model env vars render short provider-qualified prefixes unchanged.
- Production code should not need changes in this task unless the test reveals a renderer regression.

- [ ] **Step 1: Update shell renderer test fixtures to provider-qualified short prefixes**

In `testRenderUsesMultipleOAuthCommandProfilesWithModelPrefixesAndCodexProfileMapping()`, change the `modelPrefix` values:

```swift
modelPrefix: "claude-work"
```

```swift
modelPrefix: "claude-personal"
```

```swift
modelPrefix: "codex-fast"
```

```swift
modelPrefix: "codex-deep"
```

Change the assertions from:

```swift
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='work/claude-opus-4-7'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='personal/claude-sonnet-4-6'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='fast/gpt-fast(high)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='fast/gpt-fast-mini'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='deep/gpt-deep(xhigh)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='deep/gpt-deep-mini(low)'"))
```

to:

```swift
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-7'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-personal/claude-sonnet-4-6'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-fast/gpt-fast(high)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-fast/gpt-fast-mini'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-deep/gpt-deep(xhigh)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-deep/gpt-deep-mini(low)'"))
```

- [ ] **Step 2: Add a renderer assertion for duplicate suffix-shaped prefixes**

Still in the same test, append this profile to `config.oauthCommandProfiles`:

```swift
AppConfig.OAuthCommandProfile(
    id: "codex-team-2",
    provider: .codex,
    authProfileID: "codex-team-2.json",
    commandName: "ccteam2",
    codex: AppConfig.Codex(
        opus: AppConfig.CodexRole(model: "gpt-team", reasoning: .xhigh, contextWindow: .context1m),
        sonnet: AppConfig.CodexRole(model: "gpt-team", reasoning: .medium, contextWindow: .auto),
        haiku: AppConfig.CodexRole(model: "gpt-team-mini", reasoning: .low, contextWindow: .auto)
    ),
    modelPrefix: "codex-team-2"
)
```

Add these assertions after `let script = try ...render()`:

```swift
XCTAssertTrue(script.contains("ccteam2() {"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-team-2/gpt-team(xhigh)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-team-2/gpt-team-mini(low)'"))
```

Update the pass-through count assertions because there is now one additional function:

```swift
XCTAssertEqual(script.components(separatedBy: "claude \"$@\"").count - 1, 4)
XCTAssertEqual(script.components(separatedBy: "claude --dangerously-skip-permissions \"$@\"").count - 1, 1)
```

- [ ] **Step 3: Run the focused renderer test**

Run:

```bash
swift test --filter ShellFunctionRendererTests/testRenderUsesMultipleOAuthCommandProfilesWithModelPrefixesAndCodexProfileMapping
```

Expected: PASS. If it fails, inspect the assertion string and only change production renderer code if it is dropping or altering the prefix.

- [ ] **Step 4: Commit if authorized**

Only if the user has explicitly authorized commits for this execution phase, run:

```bash
git add Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "test: cover short OAuth model prefixes in shell rendering

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If commits are not authorized, do not commit; record this task as changed but uncommitted.

---

### Task 4: Full verification and development build check

**Files:**
- Test-only verification; no source changes expected.
- If verification reveals failures, return to the task that introduced the failure and fix with a new failing test first.

**Interfaces:**
- Consumes: all production and test changes from Tasks 1-3.
- Produces: fresh evidence for test/build status and development root behavior.

- [ ] **Step 1: Run focused app tests**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests
```

Expected: PASS with 0 failures.

Run:

```bash
swift test --filter DashboardViewModelRefreshTests
```

Expected: PASS with 0 failures.

- [ ] **Step 2: Run focused core tests**

Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: PASS with 0 failures.

Run:

```bash
swift test --filter AppConfigTests/testManagedPathsDefaultRootUsesDevelopmentDirectoryInDebugBuilds
```

Expected in debug test builds: PASS and `ManagedPaths.defaultRootDirectory()` equals `/Users/woosublee/.cliproxy-manager/dev`.

- [ ] **Step 3: Run full Swift test suite**

Run:

```bash
swift test
```

Expected: PASS with 0 failures.

- [ ] **Step 4: Build the development executable**

Run:

```bash
swift build --product CLIProxyManager
```

Expected: `Build of product 'CLIProxyManager' complete!` and exit code 0.

- [ ] **Step 5: Build the debug `.app` bundle**

Run:

```bash
make CONFIGURATION=debug bundle
```

Expected: `Bundled build/CLIProxyManager.app` and exit code 0.

- [ ] **Step 6: Ad-hoc sign the debug `.app` bundle**

Run:

```bash
make CONFIGURATION=debug CODESIGN_IDENTITY=- sign
```

Expected: signing completes with exit code 0. Use ad-hoc identity `-`; do not use the missing local identity `cliproxymanager`.

- [ ] **Step 7: Verify the debug `.app` bundle**

Run:

```bash
make CONFIGURATION=debug CODESIGN_IDENTITY=- verify
```

Expected: `codesign verification passed` and exit code 0.

- [ ] **Step 8: Record verification limitations honestly**

If no manual OAuth flow is performed, report that real OAuth add-account routing was not manually verified. Do not claim visible Claude Code labels are fixed until either:

1. unit tests and shell renderer output show the generated env model values use short prefixes, or
2. the user manually confirms the actual Claude Code status label.

- [ ] **Step 9: Commit if authorized**

Only if the user has explicitly authorized commits for this execution phase and verification fixes changed files, run an appropriate commit command. If no files changed in Task 4, do not create an empty commit.

---

## Self-Review

- Spec coverage: Tasks 1-2 cover nickname priority, blank fallback, duplicate suffixes, existing long-prefix replacement, settings save recomputation, and auth JSON `setPrefix` sync. Task 3 covers shell renderer output. Task 4 covers focused tests, full tests, and development build/dev-root verification.
- Placeholder scan: This plan has no `TBD`, `TODO`, or vague “handle edge cases” steps. Every changed code step includes exact code or exact assertion replacements.
- Type consistency: Helper names in Task 1 are reused exactly in Task 2. Test code uses existing `DashboardViewModel`, `AppConfig.OAuthCommandProfile`, `ProviderRowState.ID`, `AuthProfile`, and local stubs already present in the test files.
- Scope check: The plan is one cohesive feature: short model-prefix generation and synchronization. It does not require a separate subsystem plan.
