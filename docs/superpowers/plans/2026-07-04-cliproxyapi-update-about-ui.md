# CLIProxyAPI Update About UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move CLIProxyAPI binary update controls from Server settings to About > Updates, and show both current and target versions whenever a CLIProxyAPI update is available or pending.

**Architecture:** Keep the existing `CLIProxyAPIUpdateService` orchestration and file-system behavior unchanged. Move only SwiftUI ownership of the update row from `ServerSettingsView` to `AboutSettingsView`, and centralize version-aware UI copy in existing helper functions so Dashboard prompts and About rows use the same wording rules.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, SwiftPM, macOS 15, existing `CLIProxyManagerApp` and `CLIProxyManagerCore` targets.

## Global Constraints

- CLIProxyAPI binary update controls must not remain in `Settings > Server`.
- CLIProxyAPI binary update controls must live under `Settings > About > Updates`.
- New available update copy must show current version and available version together.
- Pending update copy must show current version and pending version together.
- Dashboard automatic update prompts must show current and target versions.
- Button titles must include the target version whenever a target version exists.
- If the server is running, the immediate apply button must state that the server will restart.
- Existing CLIProxyAPI download, checksum verification, pending storage, and active apply behavior must not change.
- Existing Sparkle app update UI and behavior must remain in About > Updates.
- Do not add a Server-tab read-only summary or redirect row for CLIProxyAPI updates.
- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for local SwiftPM build/test commands when SwiftUI macros are involved.
- Commit messages must end with `Co-Authored-By: Claude <noreply@anthropic.com>`.

---

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - Responsibility: Settings subviews and update UI copy helpers currently live here.
  - Changes: remove CLIProxyAPI update controls from `ServerSettingsView`; add `viewModel` and `cliProxyAPIUpdateService` dependencies plus CLIProxyAPI update controls to `AboutSettingsView`; update helper functions to include target versions.
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
  - Responsibility: Routes settings tabs to concrete settings views.
  - Changes: stop passing `cliProxyAPIUpdateService` into `ServerSettingsView`; start passing `viewModel` and `cliProxyAPIUpdateService` into `AboutSettingsView`.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - Responsibility: Main window and automatic CLIProxyAPI update confirmation dialogs.
  - Changes: use version-aware helper functions for dialog titles and buttons.
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`
  - Responsibility: Unit/source tests for CLIProxyAPI update UI copy and placement.
  - Changes: assert current/target version copy, target-version button titles, Dashboard prompt helper copy, and About-vs-Server placement.

---

### Task 1: Version-aware CLIProxyAPI update copy helpers

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift:5-120`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:244-279`

**Interfaces:**
- Consumes: existing `CLIProxyAPIRelease`, `CLIProxyAPIBinaryManifest`, `CLIProxyAPIUpdateServiceState`.
- Produces:
  - `cliproxyAPIUpdateDescription(currentVersion:state:availableUpdate:pendingUpdate:) -> String`
  - `cliproxyAPIUpdateActionTitle(state:availableUpdate:pendingUpdate:) -> String`
  - `cliProxyAPIAvailableUpdatePromptTitle(currentVersion:availableUpdate:) -> String`
  - `cliProxyAPIPendingUpdatePromptTitle(pendingUpdate:) -> String`
  - `cliProxyAPIPendingUpdatePromptMessage(currentVersion:) -> String`
  - `cliProxyAPIApplyButtonTitle(pendingUpdate:isServerRunning:) -> String`

- [ ] **Step 1: Replace the copy-helper tests with version-aware expectations**

Replace the contents of `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift` from the start of `final class CLIProxyAPIUpdateUITests` through `testServerSettingsActionTitleReflectsState()` with this code:

```swift
final class CLIProxyAPIUpdateUITests: XCTestCase {
    func testUpdateDescriptionShowsCurrentVersionByDefault() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .idle,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41"
        )
    }

    func testUpdateDescriptionShowsCurrentAndAvailableVersion() {
        let release = release("7.2.42")

        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .updateAvailable,
                availableUpdate: release,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Available version: 7.2.42"
        )
    }

    func testUpdateDescriptionShowsCurrentAndPendingVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .pending,
                availableUpdate: nil,
                pendingUpdate: manifest("7.2.42")
            ),
            "Current version: 7.2.41 · Pending version: 7.2.42"
        )
    }

    func testUpdateDescriptionShowsProgressStatesWithCurrentVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .checking,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Checking for updates…"
        )
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .downloading,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Downloading and verifying update…"
        )
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .failed("Network unavailable"),
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Last check failed."
        )
    }

    func testUpdateActionTitleReflectsTargetVersion() {
        let release = release("7.2.42")

        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .idle, availableUpdate: nil, pendingUpdate: nil), "Check now")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .checking, availableUpdate: nil, pendingUpdate: nil), "Checking…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .downloading, availableUpdate: nil, pendingUpdate: nil), "Updating…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .updateAvailable, availableUpdate: release, pendingUpdate: nil), "Download 7.2.42")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .pending, availableUpdate: nil, pendingUpdate: manifest("7.2.42")), "Apply 7.2.42 now")
    }

    func testDashboardAvailablePromptTitleShowsCurrentAndTargetVersion() {
        XCTAssertEqual(
            cliProxyAPIAvailableUpdatePromptTitle(currentVersion: "7.2.41", availableUpdate: release("7.2.42")),
            "Update CLIProxyAPI from 7.2.41 to 7.2.42?"
        )
        XCTAssertEqual(
            cliProxyAPIAvailableUpdatePromptTitle(currentVersion: "7.2.41", availableUpdate: nil),
            "CLIProxyAPI update available"
        )
    }

    func testDashboardPendingPromptCopyShowsCurrentAndPendingVersion() {
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: manifest("7.2.42")),
            "Apply CLIProxyAPI 7.2.42?"
        )
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: nil),
            "Apply CLIProxyAPI update?"
        )
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptMessage(currentVersion: "7.2.41"),
            "Current version: 7.2.41"
        )
    }

    func testApplyButtonTitleShowsTargetVersionAndRestartWhenServerRuns() {
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: manifest("7.2.42"), isServerRunning: false),
            "Apply 7.2.42 now"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: manifest("7.2.42"), isServerRunning: true),
            "Apply 7.2.42 and restart server"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: nil, isServerRunning: false),
            "Apply now"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: nil, isServerRunning: true),
            "Apply now and restart server"
        )
    }
