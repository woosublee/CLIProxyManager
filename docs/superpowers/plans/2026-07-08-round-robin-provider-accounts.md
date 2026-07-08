# Provider Account Round-Robin Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build provider-scoped round-robin commands that choose the next selected account at CLI session start and keep that account fixed for the session.

**Architecture:** Add provider-specific `AppConfig.RoundRobinProfile` settings, a file-locked `RoundRobinStateStore`, a core `RoundRobinSelectionService`, helper CLI support for `routing next <profile-id>`, shell rendering for round-robin commands, and Routing settings UI to enable/configure the feature. The first UI exposes one group per provider, while the config stores an array so more groups can be supported in the future.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest, SwiftUI, Foundation, POSIX `flock` for cross-process file locking on macOS 15+.

## Global Constraints

- The feature must not switch accounts per provider request inside a running Claude Code conversation.
- The selected account must be chosen once before `claude "$@"` starts and then remain fixed for that CLI process.
- Account-specific OAuth commands must continue to work unchanged.
- Round-robin commands must be separate commands with independent command names and independent dangerous-permissions settings.
- Round-robin account membership must be user-selectable.
- Codex model settings must belong to the round-robin command; only the selected account prefix changes between sessions.
- Round-robin selection state must persist across app restarts and terminal restarts.
- State read-select-write must be protected across helper CLI processes with a file lock.
- Invalid settings must fail before launching Claude Code; no silent fallback when state cannot be persisted.
- The existing `roundRobinEnabled` boolean must not enable the new feature by itself.
- Development app verification must use a development build.

---

## File Structure

Create or modify these files:

- Modify `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - Add `AppConfig.RoundRobinProfile`.
  - Add `roundRobinProfiles: [RoundRobinProfile]`.
  - Decode missing profiles as `[]`.
  - Keep `roundRobinEnabled` ignored/forced off for compatibility.

- Modify `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - Add `roundRobinStateFile` under the app-managed root directory.

- Create `Sources/CLIProxyManagerCore/Routing/OAuthModelDefaults.swift`
  - Own shared Claude OAuth default model constants and prefix helpers.
  - Keep `ShellFunctionRenderer` and `RoundRobinSelectionService` consistent.

- Create `Sources/CLIProxyManagerCore/Routing/RoundRobinStateStore.swift`
  - Persist and atomically advance group selection state.
  - Use POSIX file locking across helper processes.

- Create `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
  - Resolve a round-robin profile, filter usable auth profiles, advance state, and emit shell-safe env assignments.

- Create `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
  - Move helper command parsing into a testable core type.
  - Preserve existing `secret get|set|delete` behavior.
  - Add `routing next <round-robin-profile-id>`.

- Modify `Sources/CLIProxyManagerCLI/main.swift`
  - Delegate to `CLIProxyManagerCommand`.

- Modify `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - Render enabled round-robin functions.
  - Include round-robin function names in duplicate validation.
  - Use shared `OAuthModelDefaults`.

- Modify `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
  - Include renderable round-robin command names during shell install.
  - Treat provider as included when it has either fixed OAuth commands or enabled round-robin commands.

- Create `Sources/CLIProxyManagerApp/Models/RoundRobinSettingsState.swift`
  - Define UI-facing availability and settings state for provider round-robin cards.

- Modify `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Reconcile default round-robin profiles from auth profiles.
  - Expose round-robin settings state.
  - Validate and save round-robin settings.
  - Include round-robin names in active shell function validation.

- Create `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift`
  - Render provider round-robin cards, command fields, account checkboxes, Codex model settings, and dangerous-permissions toggle.

- Modify `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - Replace disabled placeholder routing row with `RoundRobinSettingsView`.

- Modify tests:
  - `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
  - `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
  - `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
  - `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- Create tests:
  - `Tests/CLIProxyManagerCoreTests/RoundRobinStateStoreTests.swift`
  - `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
  - `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
  - `Tests/CLIProxyManagerAppTests/RoundRobinSettingsViewTests.swift`

---

### Task 1: Config Model and Managed Paths

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

**Interfaces:**
- Produces: `AppConfig.RoundRobinProfile`
- Produces: `AppConfig.roundRobinProfiles: [AppConfig.RoundRobinProfile]`
- Produces: `ManagedPaths.roundRobinStateFile: URL`
- Consumed by later tasks: `RoundRobinSelectionService`, `ShellFunctionRenderer`, `DashboardViewModel`, `AutomaticShellInstallService`

- [ ] **Step 1: Add failing config decode/encode tests**

Append these tests to `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`:

```swift
func testRoundRobinProfilesDecodeAndEncodeRoundTrip() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
      "ccapi": { "model": "claude-opus-4-8" },
      "ccodex": {
        "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
        "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
        "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true,
      "roundRobinProfiles": [
        {
          "id": "codex-default",
          "provider": "codex",
          "isEnabled": true,
          "commandName": "ccodexrr",
          "nickname": "Codex Pool",
          "includedAuthProfileIDs": ["codex-fast.json", "codex-deep.json"],
          "accountDetailHidden": false,
          "dangerousPermissionsEnabled": true,
          "codex": {
            "opus": { "model": "gpt-5.6", "reasoning": "xhigh", "contextWindow": "1m" },
            "sonnet": { "model": "gpt-5.6", "reasoning": "medium", "contextWindow": "400k" },
            "haiku": { "model": "gpt-5.6-mini", "reasoning": "low", "contextWindow": "200k" }
          }
        }
      ]
    }
    """#.utf8)

    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    let encoded = try JSONEncoder().encode(decoded)
    let roundTripped = try JSONDecoder().decode(AppConfig.self, from: encoded)

    XCTAssertEqual(roundTripped.roundRobinProfiles, decoded.roundRobinProfiles)
    XCTAssertEqual(roundTripped.roundRobinProfiles, [
        AppConfig.RoundRobinProfile(
            id: "codex-default",
            provider: .codex,
            isEnabled: true,
            commandName: "ccodexrr",
            nickname: "Codex Pool",
            includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"],
            accountDetailHidden: false,
            dangerousPermissionsEnabled: true,
            codex: AppConfig.Codex(
                opus: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .xhigh, contextWindow: .context1m),
                sonnet: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
                haiku: AppConfig.CodexRole(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
            )
        )
    ])
}

func testMissingRoundRobinProfilesDecodesToEmptyArray() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
      "ccapi": { "model": "claude-opus-4-8" },
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

    XCTAssertEqual(config.roundRobinProfiles, [])
}

func testRoundRobinProfileDefaultsWhenOptionalFieldsAreMissing() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
      "ccapi": { "model": "claude-opus-4-8" },
      "ccodex": {
        "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
        "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
        "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true,
      "roundRobinProfiles": [
        {
          "id": "claude-default",
          "provider": "claude",
          "isEnabled": true,
          "commandName": "ccrr",
          "includedAuthProfileIDs": ["claude-work.json", "claude-personal.json"]
        }
      ]
    }
    """#.utf8)

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertEqual(config.roundRobinProfiles.first?.nickname, "")
    XCTAssertEqual(config.roundRobinProfiles.first?.accountDetailHidden, true)
    XCTAssertEqual(config.roundRobinProfiles.first?.dangerousPermissionsEnabled, false)
    XCTAssertNil(config.roundRobinProfiles.first?.codex)
}
```

Add this assertion to `testDecodedConfigCannotEnableUnavailableFeatures()`:

```swift
XCTAssertFalse(config.roundRobinEnabled)
XCTAssertEqual(config.roundRobinProfiles, [])
```

