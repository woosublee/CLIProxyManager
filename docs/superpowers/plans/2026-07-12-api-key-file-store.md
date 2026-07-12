# API Key 파일 저장 및 설정 보완 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** API Key를 사용자 전용 로컬 파일에 저장하고, Claude/OpenAI API Key 명령이 OAuth와 독립적인 설정·모델 매핑·권한 건너뛰기 동작을 사용하게 한다.

**Architecture:** `SecretStore` 프로토콜의 신규 기본 구현인 `FileSecretStore`가 `ManagedPaths.apiKeysDirectory` 안의 versioned JSON 파일을 안전하게 읽고 쓴다. API Key 전용 설정은 `AppConfig`에 저장하고, `DashboardViewModel`이 SwiftUI 시트와 shell renderer를 연결한다. 프록시는 파일 저장소에서 API Key를 읽어 기존 CLIProxyAPI YAML provider 블록을 생성한다.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Darwin POSIX (`open`, `flock`, `fsync`, `rename`), XCTest, zsh shell functions.

## Global Constraints

- API Key 평문 파일은 `~/.cliproxy-manager/api-keys/`에만 저장하며, DEBUG 빌드는 `~/.cliproxy-manager/dev/api-keys/`를 사용한다.
- API Key 디렉터리는 `0700`; secret·lock·temporary 파일은 현재 사용자 소유의 regular file 및 정확히 `0600`이어야 한다.
- 읽기와 삭제 시 `O_NOFOLLOW`를 사용해 symbolic link를 거부한다.
- 쓰기는 `0600` temporary file → `fsync` → atomic `rename` 순서로 진행하고, `flock` lock file로 직렬화한다.
- macOS Keychain fallback 및 자동 마이그레이션은 구현하지 않는다.
- Claude API Key 화면에는 모델 편집 UI를 노출하지 않는다. Claude 명령은 OAuth의 고정 Opus/Sonnet/Haiku 기본 매핑을 사용한다.
- Claude와 OpenAI API Key의 `Skip permission prompts`는 전역 및 OAuth 설정과 독립적이다.
- OpenAI API Key는 CLIProxyAPI를 통해서만 실행하며 OAuth Codex와 같은 role 모델 매핑을 사용한다.
- 새 사용자 노출 문구와 코드 주석은 기존 프로젝트의 영어 스타일을 따른다.

---

## 파일 구조

- `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`: API Key 디렉터리와 key별 secret file URL을 제공한다.
- `Sources/CLIProxyManagerCore/Secrets/FileSecretStore.swift`: 파일 기반 `SecretStore`의 POSIX 보안·원자적 I/O를 캡슐화한다.
- `Sources/CLIProxyManagerCore/Secrets/SecretStore.swift`: 기존 `SecretKey`/프로토콜은 유지한다.
- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`: API Key 전용 connection, Codex routing, skip-permission 설정을 영속화하고 구버전 config를 decode한다.
- `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`: 기본 secret provider를 `FileSecretStore`로 변경한다.
- `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`: `cpm secret` 기본 secret store를 파일 저장소로 변경한다.
- `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`: 자동 shell 설치의 기본 secret store를 파일 저장소로 변경한다.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`: API Key 저장/삭제 시 독립 설정을 저장하고 기본 secret store를 파일 저장소로 변경한다.
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`: API Key 시트 save callback에 새 독립 설정을 전달한다.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`: Claude API Key 모델 필드를 제거하고, OpenAI API Key에 Codex role·skip UI를 추가한다.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`: API Key별 skip value 및 Claude 기본 model mapping을 shell functions에 렌더한다.
- `Tests/CLIProxyManagerCoreTests/FileSecretStoreTests.swift`: 파일 저장소의 API 및 파일 보안 invariants를 검증한다.
- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`: API Key 설정 decode/encode와 이전 `ccapi.model` config 호환성을 검증한다.
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`: API Key 명령의 모델·skip rendering을 검증한다.
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`: 파일 secret provider로 생성되는 YAML을 검증한다.
- `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`: 기본 `cpm secret`이 `ManagedPaths` 파일 저장소를 사용하는지 검증한다.
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`: API Key별 독립 설정 저장을 검증한다.

### Task 1: 사용자 전용 파일 기반 SecretStore 추가

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:10-32`
- Create: `Sources/CLIProxyManagerCore/Secrets/FileSecretStore.swift`
- Test: `Tests/CLIProxyManagerCoreTests/FileSecretStoreTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:447-473`