```

Keep the existing source tests that follow, and keep the private helpers at the bottom for now. Add this private helper above the existing `manifest(_:)` helper:

```swift
    private func release(_ version: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(
            version: CLIProxyAPIVersion(version)!,
            tagName: "v\(version)",
            assetName: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )
    }
```

- [ ] **Step 2: Run the focused UI tests and verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests
```

Expected result:

```text
Test Suite 'CLIProxyAPIUpdateUITests' failed
```

The failures should mention missing functions such as `cliProxyAPIAvailableUpdatePromptTitle` and old strings such as `Available: 7.2.42` or `Update…`.

- [ ] **Step 3: Replace the update copy helper implementations**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, replace the existing `cliproxyAPIUpdateDescription` and `cliproxyAPIUpdateActionTitle` functions with this complete block:

```swift
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
    case .failed:
        return "Current version: \(currentVersion) · Last check failed."
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
```

- [ ] **Step 4: Run the focused UI tests and verify copy helpers pass**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests
```

Expected result at this stage:

```text
Test Suite 'CLIProxyAPIUpdateUITests' failed
```

The new copy-helper tests should pass. Remaining failures are acceptable if they come from source-placement tests that still expect Server placement or old Dashboard source strings. Those are handled in later tasks.

- [ ] **Step 5: Commit the copy helper change**

Run:

```bash
git add Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git commit -m $'Make CLIProxyAPI update copy version-aware\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
```

Expected result:

```text
[worktree-cliproxyapi-binary-self-update <hash>] Make CLIProxyAPI update copy version-aware
```

---

### Task 2: Move CLIProxyAPI update controls from Server to About

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift:87-109`
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift:51-61`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:50-166,281-344`

