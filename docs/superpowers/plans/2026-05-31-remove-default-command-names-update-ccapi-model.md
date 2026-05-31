# Remove Default Command Names and Update ccapi Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove automatic default shell command names for `cc`, `ccapi`, and `ccodex`, while updating the default Claude API model to `claude-opus-4-8` without overwriting existing saved user config.

**Architecture:** Keep fallback/reset defaults in `AppConfig.default`, and represent unconfigured command names as empty strings. Rendering and automatic shell install should derive effective enabled functions by combining provider availability with non-blank command names, so blank defaults are skipped instead of validated or rendered. Stored config decoding remains value-preserving, so existing explicit command names and `ccapi.model` values survive app updates.

**Tech Stack:** Swift, Swift Package Manager, XCTest, macOS shell function rendering.

---

## File Structure

- Modify `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - Owns app-wide persisted configuration and fallback defaults.
  - Change `AppConfig.default.commands.ccapi` from `"ccapi"` to `""`.
  - Change `AppConfig.default.ccapi.model` from `"claude-opus-4-7"` to `"claude-opus-4-8"`.

- Modify `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - Owns shell function script generation and validation.
  - Filter enabled functions through non-blank command names before validation and rendering.
  - Keep invalid non-blank command names failing when their provider is renderable.

- Modify `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
  - Owns automatic shell install orchestration.
  - Add the missing non-blank command-name gate for `ccapi`, matching the existing `cc` and `ccodex` gates.

- Modify `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Owns settings save, profile availability, and conflict checks.
  - Ensure `ccapi` save validates only the explicitly edited command name for `.zshrc` conflicts.
  - Keep `activeFunctionNames(in:)` excluding blank active names.

- Modify `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - Verify default command names and default Claude API model.
  - Verify decoding preserves existing saved command names and saved model values.

- Modify `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
  - Verify store fallback default expectations match the new defaults.

- Modify `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
  - Verify enabled providers with blank command names are skipped.
  - Verify explicit `ccapi` command names still render when enabled.
  - Verify invalid disabled/blank provider names do not block rendering.

- Modify `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
  - Verify `ccapi` is included only when both API key and explicit command name exist.
  - Verify API key alone no longer creates a `ccapi()` function.

- Modify `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - Verify active provider installation ignores blank command names.

- Modify `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
  - Verify `saveClaudeAPISettings` validates only the edited `ccapi` command name against shell profile conflicts and persists explicit values.

---

### Task 1: Update config default regression tests

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

- [ ] **Step 1: Update `AppConfigTests.testDefaultConfigMatchesMVPDecisions` expected defaults**

Change the command and Claude API model assertions in `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` to:

```swift
XCTAssertEqual(config.commands.cc, "")
XCTAssertEqual(config.commands.ccapi, "")
XCTAssertEqual(config.commands.ccodex, "")
XCTAssertEqual(config.ccapi.model, "claude-opus-4-8")
```

The full test should read:

```swift
func testDefaultConfigMatchesMVPDecisions() {
    let config = AppConfig.default

    XCTAssertEqual(config.port, 18_317)
    XCTAssertEqual(config.commands.cc, "")
    XCTAssertEqual(config.commands.ccapi, "")
    XCTAssertEqual(config.commands.ccodex, "")
    XCTAssertEqual(config.ccapi.model, "claude-opus-4-8")
    XCTAssertEqual(config.ccodex.opus, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto))
    XCTAssertEqual(config.ccodex.sonnet, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto))
    XCTAssertEqual(config.ccodex.haiku, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto))
    XCTAssertFalse(config.includeDangerouslySkipPermissions)
    XCTAssertFalse(config.startAtLogin)
    XCTAssertTrue(config.showDockIcon)
    XCTAssertTrue(config.showMenuBarIcon)
    XCTAssertFalse(config.showNotifications)
    XCTAssertFalse(config.roundRobinEnabled)
}
```

- [ ] **Step 2: Add a decode preservation test in `AppConfigTests`**

Append this test after `testDefaultConfigMatchesMVPDecisions()`:

```swift
func testDecodedConfigPreservesSavedCommandNamesAndClaudeAPIModel() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "savedcc", "ccapi": "savedapi", "ccodex": "savedcodex" },
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

    XCTAssertEqual(config.commands.cc, "savedcc")
    XCTAssertEqual(config.commands.ccapi, "savedapi")
    XCTAssertEqual(config.commands.ccodex, "savedcodex")
    XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
}
```