**Interfaces:**
- Produces: `public struct FileSecretStore: SecretStore, @unchecked Sendable` with `init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default)`, `get(_:)`, `set(_:for:)`, and `delete(_:)`.
- Produces: `ManagedPaths.apiKeysDirectory: URL` and `ManagedPaths.apiKeyFile(for: SecretKey) -> URL`.
- Consumes: existing `SecretKey` and `SecretStoreError` in `Sources/CLIProxyManagerCore/Secrets/SecretStore.swift`.

- [ ] **Step 1: Add a failing path assertion**

```swift
func testManagedPathsExposeUserPrivateAPIKeyFiles() {
    let root = URL(fileURLWithPath: "/tmp/managed", isDirectory: true)
    let paths = ManagedPaths(rootDirectory: root)

    XCTAssertEqual(paths.apiKeysDirectory, root.appendingPathComponent("api-keys", isDirectory: true))
    XCTAssertEqual(paths.apiKeyFile(for: .claudeAPIKey), root.appendingPathComponent("api-keys/claude-api-key.json"))
    XCTAssertEqual(paths.apiKeyFile(for: .codexAPIKey), root.appendingPathComponent("api-keys/codex-api-key.json"))
}
```

- [ ] **Step 2: Run the focused path test and verify it fails**

Run: `swift test --filter AppConfigTests/testManagedPathsExposeUserPrivateAPIKeyFiles`

Expected: compilation failure because `apiKeysDirectory` and `apiKeyFile(for:)` do not exist.

- [ ] **Step 3: Add managed file paths**

```swift
public var apiKeysDirectory: URL {
    rootDirectory.appendingPathComponent("api-keys", isDirectory: true)
}

public func apiKeyFile(for key: SecretKey) -> URL {
    apiKeysDirectory.appendingPathComponent("\(key.rawValue).json")
}
```

Keep the declarations beside `configFile` and other root-level persistent paths.

- [ ] **Step 4: Add failing round-trip and permission tests**

```swift
func testFileSecretStoreRoundTripsBothAPIKeysWithPrivatePermissions() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = FileSecretStore(paths: paths)

    try store.set("claude-secret", for: .claudeAPIKey)
    try store.set("codex-secret", for: .codexAPIKey)

    XCTAssertEqual(try store.get(.claudeAPIKey), "claude-secret")
    XCTAssertEqual(try store.get(.codexAPIKey), "codex-secret")
    XCTAssertEqual(fileMode(paths.apiKeysDirectory), 0o700)
    XCTAssertEqual(fileMode(paths.apiKeyFile(for: .claudeAPIKey)), 0o600)
    XCTAssertEqual(fileMode(paths.apiKeyFile(for: .codexAPIKey)), 0o600)
}

func testFileSecretStoreRejectsSymlinkAndWrongPermissions() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = FileSecretStore(paths: paths)
    try store.set("secret", for: .claudeAPIKey)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.apiKeyFile(for: .claudeAPIKey).path)

    XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
        XCTAssertEqual(error as? SecretStoreError, .readFailed("claude-api-key"))
    }
}

func testFileSecretStoreDeleteRemovesExistingSecretAndAcceptsMissingSecret() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = FileSecretStore(paths: paths)
    try store.set("secret", for: .claudeAPIKey)

    try store.delete(.claudeAPIKey)
    try store.delete(.claudeAPIKey)

    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.apiKeyFile(for: .claudeAPIKey).path))
}
```