**Interfaces:**
- Consumes:
  - Task 1 helpers: `cliproxyAPIUpdateDescription`, `cliproxyAPIUpdateActionTitle`, `cliProxyAPIApplyButtonTitle`.
  - Existing `DashboardViewModel.serverControlState`, `DashboardViewModel.restartServer()`, `DashboardViewModel.settingsMessage`.
  - Existing `CLIProxyAPIUpdateService` methods and published state.
- Produces:
  - `ServerSettingsView(viewModel: DashboardViewModel)` with no CLIProxyAPI update dependency.
  - `AboutSettingsView(viewModel: DashboardViewModel, updaterService: UpdaterService, cliProxyAPIUpdateService: CLIProxyAPIUpdateService)`.

- [ ] **Step 1: Replace source-placement tests**

In `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`, replace `testServerSettingsSourceShowsProgressIndicatorWhileCheckingOrUpdating` with this test:

```swift
    func testCLIProxyAPIUpdateControlsLiveInAboutSettingsInsteadOfServerSettings() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift"), encoding: .utf8)
        let serverRange = source.range(of: "struct ServerSettingsView: View")!..<source.range(of: "struct AdvancedSettingsView: View")!.lowerBound
        let aboutRange = source.range(of: "struct AboutSettingsView: View")!..<source.endIndex
        let serverSource = String(source[serverRange])
        let aboutSource = String(source[aboutRange])

        XCTAssertFalse(serverSource.contains("CLIProxyAPI binary"))
        XCTAssertFalse(serverSource.contains("cliProxyAPIUpdateService"))
        XCTAssertTrue(aboutSource.contains("CLIProxyAPI binary"))
        XCTAssertTrue(aboutSource.contains("cliProxyAPIUpdateService"))
        XCTAssertTrue(aboutSource.contains("ProgressView()"))
        XCTAssertTrue(aboutSource.contains("cliProxyAPIUpdateService.isChecking || cliProxyAPIUpdateService.isUpdating"))
    }
```

- [ ] **Step 2: Run the placement test and verify it fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests/testCLIProxyAPIUpdateControlsLiveInAboutSettingsInsteadOfServerSettings
```

Expected result:

```text
XCTAssertFalse failed
```

The failure should occur because Server still contains `CLIProxyAPI binary` and `cliProxyAPIUpdateService`.

- [ ] **Step 3: Update SettingsView routing**

In `Sources/CLIProxyManagerApp/Views/SettingsView.swift`, replace the switch inside `ScrollView` with this exact block:

```swift
                switch selection {
                case .general:
                    GeneralSettingsView(viewModel: viewModel)
                case .server:
                    ServerSettingsView(viewModel: viewModel)
                case .advanced:
                    AdvancedSettingsView(viewModel: viewModel)
                case .about:
                    AboutSettingsView(
                        viewModel: viewModel,
                        updaterService: updaterService,
                        cliProxyAPIUpdateService: cliProxyAPIUpdateService
                    )
                }
