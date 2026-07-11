# cpm 설치와 사용량 출력 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 Settings에서 `/usr/local/bin/cpm`을 명시적으로 설치·갱신·삭제하고, `cpm quota` 텍스트 출력을 앱의 계정 표시 규칙에 맞춘다.

**Architecture:** App target의 작은 `CPMInstallationService`가 현재 앱 번들의 `cpm`과 `/usr/local/bin/cpm` digest를 비교하고, 설치 성공 후 기록한 digest가 일치하는 파일만 갱신·삭제한다. 시스템 권한 작업은 버튼을 눌렀을 때만 `osascript`의 macOS administrator prompt로 고정된 install/remove 명령을 실행한다. `cpm quota --json`과 메뉴바는 건드리지 않고, Core command의 기본 텍스트 formatter만 config와 auth profile에서 표시명을 계산한다.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation, CryptoKit, XCTest, macOS `osascript` administrator authorization.

## Global Constraints

- 공식 외부 CLI는 `/usr/local/bin/cpm` 하나다.
- `cliproxy-manager`, shell function, 메뉴바 구독 사용량 UI, `cpm quota --json`은 변경하지 않는다.
- 앱 시작·Sparkle 업데이트만으로 CLI를 자동 변경하거나 권한 prompt를 띄우지 않는다.
- Install/Update/Remove 버튼을 누를 때만 macOS administrator prompt를 요청한다.
- 설치 원본은 현재 앱 번들의 `Contents/Helpers/cpm`으로 고정하며, 사용자 입력 경로나 임의 shell command를 허용하지 않는다.
- `cpm quota` 텍스트 출력에는 profile 파일명과 이메일을 표시하지 않는다.
- Codex의 `Primary`/`Secondary` 텍스트 label만 각각 `5h`/`7d`로 정규화한다.
- 개발 앱 런타임 검증은 development build를 기준으로 한다.

---

### Task 1: 앱 전용 cpm 설치 상태와 권한 작업 서비스

**Files:**
- Create: `Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:10-25`
- Test: `Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift`

**Interfaces:**
- Consumes: `ManagedPaths.rootDirectory`, current app bundle `Contents/Helpers/cpm`, `/usr/local/bin/cpm`.
- Produces: `CPMInstallationStatus`, `CPMInstallationManaging`, `CPMInstallationService` for `DashboardViewModel`.

- [ ] **Step 1: Write failing state and ownership tests**

Create `Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift` with a temporary source executable, temporary target, and `ManagedPaths(rootDirectory:)`. Inject `PrivilegedCPMCommandRunning` test doubles so the test never invokes macOS authorization.

```swift
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class CPMInstallationServiceTests: XCTestCase {
    func testStatusIsNotInstalledWhenTargetAndRecordAreAbsent() throws {
        let fixture = try Fixture()
        let service = fixture.makeService()

        XCTAssertEqual(service.status(), .notInstalled)
    }

    func testInstallRecordsDigestAndReportsCurrent() async throws {
        let fixture = try Fixture()
        let runner = CopyingPrivilegedRunner()
        let service = fixture.makeService(runner: runner)

        try await service.installOrUpdate()

        XCTAssertEqual(runner.actions, [.install])
        XCTAssertEqual(service.status(), .installedCurrent(version: "0.1.13"))
        XCTAssertEqual(try Data(contentsOf: fixture.target), Data(contentsOf: fixture.source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.cpmInstallationRecordFile.path))
    }

    func testChangedBundledHelperReportsOutdatedWhenInstalledDigestStillMatchesRecord() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner())
        try await service.installOrUpdate()
        try Data("new cpm".utf8).write(to: fixture.source)

        XCTAssertEqual(service.status(), .installedOutdated(installedVersion: "0.1.13", availableVersion: "0.1.14"))
    }

    func testUpdateAndRemoveRejectTargetWhoseDigestDoesNotMatchRecordedInstall() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner())
        try await service.installOrUpdate()
        try Data("other tool".utf8).write(to: fixture.target)

        XCTAssertEqual(service.status(), .unmanaged)
        await XCTAssertThrowsErrorAsync(try await service.installOrUpdate()) { error in
            XCTAssertEqual(error as? CPMInstallationError, .unmanagedTarget)
        }
        await XCTAssertThrowsErrorAsync(try await service.remove()) { error in
            XCTAssertEqual(error as? CPMInstallationError, .unmanagedTarget)
        }
    }

    func testRemoveDeletesOnlyRecordedInstallAndRecord() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner())
        try await service.installOrUpdate()

        try await service.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cpmInstallationRecordFile.path))
        XCTAssertEqual(service.status(), .notInstalled)
    }
}
```

