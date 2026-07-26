# Canonical Provider Config Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 비공식 약어 기반 legacy AppConfig schema를 version 2 provider/profile 중심 schema로 자동 migration하고, stale OAuth command/profile/functions와 신규 Codex API nickname 초기값 문제를 제거한다.

**Architecture:** `AppConfig`는 `oauthCommandProfiles`, `claudeAPI`, `codexAPI`만 provider 설정의 canonical source로 사용한다. `LegacyAppConfigDecoder`가 version 1 key를 transient migration payload로 읽고, `AppConfigMigration`이 성공적으로 읽은 auth profiles와 결합해 stale profile을 prune한 뒤 version 2 JSON으로 atomic rewrite한다.

**Tech Stack:** Swift 5.10, Foundation Codable, SwiftUI, XCTest, Swift Package Manager, Make

## Global Constraints

- 지원 플랫폼은 `macOS 15.0` 이상을 유지한다.
- 새 config document는 `schemaVersion: 2`를 저장한다.
- runtime model과 version 2 JSON에서 `commands`, `ccapi`, `ccodex`, `nicknames`, `accountPrivacy`, `includeDangerouslySkipPermissions`를 제거한다.
- 비공식 약어는 private legacy decoder coding key에만 남긴다.
- OAuth 설정의 유일한 source는 `oauthCommandProfiles`다.
- API Key 설정은 provider별 단일 `claudeAPI`, `codexAPI`를 유지한다.
- 복수 API Key 등록은 이번 범위에 포함하지 않는다.
- auth profile load 실패 시 stale profile prune과 config rewrite를 하지 않는다.
- 공개 fixture에는 실제 이메일이나 계정 식별자를 넣지 않고 `example.com` 기반 값을 사용한다.
- production 앱과 production process는 조작하지 않는다.
- 자동 검증은 전체 `swift test`와 `CONFIGURATION=debug` development bundle codesign까지 수행한다.
- subagent는 사용자가 명시적으로 동의한 경우에만 사용한다.
- commit은 사용자가 실행 방식을 승인하면서 단계별 commit을 허용한 경우에만 생성한다.

---

## File Structure

### Create

- `Sources/CLIProxyManagerCore/Config/LegacyAppConfigDecoder.swift`
  - version 1 JSON의 private legacy key를 decode하고 canonical API settings 및 transient OAuth defaults를 생성한다.
- `Sources/CLIProxyManagerApp/Models/AppConfigMigration.swift`
  - auth profiles와 load result를 결합하고 stale OAuth command profile을 제거한다.
- `Tests/CLIProxyManagerAppTests/AppConfigMigrationTests.swift`
  - legacy defaults 연결, stale prune, auth load 보호를 검증한다.

### Modify

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - version 2 canonical model, provider API commandName, `Codex.default`, custom encode를 정의한다.
- `Sources/CLIProxyManagerCore/Config/AppConfigStore.swift`
  - `loadDocument()`와 atomic canonical save를 제공한다.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - startup migration finalization, canonical save, delete cleanup, canonical provider settings를 사용한다.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
  - canonical API settings와 신규 Codex API nickname 초기값을 사용한다.
- `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
  - canonical profile/API command만 render한다.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - legacy OAuth fallback을 제거하고 canonical API command를 사용한다.
- `Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift`
  - OAuth/round-robin profile routing과 `Codex.default`를 사용한다.
- `Sources/CLIProxyManagerCore/Diagnostics/ProfileCard.swift`
  - legacy command fields 대신 canonical profile을 읽는다.
- `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
  - canonical API/provider settings를 사용한다.
- `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
  - Codex fallback을 `Codex.default`로 변경한다.
- `Sources/CLIProxyManagerApp/Views/SettingsSheets.swift`
- `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift`
  - canonical provider/profile settings를 사용한다.
- `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
- `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
- `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
  - canonical schema와 migration behavior에 맞게 fixture와 assertion을 갱신한다.

---

### Task 1: Canonical provider settings와 version 2 model 도입

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `AppConfig.currentSchemaVersion: Int`
- Produces: `AppConfig.schemaVersion: Int`
- Produces: `AppConfig.ClaudeAPI.commandName: String`
- Produces: `AppConfig.CodexAPI.commandName: String`
- Produces: `AppConfig.Codex.default: AppConfig.Codex`
- Temporary bridge: legacy computed properties remain only until Task 5 so every intermediate commit compiles.

- [ ] **Step 1: canonical default behavior의 실패 테스트 작성**

`AppConfigStoreTests`의 기존 default test를 다음 canonical assertion으로 교체한다.

```swift
func testDefaultConfigUsesCanonicalProviderSettings() {
    let config = AppConfig.default

    XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
    XCTAssertEqual(config.claudeAPI.commandName, "")
    XCTAssertEqual(config.claudeAPI.nickname, "")
    XCTAssertEqual(config.claudeAPI.connectionMode, .proxy)
    XCTAssertFalse(config.claudeAPI.dangerousPermissionsEnabled)
    XCTAssertEqual(config.codexAPI.commandName, "")
    XCTAssertEqual(config.codexAPI.nickname, "")
    XCTAssertEqual(config.codexAPI.codex, .default)
    XCTAssertEqual(config.oauthCommandProfiles, [])
    XCTAssertEqual(config.roundRobinProfiles, [])
}
```

