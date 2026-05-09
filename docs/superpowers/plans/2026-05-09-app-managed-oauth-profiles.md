# App-Managed OAuth Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Claude/Codex OAuth profile state into the bundled CLIProxyAPI area, let the app start OAuth login for both providers, and show connected profile information in the existing settings UI.

**Architecture:** Keep the current Settings/Menu Bar shape and AppConfig structure. The bundled CLIProxyAPI runtime writes its config to the app-managed directory and uses an app-managed auth directory, while the app reads only non-sensitive auth JSON metadata from that directory. Visible provider rows become Claude OAuth and Codex OAuth; Claude API remains installed/backward-compatible in shell functions but is hidden from the default profile list.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation, XCTest, existing CLIProxyManagerCore process runner, bundled CLIProxyAPI binary, local JSON auth files.

---

## Scope Notes

- Do not rely on `~/.cli-proxy-api`; that directory belongs to separately installed upstream CLIProxyAPI and may not exist on distributed installs.
- Use `ManagedPaths.authDirectory`, which resolves under the app-managed root. With the current default root, this is `~/.cliproxy-manager/auth`.
- Do not display or log token fields. Read only `type`, `email`, `account_id`, `expired`, and `disabled` from auth JSON.
- Do not implement full multi-account prefix routing in this milestone.
- Do not enable `force-model-prefix` in this milestone because shell functions still use unprefixed model IDs.
- Keep server start/stop and existing settings pages. Hide Claude API from the default visible profile list; keep the existing `ccmapi` shell function so current users are not broken.

## File Structure

Create:

- `Sources/CLIProxyManagerCore/Auth/AuthProfile.swift`
  - Defines `AuthProfileType` and `AuthProfile` with non-sensitive metadata only.
- `Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift`
  - Reads app-managed auth JSON files from `ManagedPaths.authDirectory`.
- `Sources/CLIProxyManagerCore/Auth/OAuthLoginService.swift`
  - Prepares the bundled runtime and runs `cliproxyapi --config <config> -claude-login` or `-codex-login`.
- `Tests/CLIProxyManagerCoreTests/AuthProfileStoreTests.swift`
  - Tests parsing, filtering, sorting, and token non-exposure behavior.
- `Tests/CLIProxyManagerCoreTests/OAuthLoginServiceTests.swift`
  - Tests runtime preparation and login command invocation.

Modify:

- `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - Add `authDirectory`.
- `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
  - Add reusable runtime preparation and write `auth-dir` to `ManagedPaths.authDirectory`.
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
  - Update config expectations from `~/.cli-proxy-api` to app-managed auth dir.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - Route `ccm` through bundled CLIProxyAPI Claude OAuth instead of local Claude Code login.
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
  - Add/update assertions for Claude OAuth proxy environment.
- `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
  - Remove the default Claude API row identity and add enough metadata for OAuth profile rows.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Inject profile store and OAuth login service; rebuild visible rows from app-managed auth profiles.
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - Cover visible Claude/Codex OAuth rows, profile emails, hidden Claude API, and connect actions.
- `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
  - Use ViewModel connect/disconnect methods; remove Claude API sheet from default row flow.
- `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift`
  - No structural change required, but verify it still shows connected provider/function rows.

---

### Task 1: Move bundled runtime auth-dir into app-managed storage

**Files:**

- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

- [ ] **Step 1: Write failing path test**

In `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`, add this test near the existing config tests:

```swift
func testManagedPathsExposeAppManagedAuthDirectory() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))

    XCTAssertEqual(paths.authDirectory, sandbox.appendingPathComponent("managed/auth", isDirectory: true))
}
```

- [ ] **Step 2: Update existing config expectation to fail for the new auth-dir**

In `testStartWritesCompatibleConfigAndLaunchesBinaryWithConfigPath`, replace:

```swift
XCTAssertTrue(config.contains("auth-dir: \"~/.cli-proxy-api\""))
```

with:

```swift
XCTAssertTrue(config.contains("auth-dir: \"\(paths.authDirectory.path)\""))
XCTAssertFalse(config.contains("~/.cli-proxy-api"))
```