Implement `Fixture` with `source`, `target`, `paths`, and a `makeService(runner:)` factory. `CopyingPrivilegedRunner` must copy `source` to `target` for `.install` and remove `target` for `.remove`.

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
swift test --filter CPMInstallationServiceTests
```

Expected: compilation failure because `CPMInstallationService`, `CPMInstallationStatus`, `CPMInstallationManaging`, `PrivilegedCPMCommandRunning`, and `ManagedPaths.cpmInstallationRecordFile` do not exist.

- [ ] **Step 3: Add the record path and the minimal service API**

Add this property below `subscriptionUsageManagementKeyFile` in `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`:

```swift
public var cpmInstallationRecordFile: URL {
    rootDirectory.appendingPathComponent("cpm-installation.json")
}
```

Create `Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift` with these public types:

```swift
import CLIProxyManagerCore
import CryptoKit
import Foundation

enum CPMInstallationStatus: Equatable {
    case notInstalled
    case installedCurrent(version: String)
    case installedOutdated(installedVersion: String, availableVersion: String)
    case unmanaged
}

enum CPMInstallationAction: String, Sendable {
    case install
    case remove
}

enum CPMInstallationError: Error, Equatable, LocalizedError {
    case bundledHelperMissing
    case unmanagedTarget
    case authorizationCancelled
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing: "The bundled cpm helper is unavailable."
        case .unmanagedTarget: "The existing /usr/local/bin/cpm was not installed by CLIProxyManager."
        case .authorizationCancelled: "cpm installation was cancelled."
        case .operationFailed: "cpm installation failed."
        }
    }
}

protocol CPMInstallationManaging: Sendable {
    func status() -> CPMInstallationStatus
    func installOrUpdate() async throws
    func remove() async throws
}