- [ ] **Step 3: Update `AppConfigStoreTests.testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured`**

Change the expected defaults in `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift` to:

```swift
func testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured() {
    let config = AppConfig.default

    XCTAssertEqual(config.port, 18_317)
    XCTAssertEqual(config.commands.cc, "")
    XCTAssertEqual(config.commands.ccapi, "")
    XCTAssertEqual(config.commands.ccodex, "")
    XCTAssertEqual(config.ccapi.model, "claude-opus-4-8")
    XCTAssertEqual(config.ccodex.opus, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto))
    XCTAssertEqual(config.ccodex.sonnet, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto))
    XCTAssertEqual(config.ccodex.haiku, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto))
}
```

- [ ] **Step 4: Run the focused default tests and verify they fail before implementation**

Run:

```bash
swift test --filter AppConfigTests/testDefaultConfigMatchesMVPDecisions
swift test --filter AppConfigStoreTests/testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured
```

Expected before implementation: both fail because `AppConfig.default.commands.ccapi` is still `"ccapi"` and `AppConfig.default.ccapi.model` is still `"claude-opus-4-7"`.

---

### Task 2: Change `AppConfig.default` values

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`

- [ ] **Step 1: Update the default command names and Claude API model**

In `Sources/CLIProxyManagerCore/Config/AppConfig.swift`, change `AppConfig.default` from:

```swift
public static let `default` = AppConfig(
    port: 18_317,
    commands: Commands(cc: "", ccapi: "ccapi", ccodex: ""),
    ccapi: ClaudeAPI(model: "claude-opus-4-7"),
    ccodex: Codex(
        opus: CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto),
        sonnet: CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
        haiku: CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
    ),
    includeDangerouslySkipPermissions: false,
    startAtLogin: false,
    showDockIcon: true,
    showMenuBarIcon: true,
    appearance: .system
)
```

to:

```swift
public static let `default` = AppConfig(
    port: 18_317,
    commands: Commands(cc: "", ccapi: "", ccodex: ""),
    ccapi: ClaudeAPI(model: "claude-opus-4-8"),
    ccodex: Codex(
        opus: CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto),
        sonnet: CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
        haiku: CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
    ),
    includeDangerouslySkipPermissions: false,
    startAtLogin: false,
    showDockIcon: true,
    showMenuBarIcon: true,
    appearance: .system
)
```

- [ ] **Step 2: Run config tests**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter AppConfigStoreTests
```

Expected: both suites pass.

- [ ] **Step 3: Commit config default changes**

Run:

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "Update default Claude API command settings" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Only commit if the user has explicitly asked for commits during execution. If not, skip this step and continue with uncommitted changes.

---