Also add this assertion after the existing directory checks:

```swift
var authIsDirectory: ObjCBool = false
XCTAssertTrue(FileManager.default.fileExists(atPath: paths.authDirectory.path, isDirectory: &authIsDirectory))
XCTAssertTrue(authIsDirectory.boolValue)
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter ProxyServiceManagerTests
```

Expected: FAIL because `ManagedPaths.authDirectory` does not exist and config still writes `~/.cli-proxy-api`.

- [ ] **Step 4: Add authDirectory to ManagedPaths**

In `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`, add this property after `logsDirectory`:

```swift
public var authDirectory: URL {
    rootDirectory.appendingPathComponent("auth", isDirectory: true)
}
```

- [ ] **Step 5: Add reusable runtime preparation to ProxyServiceManager**

In `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`, add this public protocol after `ProcessLaunching`:

```swift
public protocol ProxyRuntimePreparing: Sendable {
    func prepare(port: Int) throws
}
```

Make `ProxyServiceManager` conform:

```swift
public struct ProxyServiceManager: ProxyRuntimePreparing, @unchecked Sendable {
```

Add a public `prepare(port:)` method before `start(port:)`:

```swift
public func prepare(port: Int) throws {
    try lifecycleLock.withLock {
        try prepareLocked(port: port)
    }
}
```

Replace the first `do` block inside `startLocked(port:)`:

```swift
do {
    try installBundledBinaryIfNeeded()
    try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
} catch let error as ProxyServiceError {
    throw error
} catch {
    throw ProxyServiceError.writeFailed(error.localizedDescription)
}
```

with:

```swift
try prepareLocked(port: port)
```

Add this private method above `startLocked(port:)`:

```swift
private func prepareLocked(port: Int) throws {
    guard isValidPort(port) else {
        throw ProxyServiceError.invalidPort(port)
    }

    do {
        try installBundledBinaryIfNeeded()
        try fileManager.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
        try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
    } catch let error as ProxyServiceError {
        throw error
    } catch {
        throw ProxyServiceError.writeFailed(error.localizedDescription)
    }
}
```

Update `config(for:)` to use the app-managed auth directory:

```swift
private func config(for port: Int) -> String {
    """
    port: \(port)
    auth-dir: \(yamlDoubleQuoted(paths.authDirectory.path))
    logging-to-file: true
    debug: false
    api-keys:
      - sk-dummy
    """
}

private func yamlDoubleQuoted(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
```

- [ ] **Step 6: Run tests to verify pass**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter ProxyServiceManagerTests
```

Expected: PASS. The generated config contains `auth-dir: "<managed-root>/auth"` and no `~/.cli-proxy-api`.

- [ ] **Step 7: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "fix: use app-managed auth directory for bundled proxy"
```

---

### Task 2: Add non-sensitive auth profile reader

**Files:**

- Create: `Sources/CLIProxyManagerCore/Auth/AuthProfile.swift`
- Create: `Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift`
- Create: `Tests/CLIProxyManagerCoreTests/AuthProfileStoreTests.swift`

- [ ] **Step 1: Write failing auth profile store tests**

Create `Tests/CLIProxyManagerCoreTests/AuthProfileStoreTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class AuthProfileStoreTests: XCTestCase {
    func testProfilesReadClaudeAndCodexMetadataWithoutTokens() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","email":"claude@example.com","expired":"2026-05-09T11:24:01+09:00","access_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("claude.json"))
        try Data(#"{"type":"codex","email":"codex@example.com","account_id":"acct_123","disabled":false,"refresh_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("codex.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)
        let profiles = try store.profiles()

        XCTAssertEqual(profiles, [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
    }

    func testProfilesIgnoreUnsupportedTypesAndInvalidJson() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"gemini","email":"gemini@example.com"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("gemini.json"))
        try Data("not json".utf8)
            .write(to: authDirectory.appendingPathComponent("broken.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)

        XCTAssertEqual(try store.profiles(), [])
    }

    func testProfileReturnsFirstEnabledProfileForType() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","email":"disabled@example.com","disabled":true}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("a-disabled.json"))
        try Data(#"{"type":"codex","email":"enabled@example.com","disabled":false}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("b-enabled.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)

        XCTAssertEqual(try store.profile(type: .codex)?.email, "enabled@example.com")
    }

    func testMissingDirectoryReturnsEmptyProfiles() throws {
        let sandbox = try makeSandbox()
        let store = AuthProfileStore(authDirectory: sandbox.appendingPathComponent("missing", isDirectory: true))

        XCTAssertEqual(try store.profiles(), [])
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

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter AuthProfileStoreTests
```