Add `makeSandbox()` with teardown deletion and `fileMode(_:)` using `stat` under `import Darwin`.

- [ ] **Step 5: Run focused file-store tests and verify failure**

Run: `swift test --filter FileSecretStoreTests`

Expected: compilation failure because `FileSecretStore` does not exist.

- [ ] **Step 6: Implement `FileSecretStore` by adapting the subscription management key file protocol**

Create an internal envelope and stable key-to-file mapping:

```swift
import Darwin
import Foundation

public struct FileSecretStore: SecretStore, @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let value: String
    }

    private let paths: ManagedPaths
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func get(_ key: SecretKey) throws -> String {
        try withExclusiveLock(for: key) { try readSecretLocked(for: key) }
    }

    public func set(_ value: String, for key: SecretKey) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SecretStoreError.writeFailed(key.rawValue) }
        try withExclusiveLock(for: key) { try writeSecretLocked(normalized, for: key) }
    }

    public func delete(_ key: SecretKey) throws {
        try withExclusiveLock(for: key) {
            let file = paths.apiKeyFile(for: key)
            guard try validateForDeletion(file, key: key) else { return }
            guard unlink(file.path) == 0 else { throw SecretStoreError.writeFailed(key.rawValue) }
        }
    }
}
```

Implement private helpers that mirror `SubscriptionUsageManagementKeyFileStore` exactly in behavior: create `apiKeysDirectory`, enforce directory `0700`, open secret and lock files with `O_CLOEXEC | O_NOFOLLOW`, validate `S_IFREG`, `st_uid == getuid()`, exact `0o600`, use `flock(LOCK_EX)`, encode `Envelope(version: 1, value: value)` with sorted keys, write to an `O_CREAT | O_EXCL` temporary file with mode `S_IRUSR | S_IWUSR`, call `write` until complete, `fsync`, then `rename`. Map absent secret to `.missingSecret(key.rawValue)`, malformed/unsafe reads to `.readFailed`, and creation/writing/deletion failures to `.writeFailed`.

- [ ] **Step 7: Re-run focused tests and then all secret tests**

Run: `swift test --filter FileSecretStoreTests && swift test --filter SecretStoreTests && swift test --filter AppConfigTests/testManagedPathsExposeUserPrivateAPIKeyFiles`

Expected: all selected tests pass.

- [ ] **Step 8: Commit the storage implementation**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Sources/CLIProxyManagerCore/Secrets/FileSecretStore.swift \
  Tests/CLIProxyManagerCoreTests/FileSecretStoreTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "feat: store API keys in private files"
```

### Task 2: API Key 전용 AppConfig 설정 추가

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:36-114,297-429`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:5-73`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift:1-90`

**Interfaces:**
- Consumes: `AppConfig.Codex` defined in the existing config model.
- Produces: `AppConfig.ClaudeAPI(connectionMode:dangerousPermissionsEnabled:)`.
- Produces: `AppConfig.CodexAPI(codex:dangerousPermissionsEnabled:)` stored as `AppConfig.codexAPI`.
- Legacy JSON containing `ccapi.model` must decode successfully without preserving or emitting an editable Claude API model setting.

- [ ] **Step 1: Write failing AppConfig behavior tests**

```swift
func testClaudeAPISettingsDefaultToDirectAndSafeMode() {
    let config = AppConfig.default
    XCTAssertEqual(config.ccapi.connectionMode, .direct)
    XCTAssertFalse(config.ccapi.dangerousPermissionsEnabled)
}

func testCodexAPISettingsDefaultToCodexDefaultsAndSafeMode() {
    let config = AppConfig.default
    XCTAssertEqual(config.codexAPI.codex, config.ccodex)
    XCTAssertFalse(config.codexAPI.dangerousPermissionsEnabled)
}

func testLegacyClaudeAPIModelDecodesButDoesNotBecomeRuntimeConfiguration() throws {
    let config = try JSONDecoder().decode(AppConfig.self, from: legacyConfigData(
        ccapi: #"{ \"model\": \"claude-sonnet-4-6\" }"#
    ))

    XCTAssertEqual(config.ccapi.connectionMode, .direct)
    XCTAssertFalse(config.ccapi.dangerousPermissionsEnabled)
    XCTAssertFalse(String(data: try JSONEncoder().encode(config), encoding: .utf8)!.contains("claude-sonnet-4-6"))
}
```