### Task 3: Make shell rendering skip blank enabled command names

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`

- [ ] **Step 1: Add a failing renderer test for blank enabled command names**

Add this test after `testRenderCanCreateOnlyManagedHeaderBeforeProvidersAreConnected()` in `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`:

```swift
func testRenderSkipsEnabledProvidersWithBlankCommandNames() throws {
    let script = try ShellFunctionRenderer(
        config: .default,
        helperCommand: "/usr/local/bin/cliproxy-manager",
        enabledFunctions: ShellFunctionRenderer.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
    ).render()

    XCTAssertTrue(script.contains("Generated by CLIProxyAPI Manager"))
    XCTAssertFalse(script.contains("cc() {"))
    XCTAssertFalse(script.contains("ccodex() {"))
    XCTAssertFalse(script.contains("ccapi() {"))
}
```

Before implementation, this fails because the renderer validates enabled blank names and throws `ShellFunctionRendererError.invalidFunctionName("")`.

- [ ] **Step 2: Update the `configuredCommands` helper to include explicit `ccapi`**

Change the helper at the top of `ShellFunctionRendererTests.swift` from:

```swift
private func configuredCommands(_ config: AppConfig = .default) -> AppConfig {
    var config = config
    config.commands.cc = "cc"
    config.commands.ccodex = "ccodex"
    return config
}
```

to:

```swift
private func configuredCommands(_ config: AppConfig = .default) -> AppConfig {
    var config = config
    config.commands.cc = "cc"
    config.commands.ccapi = "ccapi"
    config.commands.ccodex = "ccodex"
    return config
}
```

This keeps existing renderer tests that intentionally include Claude API behavior explicit and independent of defaults.

- [ ] **Step 3: Run the new renderer test and verify it fails**

Run:

```bash
swift test --filter ShellFunctionRendererTests/testRenderSkipsEnabledProvidersWithBlankCommandNames
```

Expected before implementation: FAIL with `invalidFunctionName("")`.

- [ ] **Step 4: Add renderability helpers in `ShellFunctionRenderer`**

In `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`, add this private helper near `functionNamesToRender()`:

```swift
private func hasCommandName(_ commandName: String) -> Bool {
    !commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
```

- [ ] **Step 5: Gate each rendered function by enabled flag and non-blank command name**

In `render()`, change the three rendering conditionals from:

```swift
if enabledFunctions.claudeOAuth {
```

```swift
if enabledFunctions.codex {
```

```swift
if enabledFunctions.claudeAPI {
```

to:

```swift
if enabledFunctions.claudeOAuth, hasCommandName(config.commands.cc) {
```

```swift
if enabledFunctions.codex, hasCommandName(config.commands.ccodex) {
```

```swift
if enabledFunctions.claudeAPI, hasCommandName(config.commands.ccapi) {
```

- [ ] **Step 6: Filter blank names before validation**

Change `functionNamesToRender()` from:

```swift
private func functionNamesToRender() -> [String] {
    var names: [String] = []
    if enabledFunctions.claudeOAuth { names.append(config.commands.cc) }
    if enabledFunctions.codex { names.append(config.commands.ccodex) }
    if enabledFunctions.claudeAPI { names.append(config.commands.ccapi) }
    return names
}
```

to:

```swift
private func functionNamesToRender() -> [String] {
    var names: [String] = []
    if enabledFunctions.claudeOAuth, hasCommandName(config.commands.cc) { names.append(config.commands.cc) }
    if enabledFunctions.codex, hasCommandName(config.commands.ccodex) { names.append(config.commands.ccodex) }
    if enabledFunctions.claudeAPI, hasCommandName(config.commands.ccapi) { names.append(config.commands.ccapi) }
    return names
}
```

- [ ] **Step 7: Run renderer tests**

Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: all renderer tests pass.

- [ ] **Step 8: Commit renderer changes**

Run:

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift \
  Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "Skip blank shell command names when rendering" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Only commit if the user has explicitly asked for commits during execution. If not, skip this step and continue with uncommitted changes.

---

### Task 4: Gate automatic `ccapi` install by explicit command name

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`

- [ ] **Step 1: Update the existing Claude API inclusion test to set an explicit command name**

In `testApplyIncludesClaudeAPIWhenSecretExists`, update the config setup to include `ccapi` explicitly:

```swift
var config = AppConfig.default
config.commands.cc = "cc"
config.commands.ccapi = "ccapi"
config.commands.ccodex = "ccodex"
```

Keep these assertions:

```swift
XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex", "ccapi"])
XCTAssertTrue(installer.installedScript?.contains("ccapi() {") == true)
```

- [ ] **Step 2: Add a regression test that API key alone does not install `ccapi`**

Add this test after `testApplyIncludesClaudeAPIWhenSecretExists()`:

```swift
func testApplySkipsClaudeAPIWhenCommandNameIsBlankEvenIfSecretExists() throws {
    let installer = StubShellInstaller()
    let service = AutomaticShellInstallService(
        installer: installer,
        secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
        helperCommand: "/usr/local/bin/cliproxy-manager"
    )

    var config = AppConfig.default
    config.commands.cc = "cc"
    config.commands.ccodex = "ccodex"

    try service.apply(
        config: config,
        enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
    )

    XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
    XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
}
```

- [ ] **Step 3: Run the new automatic install test and verify it fails before implementation**

Run:

```bash
swift test --filter AutomaticShellInstallServiceTests/testApplySkipsClaudeAPIWhenCommandNameIsBlankEvenIfSecretExists
```

Expected before implementation: FAIL because `includeClaudeAPI` only checks the API key and provider flag.

- [ ] **Step 4: Add the non-blank command-name gate for Claude API**

In `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`, change:

```swift
let includeClaudeAPI = try enabledFunctions.claudeAPI && hasClaudeAPIKey()
```

to:

```swift
let includeClaudeAPI = try enabledFunctions.claudeAPI
    && !config.commands.ccapi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && hasClaudeAPIKey()
```

- [ ] **Step 5: Run automatic install tests**

Run:

```bash
swift test --filter AutomaticShellInstallServiceTests
```

Expected: all automatic install tests pass.

- [ ] **Step 6: Commit automatic install changes**

Run:

```bash
git add Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift \
  Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift
git commit -m "Require explicit ccapi command before shell install" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Only commit if the user has explicitly asked for commits during execution. If not, skip this step and continue with uncommitted changes.

---

### Task 5: Validate explicit `ccapi` saves without depending on defaults

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`

- [ ] **Step 1: Add a test that saving `ccapi` validates only the edited command name against `.zshrc` conflicts**

Add this test near the existing command-name validation tests in `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`:

```swift
func testSaveClaudeAPISettingsValidatesEditedCommandNameOnly() throws {
    var config = AppConfig.default
    config.commands.cc = "bad;rm"
    config.commands.ccodex = "also;bad"
    let store = StubConfigStore(config: config)
    let installer = StubShellInstaller(conflictingFunctionNames: ["ccapi"])
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: installer,
        authProfileStore: StubAuthProfileStore(profiles: []),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )
    installer.reset()

    XCTAssertThrowsError(try viewModel.saveClaudeAPISettings(functionName: "ccapi", model: "claude-opus-4-8")) { error in
        XCTAssertEqual(error as? ShellFunctionInstallerError, .conflictingFunctionNames(["ccapi"]))
    }

    XCTAssertEqual(installer.validatedFunctionNames, [["ccapi"]])
    XCTAssertEqual(store.savedConfigs, [])
}
```

This confirms the save path validates the edited `ccapi` command against shell-profile conflicts without validating unrelated inactive invalid provider names.

- [ ] **Step 2: Add a test that saving `ccapi` persists explicit command and model values**

Add this test after the previous one:

```swift
func testSaveClaudeAPISettingsPersistsExplicitCommandNameAndModel() throws {
    let store = StubConfigStore(config: .default)
    let installer = StubShellInstaller()
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: installer,
        authProfileStore: StubAuthProfileStore(profiles: []),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )
    installer.reset()

    try viewModel.saveClaudeAPISettings(functionName: " myapi ", model: "claude-sonnet-4-6")

    XCTAssertEqual(store.savedConfigs.last?.commands.ccapi, "myapi")
    XCTAssertEqual(store.savedConfigs.last?.ccapi.model, "claude-sonnet-4-6")
}
```

- [ ] **Step 3: Run the new provider settings test and verify the first test fails before implementation**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testSaveClaudeAPISettingsValidatesEditedCommandNameOnly
```

Expected before implementation: FAIL if `saveClaudeAPISettings` validates all active names through the generic path or does not call `shellInstaller.validateFunctionNames(["ccapi"])`.

- [ ] **Step 4: Update `saveClaudeAPISettings` to pass explicit validation names**

In `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`, change:

```swift
func saveClaudeAPISettings(functionName: String, model: String) throws {
    var updatedConfig = config
    updatedConfig.commands.ccapi = normalizeCommandName(functionName)
    updatedConfig.ccapi = AppConfig.ClaudeAPI(model: model)
    try saveConfig(updatedConfig, validateShellFunctions: true)
}
```

to:

```swift
func saveClaudeAPISettings(functionName: String, model: String) throws {
    var updatedConfig = config
    updatedConfig.commands.ccapi = normalizeCommandName(functionName)
    updatedConfig.ccapi = AppConfig.ClaudeAPI(model: model)
    try saveConfig(
        updatedConfig,
        validateShellFunctions: true,
        shellProfileValidationNames: [updatedConfig.commands.ccapi]
    )
}
```

- [ ] **Step 5: Run provider settings tests**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests
```

Expected: all provider settings tests pass.

- [ ] **Step 6: Commit provider settings changes**

Run:

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "Validate explicit Claude API command saves" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Only commit if the user has explicitly asked for commits during execution. If not, skip this step and continue with uncommitted changes.

---

### Task 6: Verify dashboard install ignores blank active command names

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Add a dashboard regression test for connected profiles with blank command names**

Add this test after `testInstallShellFunctionsInstallsActiveProvidersOnly()` in `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`:

```swift
func testInstallShellFunctionsSkipsConnectedProvidersWithBlankCommandNames() throws {
    let installer = StubShellInstaller()
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: .default),
        shellInstaller: installer,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )
    installer.reset()

    try viewModel.installShellFunctions(helperCommand: "/usr/local/bin/cliproxy-manager")

    XCTAssertEqual(installer.installedFunctionNames, [])
    XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
    XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
    XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
}
```

- [ ] **Step 2: Run the new dashboard test**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallShellFunctionsSkipsConnectedProvidersWithBlankCommandNames
```

Expected after Tasks 3 and 4: PASS. If it fails, inspect whether `activeFunctionNames(in:)` and `AutomaticShellInstallService.apply` both exclude blank commands.

- [ ] **Step 3: Run dashboard tests**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: all dashboard tests pass.

- [ ] **Step 4: Commit dashboard regression test**

Run:

```bash
git add Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "Cover blank command names in dashboard install" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Only commit if the user has explicitly asked for commits during execution. If not, skip this step and continue with uncommitted changes.

---

### Task 7: Update stale model expectations and run focused suites

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift` if any stale `ccapi` default assumptions remain.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` if any new default model expectations remain stale.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift` if any new default model expectations remain stale.

- [ ] **Step 1: Search for stale default command/model assumptions**

Run:

```bash
rg -n 'commands\.ccapi, "ccapi"|ccapi\.model, "claude-opus-4-7"|commands: Commands\(cc: "", ccapi: "ccapi"|ccapi\(\) \{' Sources Tests
```

Expected after implementation: no stale default assertions. Occurrences of `"ccapi"` are allowed only where tests explicitly configure a command name or verify explicit saved values.

- [ ] **Step 2: Update Claude OAuth model expectation if product default changed separately**

Do not change the OAuth proxy default model literals in `ShellFunctionRenderer.render()` as part of this task. The line:

```swift
let claudeOpusModel = "claude-opus-4-7"
```

is for the Claude OAuth proxy function, not the `ccapi` direct API model. Leave it unchanged unless a separate requirement explicitly asks to update OAuth model mapping.

- [ ] **Step 3: Run focused test suites**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter AppConfigStoreTests
swift test --filter ShellFunctionRendererTests
swift test --filter AutomaticShellInstallServiceTests
swift test --filter ProviderSettingsViewModelTests
swift test --filter DashboardViewModelTests
```

Expected: all focused suites pass.

---

### Task 8: Run full verification

**Files:**
- No source modifications expected.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Inspect git diff**

Run:

```bash
git diff -- Sources Tests docs/superpowers/specs docs/superpowers/plans
```

Expected: diff contains only the intended config default, renderer gating, automatic install gating, dashboard/provider tests, and the approved spec/plan documents.

- [ ] **Step 3: Report verification results**

Report:

```text
Focused tests: pass/fail with command names.
Full test suite: pass/fail with command name.
Changed files: list of source/test/spec/plan files.
Skipped steps: commit steps skipped unless user explicitly requested commits.
```

- [ ] **Step 4: Final commit if explicitly requested**

If the user explicitly asks to commit all work, run:

```bash
git add Sources Tests docs/superpowers/specs/2026-05-31-remove-default-command-names-update-ccapi-model-design.md docs/superpowers/plans/2026-05-31-remove-default-command-names-update-ccapi-model.md
git commit -m "Remove default shell command names" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Do not commit without explicit user instruction.

---

## Self-Review

- Spec coverage:
  - Blank defaults for `cc`, `ccapi`, `ccodex`: Tasks 1 and 2.
  - Default `ccapi.model == "claude-opus-4-8"`: Tasks 1 and 2.
  - Preserve existing saved command/model values: Task 1 decode preservation test.
  - Skip blank command names in rendering: Task 3.
  - Skip blank command names in automatic install: Task 4.
  - Dashboard active conflict/install path ignores blank names: Task 6.
  - Explicit command-name validation for saves: Task 5.
- Placeholder scan: no TBD/TODO/fill-in instructions remain; all code-changing steps include concrete code.
- Type consistency: all symbols match existing files: `AppConfig.Commands`, `AppConfig.ClaudeAPI`, `ShellFunctionRenderer.EnabledFunctions`, `AutomaticShellInstallService.EnabledFunctions`, `saveClaudeAPISettings(functionName:model:)`, `ShellCommandNameValidator`, and test stub names.