Expected: FAIL because `AuthProfileStore`, `AuthProfile`, and `AuthProfileType` do not exist.

- [ ] **Step 3: Create AuthProfile.swift**

Create `Sources/CLIProxyManagerCore/Auth/AuthProfile.swift`:

```swift
import Foundation

public enum AuthProfileType: String, Codable, Equatable, Sendable {
    case claude
    case codex
}

public struct AuthProfile: Equatable, Identifiable, Sendable {
    public var id: String { fileName }

    public let fileName: String
    public let type: AuthProfileType
    public let email: String?
    public let accountID: String?
    public let expired: String?
    public let disabled: Bool

    public init(
        fileName: String,
        type: AuthProfileType,
        email: String?,
        accountID: String?,
        expired: String?,
        disabled: Bool
    ) {
        self.fileName = fileName
        self.type = type
        self.email = email
        self.accountID = accountID
        self.expired = expired
        self.disabled = disabled
    }
}
```

- [ ] **Step 4: Create AuthProfileStore.swift**

Create `Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift`:

```swift
import Foundation

public struct AuthProfileStore: Sendable {
    private let authDirectory: URL
    private let fileManager: FileManager

    public init(authDirectory: URL, fileManager: FileManager = .default) {
        self.authDirectory = authDirectory
        self.fileManager = fileManager
    }

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.init(authDirectory: paths.authDirectory, fileManager: fileManager)
    }

    public func profiles() throws -> [AuthProfile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap(loadProfile)
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    public func profile(type: AuthProfileType) throws -> AuthProfile? {
        try profiles().first { $0.type == type && $0.disabled == false }
    }

    private func loadProfile(from fileURL: URL) -> AuthProfile? {
        guard let data = try? Data(contentsOf: fileURL),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data),
              let type = authFile.type.flatMap(AuthProfileType.init(rawValue:)) else {
            return nil
        }

        return AuthProfile(
            fileName: fileURL.lastPathComponent,
            type: type,
            email: trimmed(authFile.email),
            accountID: trimmed(authFile.accountID),
            expired: trimmed(authFile.expired),
            disabled: authFile.disabled ?? false
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private struct AuthFile: Decodable {
    let type: String?
    let email: String?
    let accountID: String?
    let expired: String?
    let disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case accountID = "account_id"
        case expired
        case disabled
    }
}
```