Add this assertion to `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift` in `testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured()`:

```swift
XCTAssertEqual(config.roundRobinProfiles, [])
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter AppConfigTests/testRoundRobinProfilesDecodeAndEncodeRoundTrip
swift test --filter AppConfigTests/testMissingRoundRobinProfilesDecodesToEmptyArray
swift test --filter AppConfigTests/testRoundRobinProfileDefaultsWhenOptionalFieldsAreMissing
swift test --filter AppConfigStoreTests/testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured
```

Expected: the first three tests fail to compile because `RoundRobinProfile` and `roundRobinProfiles` do not exist.

- [ ] **Step 3: Add config model implementation**

In `Sources/CLIProxyManagerCore/Config/AppConfig.swift`, insert this struct after `OAuthCommandProfile`:

```swift
public struct RoundRobinProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: AuthProfileType
    public var isEnabled: Bool
    public var commandName: String
    public var nickname: String
    public var includedAuthProfileIDs: [String]
    public var accountDetailHidden: Bool
    public var dangerousPermissionsEnabled: Bool
    public var codex: Codex?

    public init(
        id: String,
        provider: AuthProfileType,
        isEnabled: Bool = false,
        commandName: String = "",
        nickname: String = "",
        includedAuthProfileIDs: [String] = [],
        accountDetailHidden: Bool = true,
        dangerousPermissionsEnabled: Bool = false,
        codex: Codex? = nil
    ) {
        self.id = id
        self.provider = provider
        self.isEnabled = isEnabled
        self.commandName = commandName
        self.nickname = nickname
        self.includedAuthProfileIDs = includedAuthProfileIDs
        self.accountDetailHidden = accountDetailHidden
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        self.codex = codex
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case isEnabled
        case commandName
        case nickname
        case includedAuthProfileIDs
        case accountDetailHidden
        case dangerousPermissionsEnabled
        case codex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.provider = try c.decode(AuthProfileType.self, forKey: .provider)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.commandName = try c.decodeIfPresent(String.self, forKey: .commandName) ?? ""
        self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        self.includedAuthProfileIDs = try c.decodeIfPresent([String].self, forKey: .includedAuthProfileIDs) ?? []
        self.accountDetailHidden = try c.decodeIfPresent(Bool.self, forKey: .accountDetailHidden) ?? true
        self.dangerousPermissionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
        self.codex = try c.decodeIfPresent(Codex.self, forKey: .codex)
    }
}
```

Add the property to `AppConfig`:

```swift
public var roundRobinProfiles: [RoundRobinProfile]
```

Add the init parameter after `oauthCommandProfiles`:

```swift
roundRobinProfiles: [RoundRobinProfile] = [],
```

Assign it in the initializer:

```swift
self.roundRobinProfiles = roundRobinProfiles
```

Add it to `CodingKeys`:

```swift
case roundRobinProfiles
```

Decode it in `init(from:)`:

```swift
self.roundRobinProfiles = try c.decodeIfPresent([RoundRobinProfile].self, forKey: .roundRobinProfiles) ?? []
```

- [ ] **Step 4: Add managed state path**

In `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`, add:

```swift
public var roundRobinStateFile: URL {
    rootDirectory.appendingPathComponent("round-robin-state.json")
}
```

- [ ] **Step 5: Run config tests and verify they pass**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter AppConfigStoreTests
```

Expected: all `AppConfigTests` and `AppConfigStoreTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "feat: add round-robin config model"
```

---

### Task 2: File-Locked Round-Robin State Store

**Files:**
- Create: `Sources/CLIProxyManagerCore/Routing/RoundRobinStateStore.swift`
- Test: `Tests/CLIProxyManagerCoreTests/RoundRobinStateStoreTests.swift`

**Interfaces:**
- Produces: `public protocol RoundRobinStateSelecting`
- Produces: `public struct RoundRobinStateStore`
- Produces: `func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String`
- Consumes from Task 1: `ManagedPaths.roundRobinStateFile`

- [ ] **Step 1: Write failing state store tests**

Create `Tests/CLIProxyManagerCoreTests/RoundRobinStateStoreTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class RoundRobinStateStoreTests: XCTestCase {
    func testNoPreviousStateSelectsFirstCandidateAndPersists() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        let selected = try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"])

        XCTAssertEqual(selected, "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
    }

    func testLastCandidateWrapsToFirstCandidate() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
    }

    func testMissingLastCandidateFallsBackToFirstCandidate() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["c.json", "d.json"]), "c.json")
    }

    func testGroupStatesAreIndependent() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "claude-default", candidates: ["x.json", "y.json"]), "x.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "claude-default", candidates: ["x.json", "y.json"]), "y.json")
    }

    func testEmptyCandidatesThrow() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: [])) { error in
            XCTAssertEqual(error as? RoundRobinStateStoreError, .emptyCandidates("codex-default"))
        }
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter RoundRobinStateStoreTests
```

Expected: compile failure because `RoundRobinStateStore` does not exist.

- [ ] **Step 3: Implement state store**

Create `Sources/CLIProxyManagerCore/Routing/RoundRobinStateStore.swift`:

```swift
import Foundation
#if os(macOS) || os(Linux)
import Glibc
#endif
#if os(macOS)
import Darwin
#endif

public protocol RoundRobinStateSelecting: Sendable {
    func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String
}

public enum RoundRobinStateStoreError: Error, Equatable, LocalizedError {
    case emptyCandidates(String)
    case lockFailed(String)
    case unlockFailed(String)
    case stateReadFailed(String)
    case stateWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCandidates(let groupID):
            "Round-robin group `\(groupID)` has no candidates."
        case .lockFailed(let path):
            "Failed to lock round-robin state file `\(path)`."
        case .unlockFailed(let path):
            "Failed to unlock round-robin state file `\(path)`."
        case .stateReadFailed(let path):
            "Failed to read round-robin state file `\(path)`."
        case .stateWriteFailed(let path):
            "Failed to write round-robin state file `\(path)`."
        }
    }
}

public struct RoundRobinStateStore: RoundRobinStateSelecting, Sendable {
    private struct State: Codable, Equatable {
        var groups: [String: GroupState] = [:]
    }

    private struct GroupState: Codable, Equatable {
        var lastSelectedAuthProfileID: String
    }

    private let stateFile: URL
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.init(stateFile: paths.roundRobinStateFile, fileManager: fileManager)
    }

    public init(stateFile: URL, fileManager: FileManager = .default) {
        self.stateFile = stateFile
        self.fileManager = fileManager
    }

    public func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String {
        guard !candidates.isEmpty else { throw RoundRobinStateStoreError.emptyCandidates(groupID) }
        try fileManager.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try withExclusiveLock {
            var state = try readState()
            let previous = state.groups[groupID]?.lastSelectedAuthProfileID
            let selected = Self.nextCandidate(after: previous, candidates: candidates)
            state.groups[groupID] = GroupState(lastSelectedAuthProfileID: selected)
            try writeState(state)
            return selected
        }
    }

    private static func nextCandidate(after previous: String?, candidates: [String]) -> String {
        guard let previous, let index = candidates.firstIndex(of: previous) else {
            return candidates[0]
        }
        let nextIndex = candidates.index(after: index)
        return nextIndex == candidates.endIndex ? candidates[0] : candidates[nextIndex]
    }

    private func readState() throws -> State {
        guard fileManager.fileExists(atPath: stateFile.path) else { return State() }
        do {
            let data = try Data(contentsOf: stateFile)
            if data.isEmpty { return State() }
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            throw RoundRobinStateStoreError.stateReadFailed(stateFile.path)
        }
    }

    private func writeState(_ state: State) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            throw RoundRobinStateStoreError.stateWriteFailed(stateFile.path)
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockFile = stateFile.appendingPathExtension("lock")
        let fd = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RoundRobinStateStoreError.lockFailed(lockFile.path) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw RoundRobinStateStoreError.lockFailed(lockFile.path) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