Use the existing minimal valid config JSON fixture shape in `AppConfigTests`; add `legacyConfigData(ccapi:)` only if it reduces duplicated JSON.

- [ ] **Step 2: Run AppConfig tests and verify failure**

Run: `swift test --filter AppConfigTests`

Expected: compilation failure because the new API Key setting properties do not exist.

- [ ] **Step 3: Define explicit API Key configuration types with backward-compatible decoding**

Replace the model-based Claude API config with:

```swift
public struct ClaudeAPI: Codable, Equatable, Sendable {
    public var connectionMode: ConnectionMode
    public var dangerousPermissionsEnabled: Bool

    public init(connectionMode: ConnectionMode = .direct, dangerousPermissionsEnabled: Bool = false) {
        self.connectionMode = connectionMode
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case connectionMode, dangerousPermissionsEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .direct
        dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
    }
}

public struct CodexAPI: Codable, Equatable, Sendable {
    public var codex: Codex
    public var dangerousPermissionsEnabled: Bool

    public init(codex: Codex, dangerousPermissionsEnabled: Bool = false) {
        self.codex = codex
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
    }
}
```

Change `AppConfig.codexAPI` from `Codex` to `CodexAPI`. In the root decoder, when `codexAPI` is missing, initialize `CodexAPI(codex: ccodex)` so old configurations retain their existing model mapping. In `.default`, initialize `ccapi: ClaudeAPI()` and `codexAPI: CodexAPI(codex: defaultCodex)`.

Update all initializers and equality assertions that construct `ClaudeAPI(model:)` or expect `codexAPI` to equal `ccodex`.

- [ ] **Step 4: Run config and config store tests**

Run: `swift test --filter AppConfigTests && swift test --filter AppConfigStoreTests`

Expected: all selected tests pass, including JSON decode compatibility.

- [ ] **Step 5: Commit the config model**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "feat: add per-key API command settings"
```

### Task 3: 파일 저장소를 런타임 기본값으로 연결

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:241-310`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:46-115`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift:22-41`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:147-220`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Consumes: `FileSecretStore(paths:)` from Task 1.
- Produces: all production default constructors read from the same `ManagedPaths` file store instead of Keychain.
- Produces: existing `cpm secret get|set|delete` semantics unchanged.

- [ ] **Step 1: Add failing default-store integration tests**

```swift
func testDefaultCLICommandReadsAPIKeyFromManagedFileStore() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox)
    try FileSecretStore(paths: paths).set("file-secret", for: .claudeAPIKey)
    let output = OutputDouble(isInteractive: false)
    let command = CLIProxyManagerCommand(
        configStore: AppConfigStore(paths: paths),
        authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
        output: output
    )

    try await command.run(arguments: ["secret", "get", "claude-api-key"])

    XCTAssertEqual(output.stdout, ["file-secret\\n"])
}