- [ ] **Step 5: Run test to verify pass**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter AuthProfileStoreTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerCore/Auth/AuthProfile.swift Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift Tests/CLIProxyManagerCoreTests/AuthProfileStoreTests.swift
git commit -m "feat: read app-managed oauth profile metadata"
```

---

### Task 3: Add bundled OAuth login service

**Files:**

- Create: `Sources/CLIProxyManagerCore/Auth/OAuthLoginService.swift`
- Create: `Tests/CLIProxyManagerCoreTests/OAuthLoginServiceTests.swift`

- [ ] **Step 1: Write failing OAuth login service tests**

Create `Tests/CLIProxyManagerCoreTests/OAuthLoginServiceTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class OAuthLoginServiceTests: XCTestCase {
    func testClaudeLoginPreparesRuntimeAndRunsClaudeLoginFlag() async throws {
        let runtime = StubRuntimePreparer()
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed"))
        let service = OAuthLoginService(paths: paths, runtimePreparer: runtime, runner: runner)

        try await service.login(provider: .claude, port: 18_317)

        XCTAssertEqual(runtime.ports, [18_317])
        XCTAssertEqual(runner.invocations, [
            StubProcessRunner.Invocation(
                executable: "/tmp/managed/cliproxyapi/cliproxyapi",
                arguments: ["--config", "/tmp/managed/cliproxyapi/config.yaml", "-claude-login"]
            )
        ])
    }

    func testCodexLoginUsesCodexLoginFlag() async throws {
        let runtime = StubRuntimePreparer()
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed"))
        let service = OAuthLoginService(paths: paths, runtimePreparer: runtime, runner: runner)

        try await service.login(provider: .codex, port: 18_317)

        XCTAssertEqual(runner.invocations.first?.arguments, ["--config", "/tmp/managed/cliproxyapi/config.yaml", "-codex-login"])
    }

    func testLoginFailureIncludesProviderAndProcessOutput() async throws {
        let service = OAuthLoginService(
            paths: ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed")),
            runtimePreparer: StubRuntimePreparer(),
            runner: StubProcessRunner(result: ProcessResult(exitCode: 2, stdout: "", stderr: "oauth failed"))
        )

        do {
            try await service.login(provider: .codex, port: 18_317)
            XCTFail("Expected login failure")
        } catch let error as OAuthLoginError {
            XCTAssertEqual(error, .failed(provider: .codex, exitCode: 2, message: "oauth failed"))
        }
    }
}

private final class StubRuntimePreparer: ProxyRuntimePreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var _ports: [Int] = []

    var ports: [Int] { lock.withLock { _ports } }

    func prepare(port: Int) throws {
        lock.withLock { _ports.append(port) }
    }
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let result: ProcessResult
    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] { lock.withLock { _invocations } }

    init(result: ProcessResult) {
        self.result = result
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        return result
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter OAuthLoginServiceTests
```

Expected: FAIL because `OAuthLoginService`, `OAuthLoginProvider`, and `OAuthLoginError` do not exist.

- [ ] **Step 3: Create OAuthLoginService.swift**

Create `Sources/CLIProxyManagerCore/Auth/OAuthLoginService.swift`:

```swift
import Foundation

public enum OAuthLoginProvider: Equatable, Sendable {
    case claude
    case codex

    var loginFlag: String {
        switch self {
        case .claude:
            "-claude-login"
        case .codex:
            "-codex-login"
        }
    }

    var displayName: String {
        switch self {
        case .claude:
            "Claude OAuth"
        case .codex:
            "Codex OAuth"
        }
    }
}

public enum OAuthLoginError: Error, Equatable {
    case failed(provider: OAuthLoginProvider, exitCode: Int32, message: String)
}

public struct OAuthLoginService: Sendable {
    private let paths: ManagedPaths
    private let runtimePreparer: any ProxyRuntimePreparing
    private let runner: any ProcessRunning

    public init(
        paths: ManagedPaths = ManagedPaths(),
        runtimePreparer: any ProxyRuntimePreparing,
        runner: any ProcessRunning = ProcessRunner(timeout: 300)
    ) {
        self.paths = paths
        self.runtimePreparer = runtimePreparer
        self.runner = runner
    }

    public func login(provider: OAuthLoginProvider, port: Int) async throws {
        try runtimePreparer.prepare(port: port)

        let result = await runner.run(
            paths.clipProxyBinary.path,
            ["--config", paths.clipProxyConfigFile.path, provider.loginFlag]
        )

        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OAuthLoginError.failed(provider: provider, exitCode: result.exitCode, message: message)
        }
    }
}
```

- [ ] **Step 4: Run test to verify pass**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter OAuthLoginServiceTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerCore/Auth/OAuthLoginService.swift Tests/CLIProxyManagerCoreTests/OAuthLoginServiceTests.swift
git commit -m "feat: launch bundled oauth login flows"
```

---

### Task 4: Show Claude/Codex OAuth profiles in ViewModel

**Files:**

- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel tests**

In `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`, add these tests inside `DashboardViewModelRefreshTests`:

```swift
func testDefaultProviderRowsShowOnlyClaudeAndCodexOAuthProfiles() {
    let viewModel = DashboardViewModel(
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.providerRows.map(\.id), [.claude, .codex])
    XCTAssertEqual(viewModel.providerRows.map(\.name), ["Claude OAuth", "Codex OAuth"])
    XCTAssertFalse(viewModel.providerRows.contains { $0.name == "Claude API" })
}

func testProviderRowsShowOAuthProfileEmailsFromAppManagedAuthStore() {
    let profiles = [
        AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
        AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
    ]
    let viewModel = DashboardViewModel(
        authProfileStore: StubAuthProfileStore(profiles: profiles),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionTitle, "연결됨")
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionDetail, "claude@example.com")
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionTitle, "연결됨")
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
}

func testConnectProviderStartsBundledOAuthLoginAndRefreshesProfiles() async {
    let authStore = StubAuthProfileStore(profiles: [])
    authStore.nextProfiles = [
        AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
    ]
    let oauth = StubOAuthLoginService()
    let viewModel = DashboardViewModel(
        authProfileStore: authStore,
        oauthLoginService: oauth,
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    await viewModel.connectProvider(.codex)

    XCTAssertEqual(oauth.invocations, [.codex])
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
    XCTAssertFalse(viewModel.isProfileLoginInProgress)
}
```

Add these test doubles near the existing stubs at the bottom of the file:

```swift
private final class StubAuthProfileStore: AuthProfileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _profiles: [AuthProfile]
    var nextProfiles: [AuthProfile]?

    init(profiles: [AuthProfile]) {
        self._profiles = profiles
    }

    func profiles() throws -> [AuthProfile] {
        lock.withLock {
            if let nextProfiles {
                _profiles = nextProfiles
                self.nextProfiles = nil
            }
            return _profiles
        }
    }
}

private final class StubOAuthLoginService: OAuthLoginStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [OAuthLoginProvider] = []
    var error: Error?

    var invocations: [OAuthLoginProvider] { lock.withLock { _invocations } }

    func login(provider: OAuthLoginProvider, port: Int) async throws {
        lock.withLock { _invocations.append(provider) }
        if let error { throw error }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter DashboardViewModelRefreshTests
```

Expected: FAIL because `AuthProfileReading`, `OAuthLoginStarting`, `isProfileLoginInProgress`, and `connectProvider` do not exist, and provider rows still include Claude API.

- [ ] **Step 3: Update ProviderRowState**

In `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`, keep the existing shape but remove the default Claude API identity:

```swift
struct ProviderRowState: Identifiable, Equatable {
    enum ID: String {
        case claude
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

- [ ] **Step 4: Add profile and OAuth protocols to DashboardViewModel**

In `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`, add after `ProxyModelListing`:

```swift
protocol AuthProfileReading: Sendable {
    func profiles() throws -> [AuthProfile]
}

extension AuthProfileStore: AuthProfileReading {}

protocol OAuthLoginStarting: Sendable {
    func login(provider: OAuthLoginProvider, port: Int) async throws
}

extension OAuthLoginService: OAuthLoginStarting {}
```

Add these published/private properties to `DashboardViewModel`:

```swift
@Published var isProfileLoginInProgress = false

private let authProfileStore: any AuthProfileReading
private let oauthLoginService: any OAuthLoginStarting
private var authProfiles: [AuthProfile] = []
private var lastClaudeStatus: DiagnosticStatus?
private var lastCodexStatus: DiagnosticStatus?
```

Update the initializer signature to accept the new dependencies:

```swift
authProfileStore: any AuthProfileReading = AuthProfileStore(),
oauthLoginService: (any OAuthLoginStarting)? = nil,
```

Set them in the initializer after `self.modelClient = modelClient`:

```swift
self.authProfileStore = authProfileStore
let defaultRuntimePreparer = ProxyServiceManager(paths: ManagedPaths(), bundledBinaryURL: BundledProxyBinary.url())
self.oauthLoginService = oauthLoginService ?? OAuthLoginService(runtimePreparer: defaultRuntimePreparer)
```

Before the initial `rebuildProviderRows` call, load profiles:

```swift
self.authProfiles = (try? authProfileStore.profiles()) ?? []
```

- [ ] **Step 5: Add profile refresh and connect actions**

Add these methods before `addProvider()`:

```swift
func refreshProfiles() {
    authProfiles = (try? authProfileStore.profiles()) ?? []
    rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
}