protocol PrivilegedCPMCommandRunning: Sendable {
    func run(action: CPMInstallationAction, source: URL?) throws
}
```

Store an internal Codable record containing `digest` and `version`. `status()` must:

1. Return `.notInstalled` when the target does not exist and no action is required.
2. Return `.unmanaged` when the target exists but the record is absent or its SHA-256 differs from the target.
3. Return `.installedCurrent(version:)` when target, record digest, and current bundle source digest all match.
4. Return `.installedOutdated(installedVersion:availableVersion:)` when the target matches the recorded digest but source digest differs.

`installOrUpdate()` must reject `.unmanaged`, require an executable bundled source, call the runner with `.install`, verify the target digest equals the source digest, then atomically write the new record under `paths.rootDirectory` using `Data.write(options: .atomic)`.

`remove()` must require a recorded target whose digest matches, call `.remove`, verify target absence, then remove the record.

Use this exact digest helper:

```swift
private func digest(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
```

- [ ] **Step 4: Add the macOS administrator runner and wire the default service**

In the same service file, implement `AppleScriptPrivilegedCPMCommandRunner`. It must invoke `/usr/bin/osascript` with an AppleScript `on run argv` handler and arguments `[action.rawValue, source?.path ?? ""]`.

Use this exact AppleScript body so both the action and destination remain fixed:

```applescript
on run argv
    set actionName to item 1 of argv
    set sourcePath to item 2 of argv
    if actionName is "install" then
        set quotedSource to quoted form of sourcePath
        do shell script "/bin/rm -f /usr/local/bin/.cpm-install && /usr/bin/install -m 755 " & quotedSource & " /usr/local/bin/.cpm-install && /bin/mv -f /usr/local/bin/.cpm-install /usr/local/bin/cpm" with administrator privileges
    else if actionName is "remove" then
        do shell script "/bin/rm -f /usr/local/bin/cpm" with administrator privileges
    else
        error "Unsupported cpm installation action"
    end if
end run
```

Map a non-zero `osascript` termination status containing `User canceled` or `-128` to `.authorizationCancelled`; map all other failures to `.operationFailed`. Do not pass a user-provided command, target, or destination into this script.

Implement `CPMInstallationService`’s default initializer using:

```swift
init(
    bundle: Bundle = .main,
    paths: ManagedPaths = ManagedPaths(),
    runner: any PrivilegedCPMCommandRunning = AppleScriptPrivilegedCPMCommandRunner(),
    fileManager: FileManager = .default
)
```

Resolve the source as `bundle.bundleURL.appendingPathComponent("Contents/Helpers/cpm")`, target as `URL(fileURLWithPath: "/usr/local/bin/cpm")`, and source version from `CFBundleShortVersionString`, defaulting to `"Unknown"` only for UI display.

- [ ] **Step 5: Run service tests to verify they pass**

Run:

```bash
swift test --filter CPMInstallationServiceTests
```

Expected: all state, install, mismatch rejection, and remove tests pass without opening a system authorization prompt.

- [ ] **Step 6: Commit the service**

```bash
git add Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift \
  Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift
git commit -m "feat: manage cpm installation from app" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 2: Settings action and installation status UI

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:128-224, 1156-1159`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:4-48`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: `CPMInstallationManaging.status()`, `installOrUpdate()`, and `remove()` from Task 1.
- Produces: ViewModel state and actions consumed only by `GeneralSettingsView`.

- [ ] **Step 1: Write failing ViewModel tests using an injected installation double**

Add these tests to `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`:

```swift
func testInstallOrUpdateCPMRefreshesStatusAfterSuccessfulInstall() async {
    let cpm = CPMInstallationDouble(status: .notInstalled, statusAfterInstall: .installedCurrent(version: "0.1.13"))
    let viewModel = makeViewModel(cpmInstallationService: cpm)

    await viewModel.installOrUpdateCPM()

    XCTAssertEqual(cpm.actions, [.install])
    XCTAssertEqual(viewModel.cpmInstallationStatus, .installedCurrent(version: "0.1.13"))
    XCTAssertEqual(viewModel.settingsMessage, "cpm installed.")
}

func testRemoveCPMDoesNotStartSecondActionWhileFirstIsInProgress() async {
    let cpm = BlockingCPMInstallationDouble()
    let viewModel = makeViewModel(cpmInstallationService: cpm)

    async let install: Void = viewModel.installOrUpdateCPM()
    await cpm.waitUntilStarted()
    await viewModel.removeCPM()
    cpm.finish()
    await install

    XCTAssertEqual(cpm.actions, [.install])
}

func testInstallOrUpdateCPMShowsSafeErrorAndKeepsRefreshedStatus() async {
    let cpm = CPMInstallationDouble(status: .unmanaged, installError: .unmanagedTarget)
    let viewModel = makeViewModel(cpmInstallationService: cpm)

    await viewModel.installOrUpdateCPM()

    XCTAssertEqual(viewModel.cpmInstallationStatus, .unmanaged)
    XCTAssertEqual(viewModel.settingsMessage, "The existing /usr/local/bin/cpm was not installed by CLIProxyManager.")
}
```

Define `CPMInstallationDouble` and `BlockingCPMInstallationDouble` at the bottom of the test file. The blocking double must conform to `CPMInstallationManaging` and suspend `installOrUpdate()` with a continuation until `finish()` is called.

- [ ] **Step 2: Run the focused ViewModel tests to verify they fail**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallOrUpdateCPM
```

Expected: compilation failure because the ViewModel has no `cpmInstallationService`, `cpmInstallationStatus`, `installOrUpdateCPM()`, or `removeCPM()`.

- [ ] **Step 3: Add ViewModel state and actions**

In `DashboardViewModel`, add these stored properties alongside other `@Published` state:

```swift
@Published private(set) var cpmInstallationStatus: CPMInstallationStatus
@Published private(set) var isCPMInstallationActionInProgress = false
private let cpmInstallationService: any CPMInstallationManaging
```

Add the optional dependency to the initializer:

```swift
cpmInstallationService: (any CPMInstallationManaging)? = nil,
```

Initialize it before loading config:

```swift
let resolvedCPMInstallationService = cpmInstallationService ?? CPMInstallationService()
self.cpmInstallationService = resolvedCPMInstallationService
self.cpmInstallationStatus = resolvedCPMInstallationService.status()
```

Add these methods near `installShellFunctions`:

```swift
func refreshCPMInstallationStatus() {
    cpmInstallationStatus = cpmInstallationService.status()
}

func installOrUpdateCPM() async {
    guard !isCPMInstallationActionInProgress else { return }
    isCPMInstallationActionInProgress = true
    defer { isCPMInstallationActionInProgress = false }
    do {
        try await cpmInstallationService.installOrUpdate()
        refreshCPMInstallationStatus()
        settingsMessage = "cpm installed."
    } catch {
        refreshCPMInstallationStatus()
        settingsMessage = error.localizedDescription
    }
}

func removeCPM() async {
    guard !isCPMInstallationActionInProgress else { return }
    isCPMInstallationActionInProgress = true
    defer { isCPMInstallationActionInProgress = false }
    do {
        try await cpmInstallationService.remove()
        refreshCPMInstallationStatus()
        settingsMessage = "cpm removed."
    } catch {
        refreshCPMInstallationStatus()
        settingsMessage = error.localizedDescription
    }
}
```

Do not modify automatic shell installation or the default helper resolution code.

- [ ] **Step 4: Add the Command Line Settings row**

In `GeneralSettingsView`, add `@State private var confirmRemoveCPM = false` and append this `SettingsGroup` after the Behavior group:

```swift
SettingsGroup(title: "Command Line") {
    SettingsRow(label: "cpm", description: cpmDescription) {
        if viewModel.isCPMInstallationActionInProgress {
            ProgressView()
                .controlSize(.small)
        } else {
            switch viewModel.cpmInstallationStatus {
            case .notInstalled:
                Button("Install cpm") { Task { await viewModel.installOrUpdateCPM() } }
            case .installedCurrent:
                HStack(spacing: 8) {
                    Button("Update cpm") { Task { await viewModel.installOrUpdateCPM() } }
                    Button("Remove cpm…", role: .destructive) { confirmRemoveCPM = true }
                }
            case .installedOutdated:
                HStack(spacing: 8) {
                    Button("Update cpm") { Task { await viewModel.installOrUpdateCPM() } }
                    Button("Remove cpm…", role: .destructive) { confirmRemoveCPM = true }
                }
            case .unmanaged:
                EmptyView()
            }
        }
    }
}
.confirmationDialog(
    "Remove cpm?",
    isPresented: $confirmRemoveCPM,
    titleVisibility: .visible
) {
    Button("Remove cpm", role: .destructive) { Task { await viewModel.removeCPM() } }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This removes only /usr/local/bin/cpm. Your app, accounts, proxy, and shell functions are unchanged.")
}
```

Add `cpmDescription` in the view with these exact cases:

```swift
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
```

Use `.controlSize(.small)` on all buttons in this row to match the existing Settings controls.

- [ ] **Step 5: Run ViewModel and app tests to verify they pass**

Run:

```bash
swift test --filter 'DashboardViewModelTests|CPMInstallationServiceTests'
```

Expected: all new ViewModel action tests and installation service tests pass.

- [ ] **Step 6: Commit the Settings integration**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: add cpm install controls" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 3: cpm quota 계정 중심 텍스트 formatter

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:363-467`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
- Modify: `README.md:99-117,119-121`

**Interfaces:**
- Consumes: `AppConfig.oauthCommandProfiles`, legacy `commands`/`nicknames`, `AuthProfile`, and `AccountSubscriptionUsageState`.
- Produces: changed stdout only for `cpm quota`; `cpm quota --json` remains byte-for-byte structurally unchanged.

- [ ] **Step 1: Write failing quota formatter tests**

Add these tests to `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift` using a saved config, temporary auth files, and an injected quota client that returns a fixed `SubscriptionUsageReport`:

```swift
func testQuotaTextUsesNicknameCommandAndNormalizedCodexWindows() async throws {
    let sandbox = try makeSandbox()
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    config.oauthCommandProfiles = [
        .init(id: "claude-work", provider: .claude, authProfileID: "claude.json", commandName: "cc", nickname: "Work Claude"),
        .init(id: "codex-personal", provider: .codex, authProfileID: "codex.json", commandName: "cdx")
    ]
    let output = OutputDouble(isInteractive: false)
    let command = try makeQuotaCommand(sandbox: sandbox, config: config, output: output, states: [
        "claude.json": .available(.init(profileID: "claude.json", provider: .claude, windows: [
            .init(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil),
            .init(id: "seven_day", label: "7d", usedPercent: 1, resetAt: nil)
        ], fetchedAt: Date(timeIntervalSince1970: 0))),
        "codex.json": .available(.init(profileID: "codex.json", provider: .codex, windows: [
            .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
            .init(id: "secondary", label: "Secondary", usedPercent: 9, resetAt: nil)
        ], fetchedAt: Date(timeIntervalSince1970: 0)))
    ])

    try await command.run(arguments: ["quota"])

    XCTAssertEqual(output.stdout.joined(), """
    Work Claude  $ cc
      5h   ░░░░░░░░░░   0%
      7d   ░░░░░░░░░░   1%

    Codex OAuth  $ cdx
      5h   ██░░░░░░░░  15%
      7d   █░░░░░░░░░   9%

    """)
    XCTAssertFalse(output.stdout.joined().contains("claude.json"))
    XCTAssertFalse(output.stdout.joined().contains("Primary"))
    XCTAssertFalse(output.stdout.joined().contains("Secondary"))
}

func testQuotaJSONKeepsProfileIDAndRawWindowLabels() async throws {
    // Reuse the same fixture, invoke ["quota", "--json"], decode JSON,
    // and assert accounts[1].profileID == "codex.json",
    // windows[0].label == "Primary", windows[1].label == "Secondary".
}
```

Implement the test helper so it creates `claude.json` and `codex.json` in `sandbox/auth`, saves `config` through `AppConfigStore`, and uses a `SubscriptionQuotaFetching` double that returns the supplied report. Supply the existing runtime double for all other injected services.

- [ ] **Step 2: Run the quota formatter test to verify it fails**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests/testQuotaTextUsesNicknameCommandAndNormalizedCodexWindows
```

Expected: failure because current output contains `Claude claude.json` and `Codex codex.json`, and exposes `Primary`/`Secondary`.

- [ ] **Step 3: Implement the minimal text-only formatter**

Keep the `useJSON` branch and `QuotaCLIRecord` unchanged. Replace only the non-JSON `for profile in profiles` branch with a formatter that iterates visible quota accounts.

Add this internal structure and helper methods in `CLIProxyManagerCommand`:

```swift
private struct QuotaTextAccount {
    let profile: AuthProfile
    let title: String
    let commandName: String
}

private func quotaTextAccounts(config: AppConfig, profiles: [AuthProfile]) -> [QuotaTextAccount] {
    if config.oauthCommandProfiles.isEmpty {
        return profiles.compactMap { profile in
            guard !profile.disabled else { return nil }
            let commandName = profile.type == .claude ? config.commands.cc : config.commands.ccodex
            let nickname = profile.type == .claude ? config.nicknames.cc : config.nicknames.ccodex
            guard !commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let providerTitle = profile.type == .claude ? "Claude OAuth" : "Codex OAuth"
            let title = nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? providerTitle : nickname
            return QuotaTextAccount(profile: profile, title: title, commandName: commandName)
        }
    }

    let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    return config.oauthCommandProfiles.compactMap { commandProfile in
        guard commandProfile.isEnabled,
              let profile = profilesByID[commandProfile.authProfileID],
              !profile.disabled else { return nil }
        let commandName = commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandName.isEmpty else { return nil }
        let providerTitle = commandProfile.provider == .claude ? "Claude OAuth" : "Codex OAuth"
        let nickname = commandProfile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = nickname.isEmpty ? providerTitle : nickname
        return QuotaTextAccount(profile: profile, title: title, commandName: commandName)
    }
}

private func quotaWindowLabel(_ window: UsageWindow, provider: AuthProfileType) -> String {
    guard provider == .codex else { return window.label }
    switch window.id {
    case "primary": return "5h"
    case "secondary": return "7d"
    default: return window.label
    }
}

private func quotaProgressBar(usedPercent: Double) -> String {
    let percent = min(max(usedPercent, 0), 100)
    let filled = min(10, max(0, Int((percent / 10).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
}
```

For every account, write the header and state. For `.available`, write one window line and optional reset line per window:

```swift
output.writeStdout("\(account.title)  $ \(account.commandName)\n")
for window in snapshot.windows {
    let percent = Int(min(max(window.usedPercent, 0), 100).rounded())
    output.writeStdout("  \(quotaWindowLabel(window, provider: account.profile.type).padding(toLength: 4, withPad: " ", startingAt: 0)) \(quotaProgressBar(usedPercent: window.usedPercent)) \(String(format: "%3d", percent))%\n")
    if let resetAt = window.resetAt {
        output.writeStdout("       Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))\n")
    }
}
output.writeStdout("\n")
```

Use these state lines when there are no windows:

```swift
case .disabled: output.writeStdout("  Subscription usage is disabled.\n\n")
case .managementKeyNotConfigured: output.writeStdout("  Management key is not configured.\n\n")
case .loading: output.writeStdout("  Checking subscription usage…\n\n")
case .unavailable(let issue): output.writeStdout("  Usage unavailable — \(issue.message)\n\n")
case .available where snapshot.windows.isEmpty: output.writeStdout("  Usage details unavailable\n\n")
```

If no visible account exists, write exactly `No connected accounts\n`.

- [ ] **Step 4: Run quota tests to verify they pass**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: the new text formatter test passes, the JSON compatibility test passes, and existing command tests remain green.

- [ ] **Step 5: Correct the concise README instructions**

In `README.md`, replace the statement that a normal DMG install makes `cpm` available with this note directly below the `cpm --help` example:

```markdown
After installing the app, open **Settings → General → Command Line** and choose **Install cpm**. The app requests macOS administrator authorization only when you install, update, or remove this command. Use **Update cpm** from the same screen after an app update adds CLI commands.
```

Keep the `cpm quota` commands and their security guarantees unchanged.

- [ ] **Step 6: Commit quota output and docs**

```bash
git add Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift \
  README.md
git commit -m "feat: format cpm quota by account" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 4: Development build verification

**Files:**
- Verify only; no source changes expected.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: runtime evidence for installed and bundle-only cpm behavior.

- [ ] **Step 1: Run the focused full regression set**

Run:

```bash
swift test --filter 'CPMInstallationServiceTests|DashboardViewModelTests|CLIProxyManagerCommandTests|AutomaticShellInstallServiceTests'
```

Expected: all selected tests pass.

- [ ] **Step 2: Build a development app bundle**

Run:

```bash
VERIFY_DIR="${CLAUDE_JOB_DIR:-/tmp}/cpm-install-verification"
rm -rf "$VERIFY_DIR"
make bundle CONFIGURATION=debug BUILD_DIR="$VERIFY_DIR"
test -x "$VERIFY_DIR/CLIProxyManager.app/Contents/Helpers/cpm"
```

Expected: build succeeds and the bundled `cpm` is executable.

- [ ] **Step 3: Verify bundle-only cpm quota output without modifying live installation**

Run:

```bash
"$VERIFY_DIR/CLIProxyManager.app/Contents/Helpers/cpm" quota
"$VERIFY_DIR/CLIProxyManager.app/Contents/Helpers/cpm" quota --json
```

Expected: text output contains nickname/provider title, `$ command`, `5h`/`7d`, no profile filenames; JSON continues to contain raw `profileID` and raw window labels.

- [ ] **Step 4: Manually verify Settings Install/Update/Remove flow**

1. Back up any existing `/usr/local/bin/cpm` outside the app flow; do not overwrite an unmanaged file.
2. Launch the development bundle with `open "$VERIFY_DIR/CLIProxyManager.app"`.
3. Open **Settings → General → Command Line**.
4. Confirm `Install cpm` when no managed installation exists.
5. Click `Install cpm`, complete the system authentication prompt, then verify `zsh -ic 'cpm --help; cpm quota'`.
6. Confirm the row changes to `Update cpm` and `Remove cpm…`.
7. Click `Remove cpm…`, confirm the dialog and administrator prompt, then verify `zsh -ic 'whence -w cpm'` reports `none`.

Expected: only `/usr/local/bin/cpm` changes; app bundle, proxy state, generated shell functions, and `/usr/local/bin/cliproxy-manager` are unchanged.

- [ ] **Step 5: Check final diff and commit verification-only fixes if necessary**

Run:

```bash
git status --short
git diff --check
```

Expected: no unintended files and no whitespace errors. If verification exposes a defect, return to the task that owns that behavior; do not make unrelated cleanup changes.