func testProxyConfigurationReadsAPIKeysFromFileStore() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try FileSecretStore(paths: paths).set("codex-file-secret", for: .codexAPIKey)
    let manager = ProxyServiceManager(paths: paths, launcher: FakeProcessLauncher())

    try manager.prepare(port: 8317)

    XCTAssertTrue(try String(contentsOf: paths.clipProxyConfigFile).contains("codex-file-secret"))
}
```

For the CLI test, ensure the config store has a saved `.default` config if the constructor path needs it. Keep injected `InMemorySecretStore` tests unchanged so they remain unit tests.

- [ ] **Step 2: Run focused default-store tests and verify failure**

Run: `swift test --filter CLIProxyManagerCommandTests/testDefaultCLICommandReadsAPIKeyFromManagedFileStore && swift test --filter ProxyServiceManagerTests/testProxyConfigurationReadsAPIKeysFromFileStore`

Expected: failure because defaults instantiate `KeychainSecretStore`.

- [ ] **Step 3: Replace production defaults**

Use each component's already available `paths` argument where available:

```swift
// ProxyServiceManager
claudeAPIKeyProvider: claudeAPIKeyProvider ?? { try? FileSecretStore(paths: paths).get(.claudeAPIKey) }
codexAPIKeyProvider: codexAPIKeyProvider ?? { try? FileSecretStore(paths: paths).get(.codexAPIKey) }

// CLIProxyManagerCommand public and internal initializers
secretStore: any SecretStore = FileSecretStore()

// AutomaticShellInstallService initializer
secretStore: any SecretStore = FileSecretStore()

// DashboardViewModel initializer
secretStore: any SecretStore = FileSecretStore()
```

Do not delete `KeychainSecretStore.swift` in this change; it is unused compatibility code and removing it is unrelated scope.

- [ ] **Step 4: Run focused integrations and existing affected suites**

Run: `swift test --filter CLIProxyManagerCommandTests && swift test --filter ProxyServiceManagerTests && swift test --filter AutomaticShellInstallServiceTests && swift test --filter ProviderSettingsViewModelTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the production store switch**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift \
  Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "feat: use file-backed API key store"
```

### Task 4: API Key 전용 설정 저장과 SwiftUI 시트 완성

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:1129-1192`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:252-282`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift:824-960`
- Test: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift:19-56,390-440`

**Interfaces:**
- Consumes: `AppConfig.ClaudeAPI(connectionMode:dangerousPermissionsEnabled:)` and `AppConfig.CodexAPI(codex:dangerousPermissionsEnabled:)` from Task 2.
- Produces: `saveClaudeAPISettings(functionName:connectionMode:dangerousPermissionsEnabled:key:) throws`.
- Produces: `saveCodexAPISettings(functionName:codex:dangerousPermissionsEnabled:key:) throws`.
- Produces: `ClaudeAPIProviderSettingsSheet.save` and `CodexAPIProviderSettingsSheet.save` closures with these exact parameters.

- [ ] **Step 1: Update ViewModel tests to state independent persistence requirements**

```swift
func testSaveClaudeAPISettingsPersistsConnectionAndItsOwnSkipPermissionSetting() throws {
    let configStore = StubConfigStore(config: .default)
    let secrets = InMemorySecretStore()
    let viewModel = makeViewModel(configStore: configStore, secretStore: secrets)

    try viewModel.saveClaudeAPISettings(
        functionName: "ccapi",
        connectionMode: .proxy,
        dangerousPermissionsEnabled: true,
        key: "secret-value"
    )

    XCTAssertEqual(try secrets.get(.claudeAPIKey), "secret-value")
    XCTAssertEqual(configStore.config.commands.ccapi, "ccapi")
    XCTAssertEqual(configStore.config.ccapi.connectionMode, .proxy)
    XCTAssertTrue(configStore.config.ccapi.dangerousPermissionsEnabled)
    XCTAssertFalse(configStore.config.includeDangerouslySkipPermissions)
}