func connectProvider(_ provider: ProviderRowState.ID) async {
    guard isProfileLoginInProgress == false else { return }
    isProfileLoginInProgress = true
    defer { isProfileLoginInProgress = false }

    let loginProvider: OAuthLoginProvider
    switch provider {
    case .claude:
        loginProvider = .claude
    case .codex:
        loginProvider = .codex
    }

    do {
        try await oauthLoginService.login(provider: loginProvider, port: config.port)
        refreshProfiles()
        settingsMessage = "\(loginProvider.displayName) 연결 정보를 업데이트했습니다."
    } catch {
        settingsMessage = "\(loginProvider.displayName) 로그인에 실패했습니다: \(error.localizedDescription)"
        refreshProfiles()
    }
}

func disconnectProvider(_ provider: ProviderRowState.ID) {
    switch provider {
    case .claude:
        settingsMessage = "Claude OAuth 연결 해제는 이번 단계에서 auth 파일을 직접 삭제하지 않습니다."
    case .codex:
        settingsMessage = "Codex OAuth 연결 해제는 이번 단계에서 auth 파일을 직접 삭제하지 않습니다."
    }
}
```

Update `addProvider()` to make the hidden Claude API behavior explicit:

```swift
func addProvider() {
    settingsMessage = "Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다."
}
```

- [ ] **Step 6: Rebuild rows from auth profiles**

Replace `rebuildProviderRows(claudeStatus:codexStatus:)` with:

```swift
private func rebuildProviderRows(claudeStatus: DiagnosticStatus?, codexStatus: DiagnosticStatus?) {
    let claudeProfile = authProfiles.first { $0.type == .claude && $0.disabled == false }
    let codexProfile = authProfiles.first { $0.type == .codex && $0.disabled == false }

    providerRows = [
        ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            functionName: config.commands.cc,
            connectionTitle: claudeProfile == nil ? "연결 필요" : "연결됨",
            connectionDetail: profileDetail(
                profile: claudeProfile,
                fallback: claudeStatus?.message ?? "번들 CLIProxyAPI의 Claude OAuth profile을 연결하세요."
            ),
            isConnected: claudeProfile != nil
        ),
        ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            functionName: config.commands.ccodex,
            connectionTitle: codexProfile == nil ? "연결 필요" : "연결됨",
            connectionDetail: profileDetail(
                profile: codexProfile,
                fallback: codexStatus?.message ?? "번들 CLIProxyAPI의 Codex OAuth profile을 연결하세요."
            ),
            isConnected: codexProfile != nil
        )
    ]
}

private func profileDetail(profile: AuthProfile?, fallback: String) -> String {
    if let email = profile?.email {
        return email
    }
    if let accountID = profile?.accountID {
        return accountID
    }
    return fallback
}
```

Update `updateStatuses(serverStatus:claudeStatus:)` to store the latest statuses:

```swift
private func updateStatuses(serverStatus updatedServerStatus: DiagnosticStatus, claudeStatus: DiagnosticStatus?) {
    serverStatus = updatedServerStatus
    lastCodexStatus = updatedServerStatus
    if let claudeStatus {
        lastClaudeStatus = claudeStatus
    }
    refreshProfiles()

    cards = cards.map { card in
        switch card.command {
        case config.commands.cc:
            if let claudeStatus {
                card.updatingStatus(claudeStatus)
            } else {
                card
            }
        case config.commands.ccodex:
            card.updatingStatus(updatedServerStatus)
        default:
            card
        }
    }
}
```

- [ ] **Step 7: Run tests to verify pass**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter DashboardViewModelRefreshTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerApp/Models/ProviderRowState.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: show app-managed oauth profile rows"
```

---

### Task 5: Wire provider UI actions to OAuth login