```

- [ ] **Step 4: Simplify ServerSettingsView**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, replace the `ServerSettingsView` declaration header and stored properties:

```swift
struct ServerSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    @State private var showApplyPrompt = false
```

with:

```swift
struct ServerSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
```

Then delete the entire `SettingsRow(label: "CLIProxyAPI binary", ...) { ... }` block from the Server `SettingsGroup(title: "Server")`. Delete the `.confirmationDialog("Apply CLIProxyAPI update now?", ...)` modifier at the end of `ServerSettingsView`. After deletion, the complete `ServerSettingsView` should be:

```swift
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
```

- [ ] **Step 5: Add CLIProxyAPI update controls to AboutSettingsView**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, replace the `AboutSettingsView` header:

```swift
struct AboutSettingsView: View {
    @ObservedObject var updaterService: UpdaterService
    @State private var showLicenses: Bool = false
```

with:

```swift
struct AboutSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    @State private var showLicenses: Bool = false
    @State private var showApplyPrompt = false
```

Inside `SettingsGroup(title: "Updates")`, after the existing CLIProxyManager app `Check now` row, add this row:

```swift
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
                                    }
                                }
                            } else {
                                Task { await cliProxyAPIUpdateService.checkNow() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
```

Add this `.confirmationDialog` modifier after the existing `.sheet(isPresented: $showLicenses) { ... }` modifier in `AboutSettingsView`:

```swift
        .confirmationDialog(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: cliProxyAPIUpdateService.pendingUpdate),
            isPresented: $showApplyPrompt,
            titleVisibility: .visible
        ) {
            Button(cliProxyAPIApplyButtonTitle(
                pendingUpdate: cliProxyAPIUpdateService.pendingUpdate,
                isServerRunning: viewModel.serverControlState.isRunning
            )) {
                Task {
                    do {
                        try cliProxyAPIUpdateService.applyPendingNow()
                        if viewModel.serverControlState.isRunning {
                            await viewModel.restartServer()
                        }
                        viewModel.settingsMessage = "CLIProxyAPI update applied."
                    } catch {
                        viewModel.settingsMessage = "CLIProxyAPI update failed: \(error.localizedDescription)"
                    }
                }
            }
            Button("Apply on next server start") {
                viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cliProxyAPIPendingUpdatePromptMessage(currentVersion: cliProxyAPIUpdateService.currentVersionText))
        }
```

- [ ] **Step 6: Run the focused placement test and verify it passes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests/testCLIProxyAPIUpdateControlsLiveInAboutSettingsInsteadOfServerSettings
```

Expected result:

```text
Test Suite 'Selected tests' passed
```

- [ ] **Step 7: Run the full UI test file**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests
```

Expected result at this stage:

```text
Test Suite 'CLIProxyAPIUpdateUITests' failed
```

The remaining failures should be Dashboard source-copy expectations that are updated in Task 3.

- [ ] **Step 8: Commit the Settings move**

Run:

```bash
git add Sources/CLIProxyManagerApp/Views/SettingsView.swift Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git commit -m $'Move CLIProxyAPI update controls to About\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
```

Expected result:

```text
[worktree-cliproxyapi-binary-self-update <hash>] Move CLIProxyAPI update controls to About
```

---

### Task 3: Update Dashboard automatic prompts to show current and target versions

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift:94-109`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:108-142`

**Interfaces:**
- Consumes:
  - Task 1 helpers: `cliProxyAPIAvailableUpdatePromptTitle`, `cliProxyAPIPendingUpdatePromptTitle`, `cliProxyAPIPendingUpdatePromptMessage`, `cliProxyAPIApplyButtonTitle`, `cliproxyAPIUpdateActionTitle`.
  - Existing `CLIProxyAPIUpdateService.currentVersionText`, `availableUpdate`, `pendingUpdate`, `downloadAvailableUpdate()`, `deferAvailableUpdate()`, `applyPendingNow()`.
  - Existing `DashboardViewModel.serverControlState.isRunning`, `restartServer()`, `settingsMessage`.
- Produces: Dashboard confirmation dialogs that show current version and target version.

- [ ] **Step 1: Replace Dashboard source tests**

In `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`, replace `testDashboardViewCopyClarifiesOnlyServerRestarts` and `testDashboardViewSourceStartsAutomaticCLIProxyAPICheckAndShowsConfirmationDialogs` with these tests:

```swift
    func testDashboardViewCopyUsesVersionAwareCLIProxyAPIUpdatePrompts() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("cliProxyAPIAvailableUpdatePromptTitle(currentVersion:"))
        XCTAssertTrue(source.contains("cliProxyAPIPendingUpdatePromptTitle(pendingUpdate:"))
        XCTAssertTrue(source.contains("cliProxyAPIPendingUpdatePromptMessage(currentVersion:"))
        XCTAssertTrue(source.contains("cliProxyAPIApplyButtonTitle("))
        XCTAssertTrue(source.contains("CLIProxyAPI binary updated. Restarting the app is not required."))
    }

    func testDashboardViewSourceStartsAutomaticCLIProxyAPICheckAndShowsConfirmationDialogs() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("await cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()"))
        XCTAssertTrue(source.contains("showCLIProxyAPIUpdatePrompt"))
        XCTAssertTrue(source.contains("showCLIProxyAPIApplyPrompt"))
        XCTAssertTrue(source.contains("Download"))
        XCTAssertTrue(source.contains("Apply on next server start"))
    }