func testSaveCodexAPISettingsPersistsRoleRoutingAndItsOwnSkipPermissionSetting() throws {
    let configStore = StubConfigStore(config: .default)
    let secrets = InMemorySecretStore()
    let viewModel = makeViewModel(configStore: configStore, secretStore: secrets)
    let routing = AppConfig.Codex(
        opus: .init(model: "gpt-5.6", reasoning: .xhigh, contextWindow: .context1m),
        sonnet: .init(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
        haiku: .init(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
    )

    try viewModel.saveCodexAPISettings(functionName: "ccodexapi", codex: routing, dangerousPermissionsEnabled: true, key: "secret-value")

    XCTAssertEqual(configStore.config.codexAPI.codex, routing)
    XCTAssertTrue(configStore.config.codexAPI.dangerousPermissionsEnabled)
    XCTAssertEqual(try secrets.get(.codexAPIKey), "secret-value")
}
```

- [ ] **Step 2: Run focused ViewModel tests and verify failure**

Run: `swift test --filter ProviderSettingsViewModelTests/testSaveClaudeAPISettingsPersistsConnectionAndItsOwnSkipPermissionSetting && swift test --filter ProviderSettingsViewModelTests/testSaveCodexAPISettingsPersistsRoleRoutingAndItsOwnSkipPermissionSetting`

Expected: compilation failure from obsolete save signatures and missing properties.

- [ ] **Step 3: Store API Key configuration independently in DashboardViewModel**

Use these method bodies after storing any non-nil key:

```swift
func saveClaudeAPISettings(
    functionName: String,
    connectionMode: AppConfig.ConnectionMode,
    dangerousPermissionsEnabled: Bool,
    key: String?
) throws {
    if let key { try saveAPIKey(key, for: .claudeAPIKey) }
    var updatedConfig = config
    updatedConfig.commands.ccapi = normalizeCommandName(functionName)
    updatedConfig.ccapi = .init(
        connectionMode: connectionMode,
        dangerousPermissionsEnabled: dangerousPermissionsEnabled
    )
    try saveConfig(updatedConfig, validateShellFunctions: true, shellProfileValidationNames: [updatedConfig.commands.ccapi])
    if serverControlState.isRunning, connectionMode == .proxy { Task { await restartServer() } }
}

func saveCodexAPISettings(
    functionName: String,
    codex: AppConfig.Codex,
    dangerousPermissionsEnabled: Bool,
    key: String?
) throws {
    if let key { try saveAPIKey(key, for: .codexAPIKey) }
    var updatedConfig = config
    updatedConfig.commands.ccodexapi = normalizeCommandName(functionName)
    updatedConfig.codexAPI = .init(codex: codex, dangerousPermissionsEnabled: dangerousPermissionsEnabled)
    try saveConfig(updatedConfig, validateShellFunctions: true, shellProfileValidationNames: [updatedConfig.commands.ccodexapi])
    if serverControlState.isRunning { Task { await restartServer() } }
}
```

Factor the existing trim-and-empty validation into `private func saveAPIKey(_ value: String, for key: SecretKey) throws` so Claude and Codex use the exact same validation.

- [ ] **Step 4: Replace the API Key sheet state and controls**

For `ClaudeAPIProviderSettingsSheet`:

```swift
@State private var connectionMode: AppConfig.ConnectionMode
@State private var dangerousPermissionsEnabled: Bool
// no @State model
```

Initialize `dangerousPermissionsEnabled` from `config.ccapi.dangerousPermissionsEnabled`. Delete the model text field. After the segmented connection picker add the existing OAuth permission card pattern:

```swift
GroupTitle(text: "Permissions")
GroupCard {
    CardRow(
        label: "Skip permission prompts",
        description: "Adds --dangerously-skip-permissions when launching. Use only for trusted local work.",
        warning: dangerousPermissionsEnabled ? "Claude Code will skip every permission confirmation." : nil,
        isLast: true
    ) {
        Toggle("", isOn: $dangerousPermissionsEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(BrandPalette.accent)
            .controlSize(.small)
    }
}
```

Change its save closure to `(String, AppConfig.ConnectionMode, Bool, String?) throws`.

For `CodexAPIProviderSettingsSheet`, add `@State opus`, `sonnet`, `haiku`, `dangerousPermissionsEnabled`, `scopedAvailableModels`, and `isReloading`; accept the same `availableModels`, `modelLoadingState`, `refreshModels`, and `latestModel` dependencies already used by `CodexProviderSettingsSheet`. Initialize roles from `config.codexAPI.codex`, add the identical Routing section with `CodexRoleRoutingFields`, then add the identical Permissions card. Change its save closure to `(String, AppConfig.Codex, Bool, String?) throws`.

- [ ] **Step 5: Thread the exact values through DashboardView**

Update closures in `providerSettingsSheet`:

```swift
save: { functionName, connectionMode, dangerousPermissionsEnabled, key in
    try viewModel.saveClaudeAPISettings(
        functionName: functionName,
        connectionMode: connectionMode,
        dangerousPermissionsEnabled: dangerousPermissionsEnabled,
        key: key
    )
    activeSheet = nil
}
```

Pass the Codex sheet the existing DashboardView model-loading dependencies used for `CodexProviderSettingsSheet`, then save with `codex` and `dangerousPermissionsEnabled` received from its closure rather than reading `viewModel.config.codexAPI` at callback time.

- [ ] **Step 6: Run application test targets**

Run: `swift test --filter ProviderSettingsViewModelTests && swift test --filter AutomaticShellInstallServiceTests`

Expected: all selected tests pass.

- [ ] **Step 7: Commit UI and settings behavior**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "feat: configure API key commands independently"
```

### Task 5: API Key shell command rendering 완료

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift:124-185`
- Test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift:393-491`

**Interfaces:**
- Consumes: `config.ccapi.dangerousPermissionsEnabled`, `config.codexAPI.codex`, and `config.codexAPI.dangerousPermissionsEnabled` from Task 2.
- Produces: Claude Direct/Proxy functions use `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, and `ANTHROPIC_DEFAULT_HAIKU_MODEL` rather than an editable `ANTHROPIC_MODEL`.

- [ ] **Step 1: Replace obsolete model test with failing API Key rendering tests**

```swift
func testClaudeAPIDirectCommandUsesAPIKeySettingsSkipFlagAndDefaultRoleMappings() throws {
    var config = configuredCommands()
    config.ccapi = .init(connectionMode: .direct, dangerousPermissionsEnabled: true)

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm", includeClaudeAPI: true).render()

    XCTAssertTrue(script.contains("claude --dangerously-skip-permissions \\\"$@\\\""))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-6'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5-20251001'"))
    XCTAssertFalse(script.contains("ANTHROPIC_MODEL="))
}

func testClaudeAPIProxyCommandUsesPrefixedDefaultRoleMappingsAndDoesNotUseGlobalSkipFlag() throws {
    var config = configuredCommands()
    config.includeDangerouslySkipPermissions = true
    config.ccapi = .init(connectionMode: .proxy, dangerousPermissionsEnabled: false)

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm", includeClaudeAPI: true).render()

    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='cpm-claude-api/claude-opus-4-7'"))
    XCTAssertFalse(script.contains("ccapi() {\\n  if ! curl"))
    XCTAssertFalse(apiFunction(named: "ccapi", in: script).contains("--dangerously-skip-permissions"))
}

func testCodexAPICommandUsesItsOwnRoutingAndSkipFlag() throws {
    var config = configuredCommands()
    config.commands.ccodexapi = "ccodexapi"
    config.includeDangerouslySkipPermissions = true
    config.codexAPI = .init(
        codex: .init(
            opus: .init(model: "gpt-5.6", reasoning: .xhigh, contextWindow: .context1m),
            sonnet: .init(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
            haiku: .init(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
        ),
        dangerousPermissionsEnabled: false
    )

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm", enabledFunctions: .init(claudeOAuth: false, codex: false, claudeAPI: false, codexAPI: true)).render()

    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='cpm-codex-api/gpt-5.6(xhigh)'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='cpm-codex-api/gpt-5.6-mini(low)'"))
    XCTAssertFalse(apiFunction(named: "ccodexapi", in: script).contains("--dangerously-skip-permissions"))
}
```

Define a test-local `apiFunction(named:in:)` extractor if needed so OAuth functions cannot accidentally satisfy a skip assertion.

- [ ] **Step 2: Run shell renderer tests and verify failure**

Run: `swift test --filter ShellFunctionRendererTests`

Expected: assertions fail because the renderer uses global `includeDangerouslySkipPermissions` and `config.ccapi.model`.

- [ ] **Step 3: Render dedicated API Key runtime behavior**

Use the API Key-specific flag instead of the global flag:

```swift
private func claudeCommand(skipPermissions: Bool) -> String {
    skipPermissions ? "claude --dangerously-skip-permissions \\\"$@\\\"" : "claude \\\"$@\\\""
}
```

For Claude Direct, retain `ANTHROPIC_API_KEY` injection and proxy variable clearing, but replace `ANTHROPIC_MODEL` with the three `ANTHROPIC_DEFAULT_*_MODEL` values from `OAuthModelDefaults`.

For Claude Proxy, retain health probing and `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`, but render three prefixed default values:

```swift
ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellSingleQuoted(prefixedModel(OAuthModelDefaults.claudeOpusModel, prefix: "cpm-claude-api"))) \\
ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellSingleQuoted(prefixedModel(OAuthModelDefaults.claudeSonnetModel, prefix: "cpm-claude-api"))) \\
ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellSingleQuoted(prefixedModel(OAuthModelDefaults.claudeHaikuModel, prefix: "cpm-claude-api"))) \\
```

For OpenAI API Key, use `config.codexAPI.codex` model roles and `config.codexAPI.dangerousPermissionsEnabled` only.

- [ ] **Step 4: Run renderer tests including zsh validation**

Run: `swift test --filter ShellFunctionRendererTests`

Expected: all shell renderer tests pass and `testDefaultGeneratedScriptPassesZshSyntaxCheck` remains green.

- [ ] **Step 5: Commit shell rendering**

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift \
  Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "feat: render API key command settings"
```

### Task 6: 전체 회귀 검증과 사용자 문서 업데이트

**Files:**
- Modify: `README.md:12-27,38-53,120-123`
- Modify: `README.en.md` corresponding feature, setup, and security sections
- Modify: tests touched by Tasks 1-5 only if full-suite regression exposes stale assumptions

**Interfaces:**
- Consumes: all production behavior from Tasks 1-5.
- Produces: user documentation that API Key is local-file plaintext with `0600` protections, not Keychain.

- [ ] **Step 1: Add concise Korean and English documentation**

Add an API Key bullet to the feature list and setup instructions. In Security, state the precise risk and location:

```markdown
API keys are stored as plaintext files under `~/.cliproxy-manager/api-keys/`. The app creates the directory with `0700` permissions and each key file with `0600` permissions, but anyone who can access your macOS account can read them. Do not copy, commit, or share this directory.
```

Use an equivalent Korean translation in `README.md`. Do not print example keys.

- [ ] **Step 2: Run formatting and the full test suite**

Run: `git diff --check && swift test`

Expected: zero whitespace errors and all tests pass.

- [ ] **Step 3: Build and validate the debug app bundle**

Run: `make verify CONFIGURATION=debug BUILD_DIR=/private/tmp/cliproxymanager-api-key-routing`

Expected: app build, signing, bundle checks, and `codesign verification passed` complete successfully.

- [ ] **Step 4: Verify generated command behavior without exposing real keys**

Use a temporary `ManagedPaths` root and `FileSecretStore` test value only. Confirm `cpm secret get claude-api-key` emits the test key in that controlled shell test, `cpm status --json` runs from the built bundle, and remove the temporary directory afterwards. Do not run commands against the user’s actual API Key files.

- [ ] **Step 5: Commit documentation and final regression adjustments**

```bash
git add README.md README.en.md Tests Sources
git commit -m "docs: explain local API key storage"
```