**Files:**

- Modify: `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write a failing UI-facing behavior test in ViewModel tests**

In `DashboardViewModelRefreshTests`, add:

```swift
func testAddProviderExplainsClaudeAPIIsHiddenFromDefaultProfiles() {
    let viewModel = DashboardViewModel(
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector()
    )

    viewModel.addProvider()

    XCTAssertEqual(viewModel.settingsMessage, "Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다.")
}
```

- [ ] **Step 2: Run test to verify failure if message is not updated**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter DashboardViewModelRefreshTests/testAddProviderExplainsClaudeAPIIsHiddenFromDefaultProfiles
```

Expected: PASS if Task 4 already updated `addProvider`; otherwise FAIL with the old message.

- [ ] **Step 3: Update ProviderListView connect/disconnect handlers**

In `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`, replace the `connect(_:)` method with:

```swift
private func connect(_ provider: ProviderRowState.ID) {
    Task { await viewModel.connectProvider(provider) }
}
```

Replace the `disconnect(_:)` method with:

```swift
private func disconnect(_ provider: ProviderRowState.ID) {
    viewModel.disconnectProvider(provider)
}
```

Replace `providerSettingsSheet(_:)` with only Claude and Codex cases:

```swift
@ViewBuilder
private func providerSettingsSheet(_ provider: ProviderRowState.ID) -> some View {
    switch provider {
    case .claude:
        ShellFunctionsSettingsSheet(commands: viewModel.config.commands) { commands in
            try viewModel.saveClaudeFunctionName(commands.cc)
        }
    case .codex:
        CodexProviderSettingsSheet(
            config: viewModel.config,
            availableModels: viewModel.availableCodexModels,
            refreshModels: { Task { await viewModel.loadCodexModels() } },
            save: { functionName, codex in try viewModel.saveCodexSettings(functionName: functionName, codex: codex) }
        )
    }
}
```

- [ ] **Step 4: Build to catch SwiftUI switch exhaustiveness errors**

Run:

```bash
swift build --package-path "${REPO_ROOT:-.}" --product CLIProxyManager
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerApp/Views/ProviderListView.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: connect provider rows to oauth login"
```

---

### Task 6: Route the Claude OAuth shell function through bundled CLIProxyAPI

**Files:**

- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

- [ ] **Step 1: Write failing shell renderer test**

In `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`, add:

```swift
func testClaudeOAuthFunctionUsesBundledProxyAndClaudeModelDefaults() throws {
    let script = try ShellFunctionRenderer(
        config: .default,
        helperCommand: "/usr/local/bin/cliproxy-manager"
    ).render()

    XCTAssertTrue(script.contains("ccm() {"))
    XCTAssertTrue(script.contains("ANTHROPIC_BASE_URL=\"http://127.0.0.1:18317\""))
    XCTAssertTrue(script.contains("ANTHROPIC_AUTH_TOKEN='sk-dummy'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-6'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5-20251001'"))
}
```

Update `testRenderPassesArgumentsThroughToClaude` if needed so it still expects three `claude "$@"` occurrences:

```swift
XCTAssertEqual(script.components(separatedBy: "claude \"$@\"").count - 1, 3)
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter ShellFunctionRendererTests/testClaudeOAuthFunctionUsesBundledProxyAndClaudeModelDefaults
```

Expected: FAIL because `ccm()` still calls local `claude "$@"` without proxy environment.

- [ ] **Step 3: Update ShellFunctionRenderer**

In `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`, add constants after the existing Codex model variables:

```swift
let claudeOpusModel = "claude-opus-4-7"
let claudeSonnetModel = "claude-sonnet-4-6"
let claudeHaikuModel = "claude-haiku-4-5-20251001"
```

Replace the current Claude function block:

```swift
\(config.commands.cc)() {
  \(claudeCommand)
}
```

with:

```swift
\(config.commands.cc)() {
  if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:\(port)/v1/models" >/dev/null; then
    echo "CLIProxyAPI Manager가 실행 중이 아니거나 Claude OAuth profile이 연결되지 않았습니다. 앱을 열어 상태를 확인해 주세요."
    return 1
  fi

  ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)" \\
  ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
  ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellSingleQuoted(claudeOpusModel)) \\
  ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellSingleQuoted(claudeSonnetModel)) \\
  ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellSingleQuoted(claudeHaikuModel)) \\
  \(claudeCommand)
}
```

- [ ] **Step 4: Run shell renderer tests**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}" --filter ShellFunctionRendererTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "feat: route claude oauth function through proxy"
```

---

### Task 7: Final verification and manual app check

**Files:**

- No new files.
- Verify all modified files from Tasks 1-6.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test --package-path "${REPO_ROOT:-.}"
```

Expected: PASS.

- [ ] **Step 2: Build app**

Run:

```bash
swift build --package-path "${REPO_ROOT:-.}" --product CLIProxyManager
```

Expected: PASS.

- [ ] **Step 3: Launch app**

Run:

```bash
"${REPO_ROOT:-.}/.build/debug/CLIProxyManager"
```

Expected: Settings window appears and menu bar item remains available.

- [ ] **Step 4: Verify generated bundled config**

After starting the server from the app, inspect:

```bash
python3 - <<'PY'
from pathlib import Path
print(Path.home().joinpath('.cliproxy-manager/cliproxyapi/config.yaml').read_text())
PY
```

Expected output contains:

```yaml
port: 18317
auth-dir: "/Users/<current-user>/.cliproxy-manager/auth"
logging-to-file: true
debug: false
api-keys:
  - sk-dummy
```

Expected output does not contain:

```text
~/.cli-proxy-api
```

- [ ] **Step 5: Verify UI before login**

Manual checks:

- Providers tab shows exactly `Claude OAuth` and `Codex OAuth` rows.
- Claude API is not shown as a default row.
- `+` button displays `Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다.`
- Both rows show `연결 필요` when no app-managed auth JSON exists.
- Server start/stop control still works.
- General/settings UI remains visible.

- [ ] **Step 6: Verify OAuth login flow**

Manual checks:

- Click `Connect` on `Claude OAuth`.
- Browser OAuth opens through bundled CLIProxyAPI.
- Complete login.
- App shows the email from `~/.cliproxy-manager/auth/*.json` on the Claude OAuth row.
- Click `Connect` on `Codex OAuth`.
- Browser OAuth opens through bundled CLIProxyAPI.
- Complete login.
- App shows the email from `~/.cliproxy-manager/auth/*.json` on the Codex OAuth row.

- [ ] **Step 7: Verify shell functions**

Run:

```bash
zsh -ic 'source ~/.cliproxy-manager/functions.zsh; whence -f ccm; whence -f ccmcodex'
```

Expected:

- `ccm` includes `ANTHROPIC_BASE_URL="http://127.0.0.1:18317"`.
- `ccm` includes Claude model defaults.
- `ccmcodex` includes Codex model defaults.
- Neither function depends on `~/.cli-proxy-api`.

- [ ] **Step 8: Check git status**

Run:

```bash
git -C "${REPO_ROOT:-.}" status --short
```

Expected: Only intended source, test, and plan files are modified.

- [ ] **Step 9: Commit**

Run only if commits are authorized for this task:

```bash
git add Sources Tests docs/superpowers/plans/2026-05-09-app-managed-oauth-profiles.md
git commit -m "feat: add app-managed oauth profiles"
```

---

## Self-Review

- Spec coverage: The plan moves auth state to app-managed bundled CLIProxyAPI storage, supports Claude/Codex OAuth login, shows connected profile info, hides Claude API from default rows, preserves server controls, and keeps existing settings pages.
- Placeholder scan: No TBD/TODO placeholders remain. The hidden Claude API path has a concrete UI message for this milestone.
- Type consistency: `AuthProfileType`, `AuthProfile`, `AuthProfileStore`, `OAuthLoginProvider`, `OAuthLoginService`, `AuthProfileReading`, and `OAuthLoginStarting` are introduced before use. Provider row IDs are `.claude` and `.codex` throughout the plan.