```

- [ ] **Step 2: Run the Dashboard UI tests and verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests/testDashboardViewCopyUsesVersionAwareCLIProxyAPIUpdatePrompts
```

Expected result:

```text
XCTAssertTrue failed
```

The failure should occur because `DashboardView.swift` still uses inline prompt strings and inline apply button titles.

- [ ] **Step 3: Update the available-update confirmation dialog**

In `Sources/CLIProxyManagerApp/Views/DashboardView.swift`, replace this dialog title:

```swift
            cliProxyAPIUpdateService.availableUpdate.map { "CLIProxyAPI \($0.version.description) is available" } ?? "CLIProxyAPI update available",
```

with:

```swift
            cliProxyAPIAvailableUpdatePromptTitle(
                currentVersion: cliProxyAPIUpdateService.currentVersionText,
                availableUpdate: cliProxyAPIUpdateService.availableUpdate
            ),
```

In the same available-update dialog, replace:

```swift
            Button("Update") {
                Task { await cliProxyAPIUpdateService.downloadAvailableUpdate() }
            }
```

with:

```swift
            Button(cliproxyAPIUpdateActionTitle(
                state: cliProxyAPIUpdateService.state,
                availableUpdate: cliProxyAPIUpdateService.availableUpdate,
                pendingUpdate: nil
            )) {
                Task { await cliProxyAPIUpdateService.downloadAvailableUpdate() }
            }
```

- [ ] **Step 4: Update the pending-apply confirmation dialog**

In `Sources/CLIProxyManagerApp/Views/DashboardView.swift`, replace this pending dialog title:

```swift
            cliProxyAPIUpdateService.pendingUpdate.map { "Apply CLIProxyAPI \($0.version) now?" } ?? "Apply CLIProxyAPI update now?",
```

with:

```swift
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: cliProxyAPIUpdateService.pendingUpdate),
```

Inside that pending dialog, replace this button title:

```swift
            Button(viewModel.serverControlState.isRunning ? "Apply now and restart server" : "Apply now") {
```

with:

```swift
            Button(cliProxyAPIApplyButtonTitle(
                pendingUpdate: cliProxyAPIUpdateService.pendingUpdate,
                isServerRunning: viewModel.serverControlState.isRunning
            )) {
```

After the pending dialog actions block, add this message block before `.sheet(item: $activeSheet)`:

```swift
        } message: {
            Text(cliProxyAPIPendingUpdatePromptMessage(currentVersion: cliProxyAPIUpdateService.currentVersionText))
        }
```

The resulting pending dialog should have this shape:

```swift
        .confirmationDialog(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: cliProxyAPIUpdateService.pendingUpdate),
            isPresented: $showCLIProxyAPIApplyPrompt,
            titleVisibility: .visible
        ) {
            Button(cliProxyAPIApplyButtonTitle(
                pendingUpdate: cliProxyAPIUpdateService.pendingUpdate,
                isServerRunning: viewModel.serverControlState.isRunning
            )) {
                Task {
                    do {
                        try cliProxyAPIUpdateService.applyPendingNow()
                        if viewModel.serverControlState.isRunning {
                            await viewModel.restartServer()
                        }
                        viewModel.settingsMessage = "CLIProxyAPI binary updated. Restarting the app is not required."
                    } catch {
                        viewModel.settingsMessage = "CLIProxyAPI update failed: \(error.localizedDescription)"
                    }
                }
            }
            Button("Apply on next server start") {
                viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cliProxyAPIPendingUpdatePromptMessage(currentVersion: cliProxyAPIUpdateService.currentVersionText))
        }
```

- [ ] **Step 5: Run the focused Dashboard UI tests and verify they pass**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests/testDashboardViewCopyUsesVersionAwareCLIProxyAPIUpdatePrompts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests/testDashboardViewSourceStartsAutomaticCLIProxyAPICheckAndShowsConfirmationDialogs
```

Expected result for each command:

```text
Test Suite 'Selected tests' passed
```

- [ ] **Step 6: Run the full CLIProxyAPI update UI tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyAPIUpdateUITests
```

Expected result:

```text
Test Suite 'CLIProxyAPIUpdateUITests' passed
```