```

If Swift reports a duplicate import issue for `Glibc` on macOS, keep only `import Darwin` for this macOS-only package.

- [ ] **Step 4: Run tests and verify they pass**

Run:

```bash
swift test --filter RoundRobinStateStoreTests
```

Expected: all `RoundRobinStateStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Routing/RoundRobinStateStore.swift Tests/CLIProxyManagerCoreTests/RoundRobinStateStoreTests.swift
git commit -m "feat: persist round-robin selection state"
```

---

### Task 3: Round-Robin Selection Service and Model Env Output

**Files:**
- Create: `Sources/CLIProxyManagerCore/Routing/OAuthModelDefaults.swift`
- Create: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`

**Interfaces:**
- Consumes: `AppConfig.RoundRobinProfile`, `RoundRobinStateSelecting`
- Produces: `public struct RoundRobinSelectionService`
- Produces: `public func shellEnvironmentAssignments(profileID:config:authProfiles:) throws -> String`
- Produces: `public enum OAuthModelDefaults`
- Produces: `public enum RoundRobinSelectionError`
- Consumed by later tasks: `CLIProxyManagerCommand`, `ShellFunctionRenderer`

- [ ] **Step 1: Write failing selection service tests**

Create `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class RoundRobinSelectionServiceTests: XCTestCase {
    func testCodexSelectionUsesIncludedOrderAndRoundRobinModelSettings() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", codex: testCodex(model: "gpt-fast"), modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", codex: testCodex(model: "gpt-deep"), modelPrefix: "codex-deep")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"],
                codex: testCodex(model: "gpt-rr")
            )
        ]
        let state = StubRoundRobinStateSelector(selections: ["codex-deep.json"])
        let service = RoundRobinSelectionService(stateSelector: state)

        let output = try service.shellEnvironmentAssignments(
            profileID: "codex-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]
        )

        XCTAssertEqual(state.calls, [RoundRobinStateCall(groupID: "codex-default", candidates: ["codex-fast.json", "codex-deep.json"])])
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-deep/gpt-rr(xhigh)'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='codex-deep/gpt-rr(medium)'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-deep/gpt-rr(low)'"))
        XCTAssertTrue(output.contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-deep.json'"))
    }

    func testClaudeSelectionUsesDefaultClaudeModels() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork", modelPrefix: "claude-work"),
            AppConfig.OAuthCommandProfile(id: "claude-personal", provider: .claude, authProfileID: "claude-personal.json", commandName: "ccpersonal", modelPrefix: "claude-personal")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"])
        ]
        let service = RoundRobinSelectionService(stateSelector: StubRoundRobinStateSelector(selections: ["claude-work.json"]))

        let output = try service.shellEnvironmentAssignments(
            profileID: "claude-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-work"),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-personal")
            ]
        )

        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-7'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-4-6'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5-20251001'"))
    }

    func testDisabledPrefixlessAndProviderMismatchedProfilesAreExcluded() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-good", provider: .codex, authProfileID: "codex-good.json", commandName: "ccgood", modelPrefix: "codex-good"),
            AppConfig.OAuthCommandProfile(id: "codex-disabled", provider: .codex, authProfileID: "codex-disabled.json", commandName: "ccdisabled", modelPrefix: "codex-disabled"),
            AppConfig.OAuthCommandProfile(id: "codex-prefixless", provider: .codex, authProfileID: "codex-prefixless.json", commandName: "ccprefixless", modelPrefix: ""),
            AppConfig.OAuthCommandProfile(id: "claude-wrong", provider: .claude, authProfileID: "claude-wrong.json", commandName: "ccwrong", modelPrefix: "claude-wrong")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-good.json", "codex-disabled.json", "codex-prefixless.json", "claude-wrong.json"]
            )
        ]
        let service = RoundRobinSelectionService(stateSelector: StubRoundRobinStateSelector(selections: []))

        XCTAssertThrowsError(try service.shellEnvironmentAssignments(
            profileID: "codex-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "codex-good.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-good"),
                AuthProfile(fileName: "codex-disabled.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: true, prefix: "codex-disabled"),
                AuthProfile(fileName: "codex-prefixless.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: nil),
                AuthProfile(fileName: "claude-wrong.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-wrong")
            ]
        )) { error in
            XCTAssertEqual(error as? RoundRobinSelectionError, .insufficientCandidates("codex-default", 1))
        }
    }

    private func testCodex(model: String) -> AppConfig.Codex {
        AppConfig.Codex(
            opus: AppConfig.CodexRole(model: model, reasoning: .xhigh, contextWindow: .auto),
            sonnet: AppConfig.CodexRole(model: model, reasoning: .medium, contextWindow: .auto),
            haiku: AppConfig.CodexRole(model: model, reasoning: .low, contextWindow: .auto)
        )
    }
}

private struct RoundRobinStateCall: Equatable {
    let groupID: String
    let candidates: [String]
}

private final class StubRoundRobinStateSelector: RoundRobinStateSelecting, @unchecked Sendable {
    private(set) var calls: [RoundRobinStateCall] = []
    private var selections: [String]

    init(selections: [String]) {
        self.selections = selections
    }

    func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String {
        calls.append(RoundRobinStateCall(groupID: groupID, candidates: candidates))
        return selections.removeFirst()
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter RoundRobinSelectionServiceTests
```

Expected: compile failure because `RoundRobinSelectionService` and `OAuthModelDefaults` do not exist.

- [ ] **Step 3: Add shared model defaults**

Create `Sources/CLIProxyManagerCore/Routing/OAuthModelDefaults.swift`:

```swift
import Foundation

public enum OAuthModelDefaults {
    public static let claudeOpusModel = "claude-opus-4-7"
    public static let claudeSonnetModel = "claude-sonnet-4-6"
    public static let claudeHaikuModel = "claude-haiku-4-5-20251001"

    public static func prefixedModel(_ model: String, prefix: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return model }
        return "\(trimmedPrefix)/\(model)"
    }

    public static func shellSingleQuoted(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 4: Implement selection service**

Create `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`:

```swift
import Foundation

public enum RoundRobinSelectionError: Error, Equatable, LocalizedError {
    case profileNotFound(String)
    case profileDisabled(String)
    case insufficientCandidates(String, Int)
    case selectedProfileUnavailable(String)
    case missingModelPrefix(String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            "Round-robin profile `\(id)` was not found."
        case .profileDisabled(let id):
            "Round-robin profile `\(id)` is disabled."
        case .insufficientCandidates(let id, let count):
            "Round-robin profile `\(id)` requires at least 2 enabled selected accounts, but found \(count)."
        case .selectedProfileUnavailable(let id):
            "Selected round-robin auth profile `\(id)` is unavailable."
        case .missingModelPrefix(let id):
            "Selected round-robin auth profile `\(id)` does not have a routing prefix."
        }
    }
}

public struct RoundRobinSelectionService: Sendable {
    private struct Candidate: Sendable {
        let authProfileID: String
        let modelPrefix: String
    }

    private let stateSelector: any RoundRobinStateSelecting

    public init(stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore()) {
        self.stateSelector = stateSelector
    }