`AppConfigTests`에 explicit Codex default test를 추가한다.

```swift
func testCodexDefaultUsesCurrentRoleRoutingDefaults() {
    XCTAssertEqual(AppConfig.Codex.default.opus, .init(model: "gpt-5.6-terra", reasoning: .xhigh))
    XCTAssertEqual(AppConfig.Codex.default.sonnet, .init(model: "gpt-5.6-terra", reasoning: .medium))
    XCTAssertEqual(AppConfig.Codex.default.haiku, .init(model: "gpt-5.6-terra", reasoning: .low))
}
```

- [ ] **Step 2: canonical model test가 compile failure인지 확인**

Run:

```bash
swift test --filter AppConfigStoreTests/testDefaultConfigUsesCanonicalProviderSettings
swift test --filter AppConfigTests/testCodexDefaultUsesCurrentRoleRoutingDefaults
```

Expected: FAIL to compile because `schemaVersion`, `claudeAPI`, API `commandName`, and `Codex.default` do not exist.

- [ ] **Step 3: canonical fields와 temporary compatibility bridge 구현**

`AppConfig.swift`에 다음 public canonical surface를 추가한다.

```swift
public static let currentSchemaVersion = 2

public var schemaVersion: Int
public var claudeAPI: ClaudeAPI
public var codexAPI: CodexAPI
public var oauthCommandProfiles: [OAuthCommandProfile]
```

`ClaudeAPI`와 `CodexAPI` initializer를 다음 shape로 변경한다.

```swift
public struct ClaudeAPI: Codable, Equatable, Sendable {
    public var commandName: String
    public var claude: ClaudeRouting
    public var nickname: String
    public var dangerousPermissionsEnabled: Bool

    public init(
        commandName: String = "",
        claude: ClaudeRouting = .automatic,
        nickname: String = "",
        dangerousPermissionsEnabled: Bool = false
    ) {
        self.commandName = commandName
        self.claude = claude
        self.nickname = nickname
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
    }
}

public struct CodexAPI: Codable, Equatable, Sendable {
    public var commandName: String
    public var codex: Codex
    public var nickname: String
    public var dangerousPermissionsEnabled: Bool

    public init(
        commandName: String = "",
        codex: Codex = .default,
        nickname: String = "",
        dangerousPermissionsEnabled: Bool = false
    ) {
        self.commandName = commandName
        self.codex = codex
        self.nickname = nickname
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
    }
}
```

`Codex`에 다음 default를 추가한다.

```swift
public static let `default` = Codex(
    opus: CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh),
    sonnet: CodexRole(model: "gpt-5.6-terra", reasoning: .medium),
    haiku: CodexRole(model: "gpt-5.6-terra", reasoning: .low)
)
```

기존 production consumer가 Task 4~5에서 이동할 때까지 현재 legacy stored properties와 initializer parameter는 그대로 유지하되 새 코드에서는 사용하지 않는다. 기존 initializer는 `commands.ccapi`와 `ccapi`로 `claudeAPI`를, `commands.ccodexapi`와 기존 `codexAPI`로 canonical API settings를 초기화한다. Task 2의 canonical `encode(to:)`는 이 temporary legacy stored properties를 저장하지 않으며, Task 5에서 properties와 initializer parameter 자체를 삭제한다.

- [ ] **Step 4: canonical model targeted tests 통과 확인**

Run:

```bash
swift test --filter AppConfigStoreTests/testDefaultConfigUsesCanonicalProviderSettings
swift test --filter AppConfigTests/testCodexDefaultUsesCurrentRoleRoutingDefaults
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Task 1 commit**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "refactor: add canonical provider config model" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Legacy decoder와 canonical JSON encode

**Files:**
- Create: `Sources/CLIProxyManagerCore/Config/LegacyAppConfigDecoder.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfigStore.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`

**Interfaces:**
- Produces: `AppConfigLoadResult`
- Produces: `LegacyOAuthDefaults`
- Produces: `AppConfigStore.loadDocument() throws -> AppConfigLoadResult`
- Keeps: `AppConfigStore.load() throws -> AppConfig` returning `loadDocument().config` for non-migrating consumers.

- [ ] **Step 1: legacy decode와 canonical encode 실패 테스트 작성**

`AppConfigStoreTests`에 다음 tests를 추가한다.

```swift
func testLegacyDocumentLoadsCanonicalProviderSettingsAndOAuthDefaults() throws {
    let legacyJSON = #"""
    {
      "port": 18317,
      "commands": {
        "cc": "claude-work",
        "ccapi": "claude-api-work",
        "ccodex": "codex-work",
        "ccodexapi": "codex-api-work"
      },
      "ccapi": {
        "nickname": "Claude API",
        "dangerousPermissionsEnabled": true,
        "claude": {"mode":"automatic"}
      },
      "ccodex": {
        "opus":{"model":"gpt-5.6-terra","reasoning":"xhigh"},
        "sonnet":{"model":"gpt-5.6-terra","reasoning":"medium"},
        "haiku":{"model":"gpt-5.6-terra","reasoning":"low"}
      },
      "codexAPI": {
        "nickname": "Codex API",
        "codex": {
          "opus":{"model":"gpt-5.6-terra","reasoning":"xhigh"},
          "sonnet":{"model":"gpt-5.6-terra","reasoning":"medium"},
          "haiku":{"model":"gpt-5.6-terra","reasoning":"low"}
        }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true
    }
    """#
    let store = try storeContaining(legacyJSON)

    let loaded = try store.loadDocument()

    XCTAssertEqual(loaded.config.claudeAPI.commandName, "claude-api-work")
    XCTAssertEqual(loaded.config.claudeAPI.nickname, "Claude API")
    XCTAssertEqual(loaded.config.codexAPI.commandName, "codex-api-work")
    XCTAssertEqual(loaded.config.codexAPI.nickname, "Codex API")
    XCTAssertEqual(loaded.legacyOAuthDefaults?.claude?.commandName, "claude-work")
    XCTAssertEqual(loaded.legacyOAuthDefaults?.codex?.commandName, "codex-work")
    XCTAssertTrue(loaded.requiresCanonicalRewrite)
}

func testCanonicalSaveWritesOnlyVersion2ProviderKeys() throws {
    let sandbox = try makeSandbox()
    let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
    var config = AppConfig.default
    config.claudeAPI.commandName = "claude-api-work"
    config.codexAPI.commandName = "codex-api-work"

    try store.save(config)

    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.configFile)) as? [String: Any]
    )
    XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    XCTAssertNotNil(object["claudeAPI"])
    XCTAssertNotNil(object["codexAPI"])
    for legacyKey in ["commands", "ccapi", "ccodex", "nicknames", "accountPrivacy", "includeDangerouslySkipPermissions"] {
        XCTAssertNil(object[legacyKey], "Unexpected legacy key: \(legacyKey)")
    }
}
```

`storeContaining(_:)`는 test file private helper로 sandbox config file에 문자열을 쓰고 `AppConfigStore`를 반환한다.

- [ ] **Step 2: legacy decode/canonical encode tests의 RED 확인**

Run:

```bash
swift test --filter AppConfigStoreTests/testLegacyDocumentLoadsCanonicalProviderSettingsAndOAuthDefaults
swift test --filter AppConfigStoreTests/testCanonicalSaveWritesOnlyVersion2ProviderKeys
```

Expected: FAIL because `loadDocument`, `LegacyOAuthDefaults`, and version 2 custom encoding do not exist.

- [ ] **Step 3: load result와 private legacy decoder 구현**

`LegacyAppConfigDecoder.swift`에 다음 interface를 정의한다.

```swift
public struct LegacyOAuthProviderDefaults: Equatable, Sendable {
    public var commandName: String
    public var nickname: String
    public var accountDetailHidden: Bool
    public var dangerousPermissionsEnabled: Bool
    public var claude: AppConfig.ClaudeRouting?
    public var codex: AppConfig.Codex?
}

public struct LegacyOAuthDefaults: Equatable, Sendable {
    public var claude: LegacyOAuthProviderDefaults?
    public var codex: LegacyOAuthProviderDefaults?
}

public struct AppConfigLoadResult: Equatable, Sendable {
    public var config: AppConfig
    public var legacyOAuthDefaults: LegacyOAuthDefaults?
    public var requiresCanonicalRewrite: Bool

    public static func canonical(_ config: AppConfig) -> AppConfigLoadResult {
        AppConfigLoadResult(config: config, legacyOAuthDefaults: nil, requiresCanonicalRewrite: false)
    }
}
```

`LegacyAppConfigDecoder`는 private `Commands`, `Nicknames`, `AccountPrivacy`, old API settings coding structs를 사용한다. 이 file 외부 production identifier에는 `cc`, `ccapi`, `ccodex`, `ccodexapi`를 만들지 않는다.

`AppConfigStore.loadDocument()`는 raw JSON의 `schemaVersion`을 probe한다.

```swift
public func loadDocument() throws -> AppConfigLoadResult {
    guard fileManager.fileExists(atPath: paths.configFile.path) else {
        return .canonical(.default)
    }
    let data = try Data(contentsOf: paths.configFile)
    if LegacyAppConfigDecoder.isLegacyDocument(data) {
        return try LegacyAppConfigDecoder.decode(data)
    }
    return .canonical(try JSONDecoder().decode(AppConfig.self, from: data))
}

public func load() throws -> AppConfig {
    try loadDocument().config
}
```

`AppConfig.encode(to:)`는 version 2 canonical key만 encode한다.

- [ ] **Step 4: AppConfigStore tests 통과 확인**

Run:

```bash
swift test --filter AppConfigStoreTests
```

Expected: all AppConfigStoreTests PASS. 기존 round-trip fixture는 canonical initializer와 canonical API command fields를 사용하도록 갱신한다.

- [ ] **Step 5: Task 2 commit**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Sources/CLIProxyManagerCore/Config/AppConfigStore.swift \
  Sources/CLIProxyManagerCore/Config/LegacyAppConfigDecoder.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "feat: migrate legacy config documents to version 2" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Auth-aware migration과 stale profile prune

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/AppConfigMigration.swift`
- Create: `Tests/CLIProxyManagerAppTests/AppConfigMigrationTests.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:8-21, 313-340, 878-886, 2014-2087, 2373-2381`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`

**Interfaces:**
- Produces: `AppConfigMigration.reconcile(loadResult:authProfiles:) -> AppConfigMigrationResult`
- Produces: `AppConfigMigrationResult.config`
- Produces: `AppConfigMigrationResult.shouldPersist`
- Produces: `AppConfigStoring.loadDocument()` with a protocol default returning `.canonical(try load())` for existing stubs.

- [ ] **Step 1: migration behavior 실패 tests 작성**

`AppConfigMigrationTests.swift`를 다음 cases로 생성한다.

```swift
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class AppConfigMigrationTests: XCTestCase {
    func testReconcilePrunesProfilesWithoutAuthFilesAndRewritesConfig() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "stale-codex",
                provider: .codex,
                authProfileID: "missing.json",
                commandName: "stale-command",
                codex: .default,
                modelPrefix: "codex-stale"
            )
        ]
        let loaded = AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: nil,
            requiresCanonicalRewrite: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [])

        XCTAssertEqual(result.config.oauthCommandProfiles, [])
        XCTAssertTrue(result.shouldPersist)
    }

    func testReconcileAttachesLegacyDefaultsToFirstMatchingAuthProfile() {
        let loaded = AppConfigLoadResult(
            config: .default,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: nil,
                codex: LegacyOAuthProviderDefaults(
                    commandName: "codex-work",
                    nickname: "Work",
                    accountDetailHidden: false,
                    dangerousPermissionsEnabled: true,
                    claude: nil,
                    codex: .default
                )
            ),
            requiresCanonicalRewrite: true
        )
        let authProfile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "account@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [authProfile])

        XCTAssertEqual(result.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].authProfileID, authProfile.id)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].commandName, "codex-work")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].nickname, "Work")
        XCTAssertTrue(result.shouldPersist)
    }

    func testCanonicalProfileWinsOverLegacyDefaults() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "canonical-command",
                nickname: "Canonical",
                codex: .default
            )
        ]
        let loaded = AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: nil,
                codex: LegacyOAuthProviderDefaults(
                    commandName: "legacy-command",
                    nickname: "Legacy",
                    accountDetailHidden: true,
                    dangerousPermissionsEnabled: false,
                    claude: nil,
                    codex: .default
                )
            ),
            requiresCanonicalRewrite: true
        )
        let authProfile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "account@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [authProfile])

        XCTAssertEqual(result.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].commandName, "canonical-command")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].nickname, "Canonical")
    }

    func testReconcileDiscardsLegacyOAuthDefaultsWhenNoAuthProfileExists() {
        let loaded = AppConfigLoadResult(
            config: .default,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: LegacyOAuthProviderDefaults(
                    commandName: "claude-work",
                    nickname: "Work",
                    accountDetailHidden: false,
                    dangerousPermissionsEnabled: false,
                    claude: .automatic,
                    codex: nil
                ),
                codex: nil
            ),
            requiresCanonicalRewrite: true
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [])

        XCTAssertTrue(result.config.oauthCommandProfiles.isEmpty)
        XCTAssertTrue(result.shouldPersist)
    }
}
```

`DashboardViewModelTests`에 auth load failure test를 추가한다.

```swift
func testAuthProfileLoadFailureDoesNotPruneOrPersistCommandProfiles() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "kept",
            provider: .codex,
            authProfileID: "kept.json",
            commandName: "kept-command",
            codex: .default
        )
    ]
    let store = StubConfigStore(config: config)
    let authStore = ThrowingAuthProfileStore(error: CocoaError(.fileReadNoSuchFile))

    let viewModel = makeViewModel(
        config: config,
        profiles: [],
        configStore: store,
        authProfileStore: authStore
    )

    XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.id), ["kept"])
    XCTAssertTrue(store.savedConfigs.isEmpty)
}

private struct ThrowingAuthProfileStore: AuthProfileManaging {
    let error: Error

    func profiles() throws -> [AuthProfile] { throw error }
    func delete(for _: AuthProfileType) throws -> Int { throw error }
}
```

같은 suite에 migration save failure test도 추가한다.

```swift
func testMigrationSaveFailureKeepsInMemoryCanonicalConfigAndReportsError() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "stale",
            provider: .codex,
            authProfileID: "missing.json",
            commandName: "stale-command",
            codex: .default
        )
    ]
    let store = StubConfigStore(
        config: config,
        saveError: CocoaError(.fileWriteUnknown)
    )

    let viewModel = makeViewModel(
        config: config,
        profiles: [],
        configStore: store
    )

    XCTAssertTrue(viewModel.config.oauthCommandProfiles.isEmpty)
    XCTAssertEqual(store.config.oauthCommandProfiles.map(\.id), ["stale"])
    XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Config migration failed:") == true)
}
```

- [ ] **Step 2: migration tests RED 확인**

Run:

```bash
swift test --filter AppConfigMigrationTests
swift test --filter DashboardViewModelTests/testAuthProfileLoadFailureDoesNotPruneOrPersistCommandProfiles
```

Expected: FAIL because `AppConfigMigration` and auth-load-aware startup behavior do not exist.

- [ ] **Step 3: pure AppConfigMigration 구현**

`AppConfigMigration.reconcile`은 다음 순서를 사용한다.

```swift
struct AppConfigMigrationResult: Equatable, Sendable {
    let config: AppConfig
    let shouldPersist: Bool
}

enum AppConfigMigration {
    static func reconcile(
        loadResult: AppConfigLoadResult,
        authProfiles: [AuthProfile]
    ) -> AppConfigMigrationResult {
        var config = loadResult.config
        let authIDs = Set(authProfiles.map(\.id))
        var commandProfiles = config.oauthCommandProfiles.filter {
            authIDs.contains($0.authProfileID)
        }
        var usedIDs = Set(commandProfiles.map(\.id))
        var seenAuthProfileIDs = Set(commandProfiles.map(\.authProfileID))
        let firstAuthProfileIDs = Dictionary(
            authProfiles.map { ($0.type, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let preferProviderID = commandProfiles.isEmpty

        for authProfile in authProfiles where !seenAuthProfileIDs.contains(authProfile.id) {
            let legacyDefaults: LegacyOAuthProviderDefaults?
            if firstAuthProfileIDs[authProfile.type] == authProfile.id {
                switch authProfile.type {
                case .claude:
                    legacyDefaults = loadResult.legacyOAuthDefaults?.claude
                case .codex:
                    legacyDefaults = loadResult.legacyOAuthDefaults?.codex
                }
            } else {
                legacyDefaults = nil
            }

            let id = commandProfileID(
                provider: authProfile.type,
                authProfileID: authProfile.id,
                preferProviderID: preferProviderID,
                usedIDs: &usedIDs
            )
            commandProfiles.append(
                AppConfig.OAuthCommandProfile(
                    id: id,
                    provider: authProfile.type,
                    authProfileID: authProfile.id,
                    commandName: legacyDefaults?.commandName ?? "",
                    nickname: legacyDefaults?.nickname ?? "",
                    accountDetailHidden: legacyDefaults?.accountDetailHidden ?? true,
                    dangerousPermissionsEnabled: legacyDefaults?.dangerousPermissionsEnabled ?? false,
                    claude: authProfile.type == .claude
                        ? (legacyDefaults?.claude ?? .automatic)
                        : nil,
                    codex: authProfile.type == .codex
                        ? (legacyDefaults?.codex ?? .default)
                        : nil,
                    modelPrefix: "",
                    connectionMode: .proxy,
                    isEnabled: !authProfile.disabled
                )
            )
            seenAuthProfileIDs.insert(authProfile.id)
        }

        config.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(commandProfiles)
        return AppConfigMigrationResult(
            config: config,
            shouldPersist: loadResult.requiresCanonicalRewrite || config != loadResult.config
        )
    }
}
```

기존 `DashboardViewModel`의 helper 구현을 이름만 정리해 `AppConfigMigration`으로 그대로 이동한다.

```swift
private static func commandProfileID(
    provider: AuthProfileType,
    authProfileID: String,
    preferProviderID: Bool,
    usedIDs: inout Set<String>
) -> String

private static func commandProfilesWithRecomputedModelPrefixes(
    _ commandProfiles: [AppConfig.OAuthCommandProfile]
) -> [AppConfig.OAuthCommandProfile]

private static func uniqueModelPrefix(
    provider: AuthProfileType,
    nickname: String,
    authProfileID: String,
    usedPrefixes: inout Set<String>
) -> String

private static func modelPrefixBase(
    provider: AuthProfileType,
    nickname: String,
    authProfileID: String
) -> String

private static func shortAuthProfileSlug(
    provider: AuthProfileType,
    authProfileID: String
) -> String

private static func nonEmptySlug(for value: String) -> String?
private static func slug(for value: String) -> String
private static func rawSlug(for value: String) -> String
```

`commandProfileID`의 첫 branch는 `preferProviderID && !usedIDs.contains(provider.rawValue)`일 때 `provider.rawValue`를 반환하고, 나머지 slug 및 model-prefix 생성 body는 현재 `DashboardViewModel.swift:2090-2193`의 검증된 구현을 변경 없이 이동한다.

- [ ] **Step 4: Dashboard startup에서 성공한 auth load에만 migration 적용**

`AppConfigStoring`에 `loadDocument()`를 추가하고 default implementation을 제공한다.

```swift
protocol AppConfigStoring: Sendable {
    func load() throws -> AppConfig
    func loadDocument() throws -> AppConfigLoadResult
    func save(_ config: AppConfig) throws
}

extension AppConfigStoring {
    func loadDocument() throws -> AppConfigLoadResult {
        .canonical(try load())
    }
}
```

`DashboardViewModel` initialization은 `config` argument가 없을 때 `loadDocument()`를 사용하고, explicit `config`가 있으면 `.canonical(config)`를 사용한다.

```swift
let loadResult = config.map(AppConfigLoadResult.canonical)
    ?? ((try? configStore.loadDocument()) ?? .canonical(.default))
```

`CodexCredentialMigrationResult.profiles`를 `[AuthProfile]`에서 `Result<[AuthProfile], Error>`로 변경해 `try? ... ?? []`이 load failure를 빈 목록으로 위장하지 않게 한다.

```swift
private struct CodexCredentialMigrationResult {
    let config: AppConfig
    let profiles: Result<[AuthProfile], Error>
}
```

- `.success(authProfiles)`: `AppConfigMigration.reconcile`을 적용하고 `shouldPersist`이면 `configStore.save`를 호출한다.
- `.failure`: `loadResult.config`의 OAuth profiles를 그대로 사용하고 config를 저장하지 않는다.
- save failure: 기존 file을 유지하고 `settingsMessage = "Config migration failed: \(error.localizedDescription)"`를 설정하되 in-memory canonical config와 canonical shell rendering은 유지한다.

`refreshProfiles()`도 `do/catch`로 변경한다. `authProfileStore.profiles()` 성공 시에만 `.canonical(config)`을 reconcile하여 prune하고 변경된 canonical config를 저장한다. 실패하면 현재 `authProfiles`, `config`, generated shell functions를 보존한다.

- [ ] **Step 5: migration와 Dashboard tests 통과 확인**

Run:

```bash
swift test --filter AppConfigMigrationTests
swift test --filter DashboardViewModelTests
swift test --filter ProviderSettingsViewModelTests
```

Expected: all selected suites PASS. startup stale profile test에서 saved config와 generated function names에 stale command가 없어야 한다.

- [ ] **Step 6: Task 3 commit**

```bash
git add Sources/CLIProxyManagerApp/Models/AppConfigMigration.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/AppConfigMigrationTests.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "fix: reconcile provider config with auth profiles" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Core renderer와 CLI를 canonical schema로 전환

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift`
- Modify: `Sources/CLIProxyManagerCore/Diagnostics/ProfileCard.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
- Modify: corresponding Core tests listed in File Structure

**Interfaces:**
- Consumes: canonical `oauthCommandProfiles`, `claudeAPI`, `codexAPI`, `Codex.default`
- Removes: all renderer/CLI legacy single-OAuth fallback branches

- [ ] **Step 1: canonical renderer 실패 tests 작성**

`ShellFunctionRendererTests`의 API fixtures를 다음 방식으로 변경한다.

```swift
var config = AppConfig.default
config.claudeAPI.commandName = "claude-api-work"
config.codexAPI.commandName = "codex-api-work"
config.oauthCommandProfiles = [
    .init(
        id: "codex-work",
        provider: .codex,
        authProfileID: "codex-work.json",
        commandName: "codex-work",
        codex: .default,
        modelPrefix: "codex-work"
    )
]
```

추가 test:

```swift
func testRendererDoesNotCreateLegacyOAuthFunctionsWhenProfilesAreEmpty() throws {
    let script = try ShellFunctionRenderer(
        config: .default,
        helperCommand: "/usr/local/bin/cpm",
        enabledFunctions: .init(claudeOAuth: true, codex: true, claudeAPI: false, codexAPI: false)
    ).render()

    XCTAssertFalse(script.contains("() {"))
}
```

`CodexFastModeTests`는 OAuth/round-robin profile의 missing routing fallback이 `.default`임을 literal model values로 검증한다.

- [ ] **Step 2: canonical Core tests RED 확인**

Run:

```bash
swift test --filter ShellFunctionRendererTests
swift test --filter CodexFastModeTests
swift test --filter CLIProxyManagerCommandTests
swift test --filter RoundRobinSelectionServiceTests
```

Expected: tests fail until production consumers stop reading temporary legacy bridges.

- [ ] **Step 3: Core consumers를 canonical fields로 변경**

`ShellFunctionRenderer`:

```swift
for commandProfile in oauthCommandProfilesToRender() {
    script += renderOAuthFunction(commandProfile)
}
if enabledFunctions.claudeAPI, hasCommandName(config.claudeAPI.commandName) { ... }
if enabledFunctions.codexAPI, hasCommandName(config.codexAPI.commandName) { ... }
```

- `renderLegacyOAuthFunctions()` 삭제
- API function name과 permission은 `claudeAPI`/`codexAPI`에서 읽음
- OAuth profile의 missing Codex routing은 `.default`

`CodexFastConfiguration`:

```swift
let oauthCodexConfigs = config.oauthCommandProfiles.compactMap {
    guard $0.provider == .codex, $0.isEnabled else { return nil }
    return $0.codex ?? .default
}
let roundRobinCodexConfigs = config.roundRobinProfiles.compactMap {
    guard $0.provider == .codex, $0.isEnabled else { return nil }
    return $0.codex ?? .default
}
```

`ProfileCard`는 provider별 첫 canonical OAuth profile의 command를 읽는다. `CLIProxyManagerCommand`와 `RoundRobinSelectionService`도 API command/routing 및 `.default` fallback으로 변경한다.

- [ ] **Step 4: Core targeted suites 통과 확인**

Run:

```bash
swift test --filter ShellFunctionRendererTests
swift test --filter CodexFastModeTests
swift test --filter CLIProxyManagerCommandTests
swift test --filter RoundRobinSelectionServiceTests
swift test --filter AppConfigStoreTests
```

Expected: all selected suites PASS.

- [ ] **Step 5: Task 4 commit**

```bash
git add Sources/CLIProxyManagerCore \
  Tests/CLIProxyManagerCoreTests
git commit -m "refactor: use canonical provider config in core" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: App consumers 전환과 legacy bridge 제거

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsSheets.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: App test suites listed in File Structure

**Interfaces:**
- Consumes: canonical provider settings and migration result
- Removes: temporary legacy computed bridges and Dashboard mirror/reset helpers

- [ ] **Step 1: app-level canonical save/delete 실패 tests 작성**

`ProviderSettingsViewModelTests`에 다음 tests를 추가한다.

```swift
func testSaveCodexAPISettingsPersistsCommandInsideCodexAPI() throws {
    let store = StubConfigStore(config: .default)
    let viewModel = makeViewModel(configStore: store)

    try viewModel.saveCodexAPISettings(
        functionName: "codex-api-work",
        nickname: "Work",
        codex: .default,
        dangerousPermissionsEnabled: false,
        key: "test-secret"
    )

    XCTAssertEqual(store.config.codexAPI.commandName, "codex-api-work")
    XCTAssertEqual(store.config.codexAPI.nickname, "Work")
}

func testRemoveProviderCleansCommandProfileWhenAuthFileIsAlreadyMissing() {
    let authProfile = AuthProfile(
        fileName: "codex-work.json",
        type: .codex,
        email: "account@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "codex-work",
            provider: .codex,
            authProfileID: authProfile.id,
            commandName: "codex-work",
            codex: .default
        )
    ]
    let store = StubConfigStore(config: config)
    let authStore = StubAuthProfileStore(profiles: [authProfile], supportsIDDelete: false)
    let viewModel = makeViewModel(
        config: config,
        profiles: [authProfile],
        configStore: store,
        authProfileStore: authStore
    )
    authStore.nextProfiles = []

    viewModel.removeProvider(.init(rawValue: "codex-work"))

    XCTAssertTrue(store.config.oauthCommandProfiles.isEmpty)
    XCTAssertEqual(viewModel.settingsMessage, "Codex auth file was not found.")
}
```

- [ ] **Step 2: app canonical tests RED 확인**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testSaveCodexAPISettingsPersistsCommandInsideCodexAPI
swift test --filter ProviderSettingsViewModelTests/testRemoveProviderCleansCommandProfileWhenAuthFileIsAlreadyMissing
swift test --filter AutomaticShellInstallServiceTests
```

Expected: FAIL because save/remove/install still use temporary legacy bridges.

- [ ] **Step 3: Dashboard와 AutomaticShellInstallService 전환**

다음을 canonical field로 바꾼다.

- Claude API command: `config.claudeAPI.commandName`
- Codex API command: `config.codexAPI.commandName`
- API nickname/routing/permission: 동일 provider object
- OAuth command/routing/privacy/permission: `oauthCommandProfiles`
- missing Codex routing: `.default`

`activeFunctionNames`, `enabledShellFunctions`, provider rows, save/remove API provider, settings initial state, option rows를 갱신한다.

`removeAPIProvider`는 provider 설정에서 `commandName`을 비우며 secret transaction rollback을 유지한다. OAuth `removeProvider`는 auth file이 이미 없어도 row ID에 해당하는 command profile을 제거하고 canonical save/shell regeneration을 수행한다.

다음 helpers는 삭제한다.

- `normalizedCommands`
- `mirroredLegacyFields`
- `resetLegacyFields`
- legacy provider-wide command fallback

- [ ] **Step 4: AppConfig temporary bridge와 legacy model 제거**

모든 production reference가 사라진 것을 확인한다.

Run:

```bash
rg -n "\.commands\.(cc|ccapi|ccodex|ccodexapi)|\.ccapi\b|\.ccodex\b|\.nicknames\.(cc|ccodex)|includeDangerouslySkipPermissions|accountPrivacy\.(claudeHidden|codexHidden)" Sources
```

Expected: no matches outside `LegacyAppConfigDecoder.swift` private coding declarations.

그 다음 `AppConfig.swift`에서 다음을 삭제한다.

- `Commands`
- `Nicknames`
- temporary `commands`, `ccapi`, `ccodex`, `nicknames`, `accountPrivacy`, `includeDangerouslySkipPermissions` bridges
- bridge-only pending setter state

`LegacyAppConfigDecoder`의 descriptive migration payload만 유지한다.

- [ ] **Step 5: App targeted suites 통과 확인**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests
swift test --filter DashboardViewModelTests
swift test --filter AutomaticShellInstallServiceTests
swift test --filter RoundRobinSettingsViewTests
swift test --filter SettingsNavigationTests
```

Expected: all selected suites PASS.

- [ ] **Step 6: Task 5 commit**

```bash
git add Sources/CLIProxyManagerApp \
  Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerAppTests
git commit -m "refactor: remove legacy command config bridges" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: 신규 Codex API Key nickname 초기값

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift:1160-1205`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`

**Interfaces:**
- Produces: `codexAPIInitialNickname(isConfigured:savedNickname:) -> String`

- [ ] **Step 1: 신규/기존 nickname 실패 tests 작성**

`ProviderSettingsViewModelTests`에 추가한다.

```swift
func testNewCodexAPIKeyStartsWithBlankNickname() {
    XCTAssertEqual(
        codexAPIInitialNickname(isConfigured: false, savedNickname: "Saved nickname"),
        ""
    )
}

func testConfiguredCodexAPIKeyKeepsSavedNickname() {
    XCTAssertEqual(
        codexAPIInitialNickname(isConfigured: true, savedNickname: "Saved nickname"),
        "Saved nickname"
    )
}
```

- [ ] **Step 2: nickname tests RED 확인**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests/testNewCodexAPIKeyStartsWithBlankNickname
swift test --filter ProviderSettingsViewModelTests/testConfiguredCodexAPIKeyKeepsSavedNickname
```

Expected: FAIL to compile because the helper does not exist.

- [ ] **Step 3: 최소 helper와 sheet 적용**

`ProviderSettingsSheets.swift`의 API key helper section에 추가한다.

```swift
func codexAPIInitialNickname(isConfigured: Bool, savedNickname: String) -> String {
    isConfigured ? savedNickname : ""
}
```

`CodexAPIProviderSettingsSheet.init`에서 사용한다.

```swift
_nickname = State(initialValue: codexAPIInitialNickname(
    isConfigured: isConfigured,
    savedNickname: config.codexAPI.nickname
))
```

- [ ] **Step 4: nickname와 provider settings tests 통과 확인**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests
```

Expected: suite PASS, 0 failures.

- [ ] **Step 5: Task 6 commit**

```bash
git add Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "fix: clear nickname for new Codex API keys" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Fixture 비식별화와 migration 문서 갱신

**Files:**
- Modify: tests/docs containing account-derived slug fixtures found by the commands below
- Modify: `docs/superpowers/specs/2026-07-26-canonical-provider-config-design.md` only if implementation names differ from the approved interfaces

**Interfaces:**
- Produces: public repository free of real email/account identifiers

- [ ] **Step 1: 개인정보와 비공식 source identifier scan**

Run:

```bash
rg -n -i --pcre2 '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' \
  Sources Tests docs \
  --glob '!.build/**' --glob '!build/**' \
  | rg -v '@example\.(com|net|org)|noreply@anthropic\.com'
```

Expected before cleanup: any remaining historical account-derived fixture paths are listed.

- [ ] **Step 2: fixture를 reserved examples로 교체**

다음 deterministic replacements를 사용한다.

- personal email → `account@example.com`
- second email → `team@example.net`
- auth file ID → `codex-work.json`, `codex-team.json`, `claude-work.json`
- model prefix → `codex-work`, `codex-team`, `claude-work`

Assertion expected value도 동일한 canonical fixture로 갱신한다. 실제 runtime data나 screen text를 복사하지 않는다.

- [ ] **Step 3: 개인정보와 legacy source identifier scan 통과 확인**

Run:

```bash
! (rg -n -i --pcre2 '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' Sources Tests docs | rg -v '@example\.(com|net|org)|noreply@anthropic\.com')
! rg -n "\.commands\.(cc|ccapi|ccodex|ccodexapi)|\.ccapi\b|\.ccodex\b|\.nicknames\.(cc|ccodex)|includeDangerouslySkipPermissions|accountPrivacy\.(claudeHidden|codexHidden)" Sources --glob '!**/LegacyAppConfigDecoder.swift'
```

Expected: both commands exit 0 because no matches remain.

- [ ] **Step 4: affected tests 실행**

Run:

```bash
swift test --filter ProviderSettingsViewModelTests
swift test --filter DashboardViewModelTests
swift test --filter AppConfigStoreTests
```

Expected: all selected suites PASS.

- [ ] **Step 5: Task 7 commit**

```bash
git add Sources Tests docs
git commit -m "test: anonymize provider config fixtures" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: 전체 회귀와 development migration 검증

**Files:**
- Verify only: all modified source and test files
- Runtime fixture: temporary sandbox config only; do not edit production config

**Interfaces:**
- Consumes: completed version 2 migration
- Produces: full suite, development bundle, canonical JSON evidence

- [ ] **Step 1: 전체 Swift suite 실행**

Run:

```bash
swift test
```

Expected: all tests PASS, 0 failures.

- [ ] **Step 2: development bundle과 codesign 검증**

Run:

```bash
make CONFIGURATION=debug verify
```

Expected:

```text
Bundled build/CLIProxyManager.app
codesign verification passed
```

- [ ] **Step 3: temporary legacy config migration smoke test**

테스트 전용 temporary root에 legacy JSON과 비식별 auth fixtures를 만들고 Core/App migration tests를 통해 다음을 확인한다.

```bash
swift test --filter AppConfigStoreTests/testLegacyDocumentLoadsCanonicalProviderSettingsAndOAuthDefaults
swift test --filter AppConfigMigrationTests
```

Expected:

- version 1 keys decode
- stale profile removed
- version 2 encode contains `schemaVersion`, `claudeAPI`, `codexAPI`, `oauthCommandProfiles`
- version 2 encode excludes every legacy key

실제 `~/.cliproxy-manager` 또는 `~/.cliproxy-manager/dev` config를 test script로 수정하지 않는다.

- [ ] **Step 4: 최종 source/privacy scan**

Run:

```bash
git diff --check
! (rg -n -i --pcre2 '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' Sources Tests docs | rg -v '@example\.(com|net|org)|noreply@anthropic\.com')
! rg -n "\.commands\.(cc|ccapi|ccodex|ccodexapi)|\.ccapi\b|\.ccodex\b|\.nicknames\.(cc|ccodex)|includeDangerouslySkipPermissions|accountPrivacy\.(claudeHidden|codexHidden)" Sources --glob '!**/LegacyAppConfigDecoder.swift'
git status --short --branch
```

Expected: formatting/privacy/schema scans clean; worktree has no uncommitted tracked changes.

- [ ] **Step 5: 사용자 수동 확인 항목 전달**

Development build에서 사용자가 확인한다.

1. 기존 development config가 자동으로 canonical version 2로 migration되는지
2. 화면에 없는 stale OAuth command가 더 이상 shell function으로 생성되지 않는지
3. OAuth 계정 삭제 후 해당 command/profile/routing이 config에서 사라지는지
4. Codex OAuth 계정이 없을 때 top-level Codex OAuth model 설정이 남지 않는지
5. 신규 Codex API Key nickname이 빈 값인지
6. 기존 configured Codex API Key 편집에서는 저장된 nickname이 유지되는지

production 앱과 production config는 조작하지 않는다.