- [ ] **Step 7: Commit the Dashboard prompt change**

Run:

```bash
git add Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git commit -m $'Show CLIProxyAPI update versions in prompts\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
```

Expected result:

```text
[worktree-cliproxyapi-binary-self-update <hash>] Show CLIProxyAPI update versions in prompts
```

---

### Task 4: Integration verification and development-run check

**Files:**
- Read-only verification: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Read-only verification: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
- Read-only verification: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Read-only verification: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`
- Build output only: `/tmp/cliproxy-manager-update-about-ui-build/`

**Interfaces:**
- Consumes all changes from Tasks 1-3.
- Produces evidence that tests pass, the DEBUG app builds, and development runtime remains isolated from production.

- [ ] **Step 1: Run the focused app test suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CLIProxyManagerAppTests
```

Expected result:

```text
Test Suite 'CLIProxyManagerAppTests.xctest' passed
```

If SwiftPM prints a different suite wrapper name, success is still defined by exit code `0` and `0 failures`.

- [ ] **Step 2: Run all Swift tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected result:

```text
Test Suite 'All tests' passed
```

- [ ] **Step 3: Build the DEBUG app product in a clean scratch path**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c debug --product CLIProxyManager --scratch-path /tmp/cliproxy-manager-update-about-ui-build
```

Expected result:

```text
Build of product 'CLIProxyManager' complete!
```

- [ ] **Step 4: Confirm Server no longer owns CLIProxyAPI update controls**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path('Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift').read_text()
server_start = text.index('struct ServerSettingsView: View')
advanced_start = text.index('struct AdvancedSettingsView: View')
about_start = text.index('struct AboutSettingsView: View')
server = text[server_start:advanced_start]
about = text[about_start:]
checks = []
checks.append(('server lacks CLIProxyAPI binary row', 'CLIProxyAPI binary' not in server))
checks.append(('server lacks update service dependency', 'cliProxyAPIUpdateService' not in server))
checks.append(('about has CLIProxyAPI binary row', 'CLIProxyAPI binary' in about))
checks.append(('about has update service dependency', 'cliProxyAPIUpdateService' in about))
failed = [name for name, ok in checks if not ok]
if failed:
    raise SystemExit('failed checks: ' + ', '.join(failed))
for name, _ in checks:
    print('verified:', name)
PY
```

Expected result:

```text
verified: server lacks CLIProxyAPI binary row
verified: server lacks update service dependency
verified: about has CLIProxyAPI binary row
verified: about has update service dependency
```

- [ ] **Step 5: Confirm Dashboard prompt helpers are wired**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path('Sources/CLIProxyManagerApp/Views/DashboardView.swift').read_text()
required = [
    'cliProxyAPIAvailableUpdatePromptTitle(currentVersion:',
    'cliProxyAPIPendingUpdatePromptTitle(pendingUpdate:',
    'cliProxyAPIPendingUpdatePromptMessage(currentVersion:',
    'cliProxyAPIApplyButtonTitle(',
]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit('missing Dashboard helper wiring: ' + ', '.join(missing))
print('Dashboard CLIProxyAPI update prompt helpers verified')
PY
```

Expected result:

```text
Dashboard CLIProxyAPI update prompt helpers verified
```

- [ ] **Step 6: Preserve production while using the development root for manual verification**

Run this read-only production snapshot before opening a development build:

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib
import json
root = Path.home() / '.cliproxy-manager'
clip = root / 'cliproxyapi'
paths = [
    clip / 'cliproxyapi',
    clip / 'config.yaml',
    root / 'config.json',
    root / 'functions.zsh',
    clip / 'active-manifest.json',
    clip / 'update-state.json',
    clip / 'pending',
]
snapshot = {}
for path in paths:
    entry = {'exists': path.exists(), 'is_file': path.is_file(), 'is_dir': path.is_dir()}
    if path.is_file():
        h = hashlib.sha256()
        with path.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        entry['sha256'] = h.hexdigest()
        entry['size'] = path.stat().st_size
    snapshot[str(path)] = entry
out = Path('/tmp/cliproxy-manager-prod-before-update-about-ui.json')
out.write_text(json.dumps(snapshot, indent=2, sort_keys=True))
print(out)
PY
```