    public func shellEnvironmentAssignments(
        profileID: String,
        config: AppConfig,
        authProfiles: [AuthProfile]
    ) throws -> String {
        guard let profile = config.roundRobinProfiles.first(where: { $0.id == profileID }) else {
            throw RoundRobinSelectionError.profileNotFound(profileID)
        }
        guard profile.isEnabled else {
            throw RoundRobinSelectionError.profileDisabled(profileID)
        }

        let candidates = candidates(for: profile, config: config, authProfiles: authProfiles)
        guard candidates.count >= 2 else {
            throw RoundRobinSelectionError.insufficientCandidates(profile.id, candidates.count)
        }

        let selectedID = try stateSelector.nextSelectedAuthProfileID(
            groupID: profile.id,
            candidates: candidates.map(\.authProfileID)
        )
        guard let selected = candidates.first(where: { $0.authProfileID == selectedID }) else {
            throw RoundRobinSelectionError.selectedProfileUnavailable(selectedID)
        }
        guard !selected.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoundRobinSelectionError.missingModelPrefix(selectedID)
        }

        let models = modelIdentifiers(for: profile, prefix: selected.modelPrefix, fallbackCodex: config.ccodex)
        return [
            shellAssignment(name: "ANTHROPIC_DEFAULT_OPUS_MODEL", value: models.opus),
            shellAssignment(name: "ANTHROPIC_DEFAULT_SONNET_MODEL", value: models.sonnet),
            shellAssignment(name: "ANTHROPIC_DEFAULT_HAIKU_MODEL", value: models.haiku),
            shellAssignment(name: "CLIPROXY_ROUND_ROBIN_PROFILE", value: selected.authProfileID)
        ].joined(separator: "\n")
    }

    private func candidates(
        for profile: AppConfig.RoundRobinProfile,
        config: AppConfig,
        authProfiles: [AuthProfile]
    ) -> [Candidate] {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        let commandProfilesByAuthID = Dictionary(uniqueKeysWithValues: config.oauthCommandProfiles.map { ($0.authProfileID, $0) })

        return profile.includedAuthProfileIDs.compactMap { authProfileID in
            guard let authProfile = authProfilesByID[authProfileID],
                  authProfile.type == profile.provider,
                  authProfile.disabled == false,
                  let commandProfile = commandProfilesByAuthID[authProfileID],
                  commandProfile.provider == profile.provider,
                  commandProfile.isEnabled else {
                return nil
            }
            let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (authProfile.prefix ?? "")
                : commandProfile.modelPrefix
            guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Candidate(authProfileID: authProfileID, modelPrefix: prefix)
        }
    }

    private func modelIdentifiers(
        for profile: AppConfig.RoundRobinProfile,
        prefix: String,
        fallbackCodex: AppConfig.Codex
    ) -> (opus: String, sonnet: String, haiku: String) {
        switch profile.provider {
        case .claude:
            return (
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeOpusModel, prefix: prefix),
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeSonnetModel, prefix: prefix),
                OAuthModelDefaults.prefixedModel(OAuthModelDefaults.claudeHaikuModel, prefix: prefix)
            )
        case .codex:
            let codex = profile.codex ?? fallbackCodex
            return (
                OAuthModelDefaults.prefixedModel(codex.opus.modelIdentifier, prefix: prefix),
                OAuthModelDefaults.prefixedModel(codex.sonnet.modelIdentifier, prefix: prefix),
                OAuthModelDefaults.prefixedModel(codex.haiku.modelIdentifier, prefix: prefix)
            )
        }
    }

    private func shellAssignment(name: String, value: String) -> String {
        "\(name)=\(OAuthModelDefaults.shellSingleQuoted(value))"
    }
}
```

- [ ] **Step 5: Run selection tests and verify they pass**

Run:

```bash
swift test --filter RoundRobinSelectionServiceTests
```

Expected: all `RoundRobinSelectionServiceTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLIProxyManagerCore/Routing/OAuthModelDefaults.swift Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift
git commit -m "feat: select round-robin account models"
```

---

### Task 4: Helper CLI `routing next`

**Files:**
- Create: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify: `Sources/CLIProxyManagerCLI/main.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Consumes: `RoundRobinSelectionService.shellEnvironmentAssignments(profileID:config:authProfiles:)`
- Produces: `public struct CLIProxyManagerCommand`
- Produces: `public enum CLIProxyManagerCommandError`
- Preserves: `cliproxy-manager secret get|set|delete claude-api-key`
- Adds: `cliproxy-manager routing next <round-robin-profile-id>`

