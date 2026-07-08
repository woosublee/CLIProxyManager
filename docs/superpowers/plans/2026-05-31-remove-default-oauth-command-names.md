# Remove Default OAuth Command Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `cc`/`ccodex` from being restored automatically when config falls back to app defaults, while preserving explicitly saved user command names.

**Architecture:** Keep OAuth command names unconfigured in `AppConfig.default`, and treat blank OAuth command names as “not ready to render” during automatic shell installation. Explicit settings saves must still validate the edited command name so users cannot save an empty active command through the view model.

**Tech Stack:** Swift, Swift Package Manager, XCTest, macOS app bundle install via Makefile.

---

### Task 1: Add regression test for blank default OAuth command names

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

- [x] **Step 1: Write the failing test**

```swift
func testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured() {
    let config = AppConfig.default

    XCTAssertEqual(config.port, 18_317)
    XCTAssertEqual(config.commands.cc, "")
    XCTAssertEqual(config.commands.ccapi, "ccapi")
    XCTAssertEqual(config.commands.ccodex, "")
}
```

- [x] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter AppConfigStoreTests/testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured
```

Expected: FAIL because `AppConfig.default.commands.cc` is `"cc"` and `ccodex` is `"ccodex"`.

### Task 2: Remove OAuth command defaults and skip blank render targets

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`

- [ ] **Step 1: Set default OAuth command names to blank**

Change `AppConfig.default.commands` to:

```swift
commands: Commands(cc: "", ccapi: "ccapi", ccodex: ""),
```

- [ ] **Step 2: Filter blank active command names**

In `DashboardViewModel.activeFunctionNames(in:)`, append provider command names only when they are non-empty after trimming.

- [ ] **Step 3: Validate explicitly edited command names**

In `DashboardViewModel.saveConfig`, when `shellProfileValidationNames` is provided, validate those names with `ShellCommandNameValidator` before checking shell profile conflicts.

- [ ] **Step 4: Skip blank command names in automatic shell rendering**

In `AutomaticShellInstallService.apply`, compute effective enabled functions by requiring both the profile flag and a non-empty command name.

### Task 3: Update tests and verify

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Update tests that asserted default `cc`/`ccodex`**

Change expectations for `AppConfig.default` to blank OAuth command names. Where a test needs an actual rendered function, set `config.commands.cc` or `config.commands.ccodex` explicitly in test setup.

- [ ] **Step 2: Run focused tests**

Run:

```bash
swift test --filter AppConfigStoreTests
swift test --filter AppConfigTests
swift test --filter ProviderSettingsViewModelTests
swift test --filter AutomaticShellInstallServiceTests
swift test --filter DashboardViewModelTests
```

Expected: all focused tests pass.

- [ ] **Step 3: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

### Task 4: Build, install, and verify app

**Files:**
- No source file modifications.

- [ ] **Step 1: Build and install using current tag version**

Run:

```bash
VERSION=$(git describe --tags --exact-match HEAD | sed 's/^v//') \
BUILD_NUMBER=$(plutil -extract CFBundleVersion raw Info.plist) \
make install CODESIGN_IDENTITY="8B6E37D522DC05E5797A93C89B0EFD7EBDD68E00" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER"
```

- [ ] **Step 2: Verify installed app**

Run:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/CLIProxyManager.app
plutil -extract CFBundleShortVersionString raw /Applications/CLIProxyManager.app/Contents/Info.plist
```

Expected: codesign passes and version remains `0.1.4`.