Expected result:

```text
/tmp/cliproxy-manager-prod-before-update-about-ui.json
```

Then ensure development config uses port `18318`:

```bash
python3 - <<'PY'
from pathlib import Path
import json
root = Path.home() / '.cliproxy-manager' / 'dev'
root.mkdir(parents=True, exist_ok=True)
config_path = root / 'config.json'
if config_path.exists():
    config = json.loads(config_path.read_text())
else:
    config = {
        'port': 18318,
        'commands': {'cc': '', 'ccapi': '', 'ccodex': ''},
        'ccapi': {'model': 'claude-opus-4-8'},
        'ccodex': {
            'opus': {'model': 'gpt-5.5', 'reasoning': 'xhigh', 'contextWindow': 'auto'},
            'sonnet': {'model': 'gpt-5.5', 'reasoning': 'medium', 'contextWindow': 'auto'},
            'haiku': {'model': 'gpt-5.5', 'reasoning': 'low', 'contextWindow': 'auto'},
        },
        'includeDangerouslySkipPermissions': False,
        'startAtLogin': False,
        'showDockIcon': True,
        'showMenuBarIcon': True,
        'showNotifications': False,
        'appearance': 'system',
        'nicknames': {'cc': '', 'ccodex': ''},
        'accountPrivacy': {'claudeHidden': True, 'codexHidden': True},
        'bindAddress': '127.0.0.1',
        'autostartServer': False,
        'roundRobinEnabled': False,
        'logLevel': 'info',
    }
config['port'] = 18318
config['autostartServer'] = False
config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + '\n')
print(f'{config_path}: port={config["port"]}, autostartServer={config["autostartServer"]}')
PY
```

Expected result:

```text
/Users/<user>/.cliproxy-manager/dev/config.json: port=18318, autostartServer=False
```

- [ ] **Step 7: Report final git status**

Run:

```bash
git status --short
```

Expected result after committing Tasks 1-3 and keeping design/plan files uncommitted only if intentionally deferred:

```text
?? docs/superpowers/plans/2026-07-02-dev-managed-path.md
?? docs/superpowers/plans/2026-07-04-cliproxyapi-update-about-ui.md
?? docs/superpowers/specs/2026-07-04-cliproxyapi-update-about-ui-design.md
```

If the design and plan files were committed as part of the work, only the pre-existing untracked dev-managed-path plan may remain.

---

## Self-Review

### Spec coverage

- Server tab removes CLIProxyAPI update controls: Task 2 Steps 1, 4, 6; Task 4 Step 4.
- About > Updates owns CLIProxyAPI update controls: Task 2 Steps 1, 5, 6; Task 4 Step 4.
- Current and available versions shown together: Task 1 Steps 1, 3, 4.
- Current and pending versions shown together: Task 1 Steps 1, 3, 4.
- Dashboard automatic prompts show current and target versions: Task 1 prompt helpers and Task 3 Dashboard wiring.
- Button titles include target version: Task 1 action/apply button helpers; Task 2 About row; Task 3 Dashboard dialogs.
- Server-running apply button mentions restart: Task 1 `cliProxyAPIApplyButtonTitle`; Task 2 About dialog; Task 3 Dashboard dialog.
- Existing CLIProxyAPI download/verify/apply behavior unchanged: Tasks 2 and 3 reuse existing service calls without changing service/store code.
- Existing Sparkle app update behavior preserved: Task 2 adds CLIProxyAPI row under existing About Updates group without changing `UpdaterService` or Sparkle rows.

### Placeholder scan

Placeholder-marker scan is clean. All new helper function signatures and expected strings are defined before use.

### Type consistency

- `cliProxyAPIUpdateService` remains `CLIProxyAPIUpdateService` everywhere.
- `viewModel` remains `DashboardViewModel` everywhere.
- `pendingUpdate` type is `CLIProxyAPIBinaryManifest?` in helper signatures and callers.
- `availableUpdate` type is `CLIProxyAPIRelease?` in helper signatures and callers.
- `isServerRunning` is derived from `viewModel.serverControlState.isRunning` in both About and Dashboard.