- [ ] **Step 1: Write failing command tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyManagerCommandTests: XCTestCase {
    func testSecretGetStillPrintsSecret() throws {
        var output = ""
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "secret-value"]),
            output: { output += $0 + "\n" }
        )

        try command.run(arguments: ["secret", "get", "claude-api-key"])

        XCTAssertEqual(output, "secret-value\n")
    }

    func testRoutingNextPrintsShellAssignments() throws {
        let sandbox = try makeSandbox()
        let configStore = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-a", provider: .codex, authProfileID: "codex-a.json", commandName: "cca", modelPrefix: "codex-a"),
            AppConfig.OAuthCommandProfile(id: "codex-b", provider: .codex, authProfileID: "codex-b.json", commandName: "ccb", modelPrefix: "codex-b")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: true, commandName: "ccodex", includedAuthProfileIDs: ["codex-a.json", "codex-b.json"])
        ]
        try configStore.save(config)
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","prefix":"codex-a","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex-a.json"))
        try Data(#"{"type":"codex","prefix":"codex-b","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex-b.json"))
        var output = ""
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            stateSelector: RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("round-robin-state.json")),
            output: { output += $0 + "\n" }
        )

        try command.run(arguments: ["routing", "next", "codex-default"])

        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-a/gpt-5.5(xhigh)'"))
        XCTAssertTrue(output.contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-a.json'"))
    }

    func testUnknownArgumentsThrowUsage() {
        let command = CLIProxyManagerCommand(secretStore: InMemorySecretStore())

        XCTAssertThrowsError(try command.run(arguments: ["routing"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: compile failure because `CLIProxyManagerCommand` does not exist.

- [ ] **Step 3: Implement testable command runner**

Create `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`:

```swift
import Foundation

public enum CLIProxyManagerCommandError: Error, Equatable, CustomStringConvertible {
    case usage
    case emptySecret(String)

    public var description: String {
        switch self {
        case .usage:
            "Usage: cliproxy-manager secret <get|set|delete> claude-api-key | cliproxy-manager routing next <round-robin-profile-id>"
        case .emptySecret(let key):
            "Secret value cannot be empty: \(key)"
        }
    }
}

public struct CLIProxyManagerCommand: Sendable {
    private let secretStore: any SecretStore
    private let configStore: AppConfigStore
    private let authProfileStore: AuthProfileStore
    private let stateSelector: any RoundRobinStateSelecting
    private let input: @Sendable () -> String
    private let output: @Sendable (String) -> Void

    public init(
        secretStore: any SecretStore = KeychainSecretStore(),
        configStore: AppConfigStore = AppConfigStore(),
        authProfileStore: AuthProfileStore = AuthProfileStore(),
        stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore(),
        input: @escaping @Sendable () -> String = {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        },
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.secretStore = secretStore
        self.configStore = configStore
        self.authProfileStore = authProfileStore
        self.stateSelector = stateSelector
        self.input = input
        self.output = output
    }

    public func run(arguments: [String]) throws {
        if arguments.count == 3, arguments[0] == "secret" {
            try runSecret(arguments: arguments)
            return
        }
        if arguments.count == 3, arguments[0] == "routing", arguments[1] == "next" {
            try runRoutingNext(profileID: arguments[2])
            return
        }
        throw CLIProxyManagerCommandError.usage
    }

    private func runSecret(arguments: [String]) throws {
        guard let key = SecretKey(rawValue: arguments[2]) else {
            throw CLIProxyManagerCommandError.usage
        }
        switch arguments[1] {
        case "get":
            output(try secretStore.get(key))
        case "set":
            let value = input().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw CLIProxyManagerCommandError.emptySecret(key.rawValue)
            }
            try secretStore.set(value, for: key)
        case "delete":
            try secretStore.delete(key)
        default:
            throw CLIProxyManagerCommandError.usage
        }
    }

    private func runRoutingNext(profileID: String) throws {
        let config = try configStore.load()
        let authProfiles = try authProfileStore.profiles()
        let service = RoundRobinSelectionService(stateSelector: stateSelector)
        output(try service.shellEnvironmentAssignments(profileID: profileID, config: config, authProfiles: authProfiles))
    }
}
```

- [ ] **Step 4: Simplify executable main**

Replace `Sources/CLIProxyManagerCLI/main.swift` with:

```swift
import CLIProxyManagerCore
import Foundation

do {
    try CLIProxyManagerCommand().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIProxyManagerCommandError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch let error as SecretStoreError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
```

- [ ] **Step 5: Run command tests and existing secret behavior tests**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
swift test --filter SecretStoreTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Sources/CLIProxyManagerCLI/main.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "feat: add round-robin helper command"
```

---

### Task 5: Shell Function Rendering and Automatic Install

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `AppConfig.RoundRobinProfile`
- Consumes: `OAuthModelDefaults`
- Produces: generated round-robin shell functions that call `cliproxy-manager routing next <profile-id>`
- Updates: active shell install function names include round-robin commands

- [ ] **Step 1: Add failing shell renderer tests**

Append to `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`:

```swift
func testRenderIncludesEnabledRoundRobinFunction() throws {
    var config = configuredCommands()
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
        AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
    ]
    config.roundRobinProfiles = [
        AppConfig.RoundRobinProfile(
            id: "codex-default",
            provider: .codex,
            isEnabled: true,
            commandName: "ccodex",
            includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"],
            dangerousPermissionsEnabled: true,
            codex: AppConfig.default.ccodex
        )
    ]

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cliproxy-manager").render()

    XCTAssertTrue(script.contains("ccfast() {"))
    XCTAssertTrue(script.contains("ccdeep() {"))
    XCTAssertTrue(script.contains("ccodex() {"))
    XCTAssertTrue(script.contains("routing next codex-default"))
    XCTAssertTrue(script.contains("eval \"$routing_env\""))
    XCTAssertTrue(script.contains("claude --dangerously-skip-permissions \"$@\""))
}

func testRenderSkipsDisabledRoundRobinFunction() throws {
    var config = configuredCommands()
    config.roundRobinProfiles = [
        AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: false, commandName: "ccodex")
    ]

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cliproxy-manager").render()

    XCTAssertFalse(script.contains("ccodex() {"))
    XCTAssertFalse(script.contains("routing next codex-default"))
}

func testRoundRobinCommandNameConflictsWithFixedCommandName() throws {
    var config = configuredCommands()
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "same", modelPrefix: "codex-fast")
    ]
    config.roundRobinProfiles = [
        AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: true, commandName: "same", includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"])
    ]

    XCTAssertThrowsError(try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cliproxy-manager").render()) { error in
        XCTAssertEqual(error as? ShellFunctionRendererError, .duplicateFunctionNames(["same"]))
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter ShellFunctionRendererTests/testRenderIncludesEnabledRoundRobinFunction
swift test --filter ShellFunctionRendererTests/testRenderSkipsDisabledRoundRobinFunction
swift test --filter ShellFunctionRendererTests/testRoundRobinCommandNameConflictsWithFixedCommandName
```

Expected: first test fails because no round-robin function is rendered; conflict test fails because round-robin names are not validated.

- [ ] **Step 3: Update renderer to use shared Claude defaults**

In `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`, remove the private default model constants and replace references:

```swift
let claudeOpusModel = OAuthModelDefaults.claudeOpusModel
let claudeSonnetModel = OAuthModelDefaults.claudeSonnetModel
let claudeHaikuModel = OAuthModelDefaults.claudeHaikuModel
```

Replace `prefixedModel` body with:

```swift
OAuthModelDefaults.prefixedModel(model, prefix: prefix)
```

Replace `shellSingleQuoted` body with:

```swift
OAuthModelDefaults.shellSingleQuoted(value)
```

- [ ] **Step 4: Add round-robin rendering**

In `render()`, after OAuth functions are rendered and before Claude API rendering, add:

```swift
for roundRobinProfile in roundRobinProfilesToRender() {
    script += renderRoundRobinFunction(roundRobinProfile)
}
```

Add this method:

```swift
private func renderRoundRobinFunction(_ profile: AppConfig.RoundRobinProfile) -> String {
    let claudeCommand = profile.dangerousPermissionsEnabled
        ? "claude --dangerously-skip-permissions \"$@\""
        : "claude \"$@\""
    let port = config.port
    let commandName = profile.commandName
    let providerName = profile.provider == .codex ? "Codex" : "Claude"

    return """
    \(commandName)() {
      local routing_env
      if ! routing_env="$(\(shellSingleQuoted(helperCommand)) routing next \(shellSingleQuoted(profile.id)))"; then
        echo "Cannot select a \(providerName) account for round-robin. Open CLIProxyManager to check routing settings."
        return 1
      fi

      eval "$routing_env"

      if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:\(port)/v1/models" >/dev/null; then
        echo "CLIProxyAPI Manager is not running or authentication settings are invalid. Open the app to check the status."
        return 1
      fi

      ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)" \\
      ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
      ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL" \\
      ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_DEFAULT_SONNET_MODEL" \\
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_DEFAULT_HAIKU_MODEL" \\
      \(claudeCommand)
    }

    """
}
```

Add this filter method:

```swift
private func roundRobinProfilesToRender() -> [AppConfig.RoundRobinProfile] {
    config.roundRobinProfiles.filter { profile in
        guard profile.isEnabled, hasCommandName(profile.commandName) else { return false }
        switch profile.provider {
        case .claude:
            return enabledFunctions.claudeOAuth
        case .codex:
            return enabledFunctions.codex
        }
    }
}
```

Update `functionNamesToRender()` to append round-robin command names:

```swift
names.append(contentsOf: roundRobinProfilesToRender().map(\.commandName))
```

- [ ] **Step 5: Update automatic shell install**

In `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`, update `shouldIncludeOAuth` to include round-robin profiles:

```swift
let hasFixedCommand = config.oauthCommandProfiles.contains { commandProfile in
    commandProfile.provider == provider
        && commandProfile.isEnabled
        && !commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
let hasRoundRobinCommand = config.roundRobinProfiles.contains { roundRobinProfile in
    roundRobinProfile.provider == provider
        && roundRobinProfile.isEnabled
        && !roundRobinProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
return hasFixedCommand || hasRoundRobinCommand
```

Update `oauthFunctionNames(config:includeClaudeOAuth:includeCodex:)` to append round-robin names:

```swift
var names = config.oauthCommandProfiles.compactMap { commandProfile in
    let included = commandProfile.provider == .claude ? includeClaudeOAuth : includeCodex
    let commandName = commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
    return included && commandProfile.isEnabled && !commandName.isEmpty ? commandName : nil
}
names.append(contentsOf: config.roundRobinProfiles.compactMap { profile in
    let included = profile.provider == .claude ? includeClaudeOAuth : includeCodex
    let commandName = profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
    return included && profile.isEnabled && !commandName.isEmpty ? commandName : nil
})
return names
```

Keep the legacy branch for `oauthCommandProfiles.isEmpty`, but append round-robin names after it so new profiles work with migrated users.

- [ ] **Step 6: Run renderer and shell install tests**

Run:

```bash
swift test --filter ShellFunctionRendererTests
swift test --filter ProviderSettingsViewModelTests/testInitialShellInstallKeepsCodexFunctionWhenClaudeNameConflictsInZshrc
```

Expected: selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "feat: render round-robin shell commands"
```

---

### Task 6: ViewModel Round-Robin Settings State and Save Flow

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/RoundRobinSettingsState.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Test: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `AppConfig.RoundRobinProfile`, `AuthProfile`, `OAuthCommandProfile.modelPrefix`
- Produces: `RoundRobinSettingsState`
- Produces: `RoundRobinAvailability`
- Produces: `DashboardViewModel.roundRobinSettings(for:) -> RoundRobinSettingsState`
- Produces: `DashboardViewModel.roundRobinCommandNameAvailability(profileID:functionName:) async -> CommandNameAvailability`
- Produces: `DashboardViewModel.saveRoundRobinSettings(_ state: RoundRobinSettingsState) throws`

- [ ] **Step 1: Write failing ViewModel tests**

Append to `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`:

```swift
func testRoundRobinSettingsAvailableForTwoEnabledCodexProfiles() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
        AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
    ]
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
            AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
        ]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    let state = viewModel.roundRobinSettings(for: .codex)

    XCTAssertEqual(state.profile.id, "codex-default")
    XCTAssertEqual(state.profile.provider, .codex)
    XCTAssertEqual(state.profile.commandName, "ccodex")
    XCTAssertEqual(state.profile.includedAuthProfileIDs, ["codex-fast.json", "codex-deep.json"])
    XCTAssertEqual(state.availability, .available(count: 2))
}

func testRoundRobinSettingsUnavailableForOneSelectedProfile() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
        AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
    ]
    config.roundRobinProfiles = [
        AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: false, commandName: "ccodex", includedAuthProfileIDs: ["codex-fast.json"])
    ]
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
            AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
        ]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).availability, .insufficientSelectedAccounts(count: 1))
}

func testSaveRoundRobinSettingsPersistsProfileAndKeepsFixedCommands() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
        AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
    ]
    let store = StubConfigStore(config: config)
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
            AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
        ]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector()
    )
    var state = viewModel.roundRobinSettings(for: .codex)
    state.profile.isEnabled = true
    state.profile.commandName = "ccodexrr"
    state.profile.dangerousPermissionsEnabled = true

    try viewModel.saveRoundRobinSettings(state)

    XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles.first?.commandName, "ccodexrr")
    XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles.first?.dangerousPermissionsEnabled, true)
    XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.commandName), ["ccfast", "ccdeep"])
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testRoundRobinSettingsAvailableForTwoEnabledCodexProfiles
swift test --filter ProviderSettingsViewModelTests/testRoundRobinSettingsUnavailableForOneSelectedProfile
swift test --filter ProviderSettingsViewModelTests/testSaveRoundRobinSettingsPersistsProfileAndKeepsFixedCommands
```

Expected: compile failure because `RoundRobinSettingsState` and ViewModel methods do not exist.

- [ ] **Step 3: Add UI-facing state model**

Create `Sources/CLIProxyManagerApp/Models/RoundRobinSettingsState.swift`:

```swift
import CLIProxyManagerCore
import Foundation

enum RoundRobinAvailability: Equatable {
    case available(count: Int)
    case insufficientProviderAccounts(count: Int)
    case insufficientSelectedAccounts(count: Int)
    case missingPrefixes([String])

    var canEnable: Bool {
        if case .available = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .available(let count):
            return "Available — \(count) accounts selected."
        case .insufficientProviderAccounts(let count):
            return "Unavailable — connect at least 2 accounts. Current enabled accounts: \(count)."
        case .insufficientSelectedAccounts(let count):
            return "Select at least 2 accounts to enable round-robin. Current selected accounts: \(count)."
        case .missingPrefixes(let ids):
            return "Some accounts cannot be used because they do not have a routing prefix: \(ids.joined(separator: ", "))."
        }
    }
}

struct RoundRobinAccountOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isEnabled: Bool
    let hasPrefix: Bool
}

struct RoundRobinSettingsState: Equatable {
    var profile: AppConfig.RoundRobinProfile
    var accountOptions: [RoundRobinAccountOption]
    var availability: RoundRobinAvailability
}
```

- [ ] **Step 4: Add ViewModel helpers**

In `DashboardViewModel.swift`, add these public/internal methods near the existing save methods:

```swift
func roundRobinSettings(for providerType: AuthProfileType) -> RoundRobinSettingsState {
    let profile = roundRobinProfile(for: providerType)
    let options = roundRobinAccountOptions(for: providerType)
    let availability = roundRobinAvailability(profile: profile, options: options)
    return RoundRobinSettingsState(profile: profile, accountOptions: options, availability: availability)
}

func roundRobinCommandNameAvailability(profileID: String, functionName: String) async -> CommandNameAvailability {
    let normalizedName = normalizeCommandName(functionName)
    do {
        try ShellCommandNameValidator.validate(normalizedName)
        var updatedConfig = config
        if let index = updatedConfig.roundRobinProfiles.firstIndex(where: { $0.id == profileID }) {
            updatedConfig.roundRobinProfiles[index].commandName = normalizedName
        }
        let activeNames = activeFunctionNames(in: updatedConfig)
        try ShellCommandNameValidator.validate(activeNames)
        try shellInstaller.validateFunctionNames([normalizedName])
        return .available
    } catch {
        return .unavailable(error.localizedDescription)
    }
}

func saveRoundRobinSettings(_ state: RoundRobinSettingsState) throws {
    var updatedConfig = config
    var profile = state.profile
    profile.commandName = normalizeCommandName(profile.commandName)
    let validIDs = Set(roundRobinAccountOptions(for: profile.provider).map(\.id))
    profile.includedAuthProfileIDs = profile.includedAuthProfileIDs.filter { validIDs.contains($0) }
    if profile.isEnabled, !roundRobinAvailability(profile: profile, options: roundRobinAccountOptions(for: profile.provider)).canEnable {
        throw RoundRobinSettingsError.insufficientAccounts
    }
    if let index = updatedConfig.roundRobinProfiles.firstIndex(where: { $0.id == profile.id }) {
        updatedConfig.roundRobinProfiles[index] = profile
    } else {
        updatedConfig.roundRobinProfiles.append(profile)
    }
    try saveConfig(
        updatedConfig,
        validateShellFunctions: true,
        shellProfileValidationNames: profile.isEnabled ? [profile.commandName] : []
    )
}
```

Add the supporting private methods and error:

```swift
enum RoundRobinSettingsError: LocalizedError, Equatable {
    case insufficientAccounts

    var errorDescription: String? {
        switch self {
        case .insufficientAccounts:
            "Select at least 2 enabled accounts to enable round-robin."
        }
    }
}

private func roundRobinProfile(for providerType: AuthProfileType) -> AppConfig.RoundRobinProfile {
    let defaultID = providerType == .codex ? "codex-default" : "claude-default"
    if let existing = config.roundRobinProfiles.first(where: { $0.id == defaultID }) {
        return existing
    }
    return AppConfig.RoundRobinProfile(
        id: defaultID,
        provider: providerType,
        isEnabled: false,
        commandName: providerType == .codex ? "ccodex" : "cc",
        includedAuthProfileIDs: roundRobinAccountOptions(for: providerType).filter { $0.isEnabled && $0.hasPrefix }.map(\.id),
        codex: providerType == .codex ? config.ccodex : nil
    )
}

private func roundRobinAccountOptions(for providerType: AuthProfileType) -> [RoundRobinAccountOption] {
    let commandProfilesByAuthID = Dictionary(uniqueKeysWithValues: config.oauthCommandProfiles.map { ($0.authProfileID, $0) })
    return authProfiles
        .filter { $0.type == providerType }
        .map { profile in
            let commandProfile = commandProfilesByAuthID[profile.id]
            let prefix = commandProfile?.modelPrefix ?? profile.prefix ?? ""
            let title = commandProfile?.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? commandProfile?.nickname ?? profile.id
                : profile.email ?? profile.id
            let detail = profile.disabled ? "Disabled" : "Connected"
            return RoundRobinAccountOption(
                id: profile.id,
                title: title,
                detail: detail,
                isEnabled: !profile.disabled && commandProfile?.isEnabled != false,
                hasPrefix: !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
}

private func roundRobinAvailability(
    profile: AppConfig.RoundRobinProfile,
    options: [RoundRobinAccountOption]
) -> RoundRobinAvailability {
    let enabledOptions = options.filter { $0.isEnabled }
    guard enabledOptions.count >= 2 else {
        return .insufficientProviderAccounts(count: enabledOptions.count)
    }
    let selectedOptions = enabledOptions.filter { profile.includedAuthProfileIDs.contains($0.id) }
    guard selectedOptions.count >= 2 else {
        return .insufficientSelectedAccounts(count: selectedOptions.count)
    }
    let missingPrefixIDs = selectedOptions.filter { !$0.hasPrefix }.map(\.id)
    guard missingPrefixIDs.isEmpty else {
        return .missingPrefixes(missingPrefixIDs)
    }
    return .available(count: selectedOptions.count)
}
```

- [ ] **Step 5: Include round-robin names in validation**

Update `activeFunctionNames(in:)`:

```swift
var names = renderableOAuthCommandProfiles(in: config)
    .map { normalizeCommandName($0.commandName) }
    .filter { !$0.isEmpty }
names.append(contentsOf: renderableRoundRobinProfiles(in: config).map { normalizeCommandName($0.commandName) }.filter { !$0.isEmpty })
return names
```

Add:

```swift
private func renderableRoundRobinProfiles(in config: AppConfig) -> [AppConfig.RoundRobinProfile] {
    config.roundRobinProfiles.filter { profile in
        profile.isEnabled && !profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

Update `enabledShellFunctions(in:)` so provider booleans include round-robin profiles:

```swift
let enabledOAuthProfiles = renderableOAuthCommandProfiles(in: config)
let enabledRoundRobinProfiles = renderableRoundRobinProfiles(in: config)
return AutomaticShellInstallService.EnabledFunctions(
    claudeOAuth: enabledOAuthProfiles.contains { $0.provider == .claude } || enabledRoundRobinProfiles.contains { $0.provider == .claude },
    codex: enabledOAuthProfiles.contains { $0.provider == .codex } || enabledRoundRobinProfiles.contains { $0.provider == .codex },
    claudeAPI: false
)
```

- [ ] **Step 6: Run ViewModel tests**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testRoundRobinSettingsAvailableForTwoEnabledCodexProfiles
swift test --filter ProviderSettingsViewModelTests/testRoundRobinSettingsUnavailableForOneSelectedProfile
swift test --filter ProviderSettingsViewModelTests/testSaveRoundRobinSettingsPersistsProfileAndKeepsFixedCommands
swift test --filter ProviderSettingsViewModelTests/testCommandNameAvailabilityReportsDuplicateActiveProviderNames
```

Expected: selected tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLIProxyManagerApp/Models/RoundRobinSettingsState.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "feat: save round-robin routing settings"
```

---

### Task 7: Routing Settings UI

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Test: `Tests/CLIProxyManagerAppTests/RoundRobinSettingsViewTests.swift`

**Interfaces:**
- Consumes: `DashboardViewModel.roundRobinSettings(for:)`
- Consumes: `DashboardViewModel.roundRobinCommandNameAvailability(profileID:functionName:)`
- Consumes: `DashboardViewModel.saveRoundRobinSettings(_:)`
- Produces: SwiftUI routing settings replacing disabled placeholder row

- [ ] **Step 1: Write failing UI utility tests**

Create `Tests/CLIProxyManagerAppTests/RoundRobinSettingsViewTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class RoundRobinSettingsViewTests: XCTestCase {
    func testRoundRobinProviderTitleUsesProviderName() {
        XCTAssertEqual(roundRobinProviderTitle(.codex), "Codex round-robin")
        XCTAssertEqual(roundRobinProviderTitle(.claude), "Claude round-robin")
    }

    func testRoundRobinModelDescriptionExplainsFixedModelPolicy() {
        XCTAssertEqual(
            roundRobinModelDescription(provider: .codex),
            "These model settings belong to the round-robin command. Only the account prefix changes between sessions."
        )
        XCTAssertEqual(
            roundRobinModelDescription(provider: .claude),
            "Claude OAuth round-robin uses the default Claude OAuth model mappings. Only the account prefix changes between sessions."
        )
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter RoundRobinSettingsViewTests
```

Expected: compile failure because UI helper functions do not exist.

- [ ] **Step 3: Create round-robin settings view**

Create `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift`:

```swift
import CLIProxyManagerCore
import SwiftUI

func roundRobinProviderTitle(_ provider: AuthProfileType) -> String {
    switch provider {
    case .codex:
        return "Codex round-robin"
    case .claude:
        return "Claude round-robin"
    }
}

func roundRobinModelDescription(provider: AuthProfileType) -> String {
    switch provider {
    case .codex:
        return "These model settings belong to the round-robin command. Only the account prefix changes between sessions."
    case .claude:
        return "Claude OAuth round-robin uses the default Claude OAuth model mappings. Only the account prefix changes between sessions."
    }
}

struct RoundRobinSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 12) {
            RoundRobinProviderSettingsCard(viewModel: viewModel, provider: .codex)
            RoundRobinProviderSettingsCard(viewModel: viewModel, provider: .claude)
        }
    }
}

private struct RoundRobinProviderSettingsCard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let provider: AuthProfileType
    @State private var state: RoundRobinSettingsState
    @State private var commandNameCheckState: CommandNameAvailability = .available

    init(viewModel: DashboardViewModel, provider: AuthProfileType) {
        self.viewModel = viewModel
        self.provider = provider
        _state = State(initialValue: viewModel.roundRobinSettings(for: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(roundRobinProviderTitle(provider))
                        .font(.caption.weight(.semibold))
                    Text("Start each new CLI session with the next selected account. The chosen account stays fixed for that session.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.profile.isEnabled },
                    set: { value in state.profile.isEnabled = value }
                ))
                .labelsHidden()
                .toggleStyle(SettingsToggleStyle())
                .disabled(!state.availability.canEnable)
            }

            Text(state.availability.message)
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.availability.canEnable ? BrandPalette.statusRunning : BrandPalette.statusError)

            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("function_name", text: Binding(
                    get: { state.profile.commandName },
                    set: { state.profile.commandName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                if case .unavailable(let message) = commandNameCheckState {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(BrandPalette.statusError)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(state.accountOptions) { option in
                    Toggle(isOn: Binding(
                        get: { state.profile.includedAuthProfileIDs.contains(option.id) },
                        set: { isSelected in
                            if isSelected {
                                if !state.profile.includedAuthProfileIDs.contains(option.id) {
                                    state.profile.includedAuthProfileIDs.append(option.id)
                                }
                            } else {
                                state.profile.includedAuthProfileIDs.removeAll { $0 == option.id }
                            }
                            state = recomputedState(profile: state.profile)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.caption)
                            Text(option.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!option.isEnabled || !option.hasPrefix)
                }
            }

            if provider == .codex {
                Text(roundRobinModelDescription(provider: provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CodexRoundRobinModelFields(profile: $state.profile)
            } else {
                Text(roundRobinModelDescription(provider: provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: Binding(
                get: { state.profile.dangerousPermissionsEnabled },
                set: { state.profile.dangerousPermissionsEnabled = $0 }
            )) {
                Text("Skip permission prompts")
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Save") {
                    viewModel.saveSetting { try viewModel.saveRoundRobinSettings(state) }
                    state = viewModel.roundRobinSettings(for: provider)
                }
                .disabled(state.profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commandNameCheckState != .available)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 10, opacity: 0.04)
        .task(id: state.profile.commandName) {
            await updateCommandAvailability()
        }
    }

    private func recomputedState(profile: AppConfig.RoundRobinProfile) -> RoundRobinSettingsState {
        var next = viewModel.roundRobinSettings(for: provider)
        next.profile = profile
        return RoundRobinSettingsState(
            profile: profile,
            accountOptions: next.accountOptions,
            availability: next.availability
        )
    }

    private func updateCommandAvailability() async {
        guard !state.profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commandNameCheckState = await viewModel.roundRobinCommandNameAvailability(profileID: state.profile.id, functionName: state.profile.commandName)
    }
}

private struct CodexRoundRobinModelFields: View {
    @Binding var profile: AppConfig.RoundRobinProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelTextField(label: "Opus", text: Binding(get: { codex.opus.model }, set: { updateOpusModel($0) }))
            modelTextField(label: "Sonnet", text: Binding(get: { codex.sonnet.model }, set: { updateSonnetModel($0) }))
            modelTextField(label: "Haiku", text: Binding(get: { codex.haiku.model }, set: { updateHaikuModel($0) }))
        }
    }

    private var codex: AppConfig.Codex {
        profile.codex ?? AppConfig.default.ccodex
    }

    private func modelTextField(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption2.weight(.medium))
                .frame(width: 48, alignment: .leading)
            TextField("model", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func updateOpusModel(_ value: String) {
        var updated = codex
        updated.opus.model = value
        profile.codex = updated
    }

    private func updateSonnetModel(_ value: String) {
        var updated = codex
        updated.sonnet.model = value
        profile.codex = updated
    }

    private func updateHaikuModel(_ value: String) {
        var updated = codex
        updated.haiku.model = value
        profile.codex = updated
    }
}
```

- [ ] **Step 4: Replace disabled routing placeholder**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, replace the disabled Routing `SettingsRow` with:

```swift
SettingsGroup(title: "Routing") {
    RoundRobinSettingsView(viewModel: viewModel)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
}
```

- [ ] **Step 5: Run UI tests and build app target**

Run:

```bash
swift test --filter RoundRobinSettingsViewTests
swift build -c debug --product CLIProxyManager
```

Expected: tests pass and debug app product builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift Tests/CLIProxyManagerAppTests/RoundRobinSettingsViewTests.swift
git commit -m "feat: add round-robin routing settings UI"
```

---

### Task 8: Full Regression, Development Verification, and Review

**Files:**
- Modify: any files needed for fixes discovered by the verification pass
- Test: all existing tests

**Interfaces:**
- Consumes: all prior task outputs
- Produces: verified feature branch ready for code review and PR

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Run focused renderer and CLI smoke tests**

Run:

```bash
swift test --filter ShellFunctionRendererTests
swift test --filter CLIProxyManagerCommandTests
swift test --filter RoundRobinSelectionServiceTests
swift test --filter RoundRobinStateStoreTests
```

Expected: all selected tests pass.

- [ ] **Step 3: Build development app and helper**

Run:

```bash
swift build -c debug --product CLIProxyManager
swift build -c debug --product cliproxy-manager
```

Expected: both products build successfully.

- [ ] **Step 4: Exercise helper command with a temporary config root**

Create a temporary root in `$CLAUDE_JOB_DIR/tmp` and run the helper against it if `ManagedPaths` dependency injection is available in the command tests. If the executable cannot point to a custom root, rely on `CLIProxyManagerCommandTests` and skip touching the user's real `~/.cliproxy-manager` data.

Use this test-backed command instead of live account calls:

```bash
swift test --filter CLIProxyManagerCommandTests/testRoutingNextPrintsShellAssignments
```

Expected: test passes and shows the helper produces shell assignments with a selected prefix.

- [ ] **Step 5: Run development app verification**

Run the project verification skill or development run command:

```bash
make CONFIGURATION=debug swift-build
```

Expected: debug build succeeds for `CLIProxyManager` and `cliproxy-manager`.

If you need to visually inspect the Routing settings, use the repo's run workflow or ask the user before installing into `/Applications` or modifying their shell profile. Do not run live provider requests unless the user explicitly approves using connected accounts.

- [ ] **Step 6: Request code review**

Use the code review skill on the current diff:

```bash
/code-review
```

Expected: no confirmed correctness findings. If findings are returned, fix them and rerun relevant tests.

- [ ] **Step 7: Final commit for verification fixes**

If Step 1-6 required fixes, commit them:

```bash
git add <changed-files>
git commit -m "fix: address round-robin verification findings"
```

If no fixes were needed, do not create an empty commit.

- [ ] **Step 8: Final status**

Run:

```bash
git status --short
```

Expected: clean working tree.

---

## Self-Review

### Spec coverage

- Provider-scoped round-robin config: Task 1.
- User-selectable included accounts: Task 6 and Task 7.
- Separate round-robin command: Task 5 and Task 7.
- Session-start selection only: Task 5 shell rendering calls helper before `claude "$@"`; Task 3 emits fixed model env values.
- Model settings fixed on round-robin command: Task 3 and Task 7.
- Persistent selection state: Task 2.
- Cross-process locking: Task 2.
- Helper CLI `routing next`: Task 4.
- Validation and clear failure: Task 3, Task 4, Task 6.
- Tests: Tasks 1-8.
- Development build verification: Task 8.

### Placeholder scan

The plan contains no `TBD`, no `TODO`, no unspecified edge-case instruction, and no step that says only to “write tests” without concrete test code.

### Type consistency

- `AppConfig.RoundRobinProfile` is defined in Task 1 and consumed by Tasks 3, 5, 6, and 7.
- `RoundRobinStateSelecting.nextSelectedAuthProfileID(groupID:candidates:)` is defined in Task 2 and consumed by Task 3.
- `RoundRobinSelectionService.shellEnvironmentAssignments(profileID:config:authProfiles:)` is defined in Task 3 and consumed by Task 4.
- `CLIProxyManagerCommand.run(arguments:)` is defined in Task 4 and consumed by the executable target.
- `RoundRobinSettingsState` is defined in Task 6 and consumed by Task 7.
