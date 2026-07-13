# Account Reordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자가 메인 화면에서 OAuth 및 API key 계정을 재정렬하고, 그 순서를 앱 재실행·메뉴바·Usage HUD 전체에서 일관되게 유지하도록 구현한다.

**Architecture:** `AppConfig.accountOrder`가 모든 계정의 표시 ID를 저장하는 단일 지속화 소스가 된다. 순수 `AccountOrdering` 유틸리티가 저장 순서 정규화와 이동 계산을 담당하고, `DashboardViewModel`이 정렬된 `providerRows`를 메인 화면·메뉴바·HUD에 공유하며 명시적 순서 변경만 전용 경량 저장 경로로 저장한다.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 15+, Foundation Codable, XCTest, Swift Package Manager

## Global Constraints

- OAuth 계정과 Claude/OpenAI API key 계정을 하나의 통합 순서로 관리한다.
- 앱 메인 화면만 재정렬 UI를 제공하며 메뉴바와 Usage HUD는 `providerRows` 순서를 소비한다.
- 계정 순서 변경은 인증 정보, shell function, 라우팅 설정, 서버 상태를 변경하거나 서버를 재시작하지 않는다.
- 기존 설정에 `accountOrder`가 없으면 현재 생성 순서를 사용한다.
- 새 계정은 마지막에 추가하고 삭제된 계정 ID와 중복 ID는 정규화 과정에서 제거한다.
- 저장 실패 시 메모리 순서와 `config.accountOrder`를 rollback하고 `Account order could not be saved: <localized error>` toast를 표시한다.
- 카드 전체가 아니라 항상 보이는 전용 drag handle만 draggable로 만든다.
- drag-and-drop 외에 `Move Up`과 `Move Down` 메뉴 명령을 제공한다.
- Reduce Motion이 활성화되면 위치 전환 애니메이션을 생략한다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, development app bundle build까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Structure

- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - `accountOrder`의 Codable 저장 모델과 legacy 기본값을 소유한다.
- Create: `Sources/CLIProxyManagerApp/Models/AccountOrdering.swift`
  - 저장 ID 정규화와 계정 이동을 부작용 없이 계산한다.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - 원본 행에 저장 순서를 적용하고, 명시적 이동을 저장하며 실패 시 rollback한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - drag handle, 삽입선, drop target, Move Up/Move Down 명령을 제공한다.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - 기본값과 legacy decode를 검증한다.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
  - 설정 파일 round trip을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/AccountOrderingTests.swift`
  - 정규화와 이동 알고리즘을 독립 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - 통합 정렬, 수명주기 보존, 저장, rollback을 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift`
  - 필터링 후 상대 순서 보존을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/AccountReorderingUITests.swift`
  - SwiftUI source 계약으로 handle, drop destination, 대체 이동 명령을 검증한다.

---

### Task 1: Persist the unified account order in AppConfig

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:354-474`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:5-37,75-104`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift:4-107`

**Interfaces:**
- Produces: `AppConfig.accountOrder: [String]`
- Produces: `AppConfig.init(..., accountOrder: [String] = [], ...)`
- Compatibility: missing JSON key decodes as `[]`

- [ ] **Step 1: Write failing AppConfig compatibility tests**

Add these assertions and tests to `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`:

```swift
func testDefaultConfigHasNoStoredAccountOrder() {
    XCTAssertEqual(AppConfig.default.accountOrder, [])
}

func testDecodedConfigDefaultsMissingAccountOrderToEmpty() throws {
    let data = Data(#"""
    {
      "port": 18317,
      "commands": { "cc": "", "ccapi": "", "ccodex": "" },
      "ccapi": {},
      "ccodex": {
        "opus": { "model": "gpt-5.6-terra", "reasoning": "xhigh", "contextWindow": "auto" },
        "sonnet": { "model": "gpt-5.6-terra", "reasoning": "medium", "contextWindow": "auto" },
        "haiku": { "model": "gpt-5.6-terra", "reasoning": "low", "contextWindow": "auto" }
      },
      "includeDangerouslySkipPermissions": false,
      "startAtLogin": false,
      "showDockIcon": true,
      "showMenuBarIcon": true
    }
    """#.utf8)

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertEqual(config.accountOrder, [])
}

func testAccountOrderRoundTripsThroughCodable() throws {
    var config = AppConfig.default
    config.accountOrder = ["codex-api", "claude-work", "claude-api"]

    let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

    XCTAssertEqual(decoded.accountOrder, ["codex-api", "claude-work", "claude-api"])
}
```

Also add `XCTAssertEqual(config.accountOrder, [])` to `testDefaultConfigMatchesMVPDecisions()`.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: compilation fails because `AppConfig` has no member `accountOrder`.

- [ ] **Step 3: Add accountOrder to AppConfig**

In `Sources/CLIProxyManagerCore/Config/AppConfig.swift`, add the stored property beside the other account collections:

```swift
public var oauthCommandProfiles: [OAuthCommandProfile]
public var roundRobinProfiles: [RoundRobinProfile]
public var accountOrder: [String]
```

Add the initializer parameter after `roundRobinProfiles` and assign it:

```swift
roundRobinProfiles: [RoundRobinProfile] = [],
accountOrder: [String] = [],
bindAddress: String = "127.0.0.1",
```

```swift
self.roundRobinProfiles = roundRobinProfiles
self.accountOrder = accountOrder
```

Add the key and backward-compatible decode:

```swift
case accountOrder
```

```swift
self.accountOrder = try c.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
```

- [ ] **Step 4: Extend the file-store round-trip test**

In `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`, set a mixed order in `testStoreSavesAndLoadsConfig()` before saving:

```swift
config.accountOrder = ["codex-personal", "claude-api", "claude-work"]
```

The existing full equality assertion must continue to pass.

- [ ] **Step 5: Run AppConfig tests**

Run:

```bash
swift test --filter 'AppConfigTests|AppConfigStoreTests'
```

Expected: all selected tests pass with 0 failures.

- [ ] **Step 6: Commit the storage model**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift
git commit -m "feat: persist account display order

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add pure account-order normalization and movement

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/AccountOrdering.swift`
- Create: `Tests/CLIProxyManagerAppTests/AccountOrderingTests.swift`

**Interfaces:**
- Consumes: `ProviderRowState`, `ProviderRowState.ID`, stored `[String]`
- Produces: `AccountOrdering.orderedRows(_:storedIDs:) -> [ProviderRowState]`
- Produces: `AccountOrdering.moving(_:id:before:) -> [ProviderRowState]`
- Contract: `before: nil` means move to the end

- [ ] **Step 1: Write failing normalization tests**

Create `Tests/CLIProxyManagerAppTests/AccountOrderingTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class AccountOrderingTests: XCTestCase {
    func testStoredOrderPlacesKnownAccountsFirstAndAppendsNewAccounts() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        let ordered = AccountOrdering.orderedRows(
            rows,
            storedIDs: ["codex-work", "claude-work"]
        )

        XCTAssertEqual(ordered.map(\.id.rawValue), ["codex-work", "claude-work", "claude-api"])
    }

    func testStoredOrderDropsDuplicatesAndMissingAccounts() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        let ordered = AccountOrdering.orderedRows(
            rows,
            storedIDs: ["missing", "codex-work", "codex-work", "claude-work"]
        )

        XCTAssertEqual(ordered.map(\.id.rawValue), ["codex-work", "claude-work", "claude-api"])
    }

    func testEmptyStoredOrderKeepsSourceOrder() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        XCTAssertEqual(
            AccountOrdering.orderedRows(rows, storedIDs: []).map(\.id.rawValue),
            ["claude-work", "codex-work", "claude-api"]
        )
    }

    private func row(_ id: String) -> ProviderRowState {
        ProviderRowState(
            id: ProviderRowState.ID(rawValue: id),
            name: id,
            nickname: "",
            functionName: id,
            connectionTitle: "Connected",
            connectionDetail: id,
            isConnected: true
        )
    }
}
```

- [ ] **Step 2: Run normalization tests and verify failure**

Run:

```bash
swift test --filter AccountOrderingTests
```

Expected: compilation fails because `AccountOrdering` does not exist.

- [ ] **Step 3: Implement orderedRows minimally**

Create `Sources/CLIProxyManagerApp/Models/AccountOrdering.swift`:

```swift
enum AccountOrdering {
    static func orderedRows(
        _ rows: [ProviderRowState],
        storedIDs: [String]
    ) -> [ProviderRowState] {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.rawValue, $0) })
        var seen: Set<String> = []
        var ordered: [ProviderRowState] = []

        for id in storedIDs where seen.insert(id).inserted {
            if let row = rowsByID[id] {
                ordered.append(row)
            }
        }

        ordered.append(contentsOf: rows.filter { seen.insert($0.id.rawValue).inserted })
        return ordered
    }
}
```

- [ ] **Step 4: Run normalization tests**

Run:

```bash
swift test --filter AccountOrderingTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Write failing movement tests**

Append to `AccountOrderingTests`:

```swift
func testMoveBeforePlacesSourceImmediatelyBeforeTarget() {
    let rows = [row("a"), row("b"), row("c"), row("d")]

    let moved = AccountOrdering.moving(
        rows,
        id: ProviderRowState.ID(rawValue: "d"),
        before: ProviderRowState.ID(rawValue: "b")
    )

    XCTAssertEqual(moved.map(\.id.rawValue), ["a", "d", "b", "c"])
}

func testMoveBeforeAccountsForRemovingAnEarlierSource() {
    let rows = [row("a"), row("b"), row("c"), row("d")]

    let moved = AccountOrdering.moving(
        rows,
        id: ProviderRowState.ID(rawValue: "a"),
        before: ProviderRowState.ID(rawValue: "d")
    )

    XCTAssertEqual(moved.map(\.id.rawValue), ["b", "c", "a", "d"])
}

func testMoveWithNilTargetAppendsToEnd() {
    let rows = [row("a"), row("b"), row("c")]

    let moved = AccountOrdering.moving(
        rows,
        id: ProviderRowState.ID(rawValue: "a"),
        before: nil
    )

    XCTAssertEqual(moved.map(\.id.rawValue), ["b", "c", "a"])
}

func testInvalidAndSelfMovesAreNoOps() {
    let rows = [row("a"), row("b")]

    XCTAssertEqual(
        AccountOrdering.moving(rows, id: "missing", before: "a"),
        rows
    )
    XCTAssertEqual(
        AccountOrdering.moving(rows, id: "a", before: "a"),
        rows
    )
}
```

- [ ] **Step 6: Run movement tests and verify failure**

Run:

```bash
swift test --filter AccountOrderingTests
```

Expected: compilation fails because `AccountOrdering.moving` does not exist.

- [ ] **Step 7: Implement movement calculation**

Add to `AccountOrdering`:

```swift
static func moving(
    _ rows: [ProviderRowState],
    id: ProviderRowState.ID,
    before targetID: ProviderRowState.ID?
) -> [ProviderRowState] {
    guard targetID != id,
          let sourceIndex = rows.firstIndex(where: { $0.id == id }) else {
        return rows
    }

    var movedRows = rows
    let source = movedRows.remove(at: sourceIndex)

    if let targetID {
        guard let targetIndex = movedRows.firstIndex(where: { $0.id == targetID }) else {
            return rows
        }
        movedRows.insert(source, at: targetIndex)
    } else {
        movedRows.append(source)
    }

    return movedRows
}
```

- [ ] **Step 8: Run AccountOrdering tests**

Run:

```bash
swift test --filter AccountOrderingTests
```

Expected: all 7 tests pass with 0 failures.

- [ ] **Step 9: Commit the pure ordering component**

```bash
git add Sources/CLIProxyManagerApp/Models/AccountOrdering.swift \
  Tests/CLIProxyManagerAppTests/AccountOrderingTests.swift
git commit -m "feat: add account ordering rules

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Apply and persist ordering in DashboardViewModel

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:741-748,1947-2046,2220-2294`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:171-240,3628-3650`

**Interfaces:**
- Consumes: `AppConfig.accountOrder`, `AccountOrdering.orderedRows`, `AccountOrdering.moving`
- Produces: `DashboardViewModel.moveAccount(_:before:)`
- Produces: `DashboardViewModel.moveAccountUp(_:)`
- Produces: `DashboardViewModel.moveAccountDown(_:)`
- Produces: `DashboardViewModel.canMoveAccountUp(_:) -> Bool`
- Produces: `DashboardViewModel.canMoveAccountDown(_:) -> Bool`

- [ ] **Step 1: Write failing initial-order and normalization tests**

Add a new `@MainActor final class DashboardAccountOrderingTests: XCTestCase` before the test doubles in `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`. Use these helpers inside the class:

```swift
private func profile(_ id: String, type: AuthProfileType) -> AuthProfile {
    AuthProfile(
        fileName: id,
        type: type,
        email: "\(id)@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )
}

private func commandProfile(
    id: String,
    authProfileID: String,
    provider: AuthProfileType
) -> AppConfig.OAuthCommandProfile {
    AppConfig.OAuthCommandProfile(
        id: id,
        provider: provider,
        authProfileID: authProfileID,
        commandName: "cmd-\(id)",
        nickname: id,
        isEnabled: true
    )
}

private func makeViewModel(
    config: AppConfig,
    profiles: [AuthProfile],
    configStore: StubConfigStore? = nil,
    authProfileStore: (any AuthProfileManaging)? = nil,
    secretStore: any SecretStore = InMemorySecretStore()
) -> DashboardViewModel {
    DashboardViewModel(
        config: config,
        configStore: configStore ?? StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: authProfileStore ?? StubAuthProfileStore(profiles: profiles),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: secretStore
    )
}

private func connectedClaudeConnector() -> ClaudeConnector {
    ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
        ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
    ], count: 4).flatMap { $0 }))
}
```

Add the tests:

```swift
func testProviderRowsApplyStoredOrderAcrossOAuthAndAPIKeyAccounts() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "claude-work", authProfileID: "claude.json", provider: .claude),
        commandProfile(id: "codex-work", authProfileID: "codex.json", provider: .codex)
    ]
    config.accountOrder = ["codex-api", "claude-work", "claude-api", "codex-work"]
    let secrets = InMemorySecretStore()
    try secrets.set("claude-key", for: .claudeAPIKey)
    try secrets.set("codex-key", for: .codexAPIKey)

    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("claude.json", type: .claude), profile("codex.json", type: .codex)],
        secretStore: secrets
    )

    XCTAssertEqual(
        viewModel.providerRows.map(\.id.rawValue),
        ["codex-api", "claude-work", "claude-api", "codex-work"]
    )
}

func testProviderRowsNormalizeMissingDuplicateAndNewAccountIDs() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "claude-work", authProfileID: "claude.json", provider: .claude),
        commandProfile(id: "codex-work", authProfileID: "codex.json", provider: .codex)
    ]
    config.accountOrder = ["missing", "codex-work", "codex-work"]

    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("claude.json", type: .claude), profile("codex.json", type: .codex)]
    )

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["codex-work", "claude-work"])
    XCTAssertEqual(viewModel.config.accountOrder, ["codex-work", "claude-work"])
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter DashboardAccountOrderingTests
```

Expected: assertions fail because `providerRows` still use construction order and `config.accountOrder` is not normalized.

- [ ] **Step 3: Apply AccountOrdering when rebuilding provider rows**

At the end of `rebuildProviderRows`, replace the direct assignment:

```swift
let orderedRows = AccountOrdering.orderedRows(rows, storedIDs: config.accountOrder)
providerRows = orderedRows
config.accountOrder = orderedRows.map(\.id.rawValue)
```

This keeps `providerRows` and in-memory `config.accountOrder` synchronized every time accounts are rebuilt.

- [ ] **Step 4: Ensure existing save paths persist the normalized order**

In `saveConfig`, make the local updated config mutable and save the post-rebuild `config` value:

```swift
var updatedConfig = Self.persistedConfig(persistedConfig)
```

After the first `rebuildProviderRows(...)`, synchronize the local value:

```swift
updatedConfig = config
```

Then keep using `updatedConfig` for shell application and `configStore.save(updatedConfig)`.

Apply the same principle to `savePrivacyOnlyConfig`: after assigning `config`, rebuilding rows, and normalizing `accountOrder`, use the post-rebuild `config` value for `configStore.save` and `lastPersistedConfig`. Name it explicitly:

```swift
let normalizedConfig = config
try configStore.save(normalizedConfig)
lastPersistedConfig = normalizedConfig
```

Do not add server restart or shell installation to the account-order-only path introduced below.

- [ ] **Step 5: Run initial-order tests**

Run:

```bash
swift test --filter DashboardAccountOrderingTests
```

Expected: the two initial tests pass.

- [ ] **Step 6: Write failing move, boundary, and rollback tests**

Add these tests to `DashboardAccountOrderingTests`:

```swift
func testMoveAccountPersistsNewOrderWithoutChangingOtherConfig() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex),
        commandProfile(id: "c", authProfileID: "c.json", provider: .claude)
    ]
    let store = StubConfigStore(config: config)
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex), profile("c.json", type: .claude)],
        configStore: store
    )

    viewModel.moveAccount("c", before: "a")

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["c", "a", "b"])
    XCTAssertEqual(viewModel.config.accountOrder, ["c", "a", "b"])
    XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["c", "a", "b"])
    XCTAssertEqual(store.savedConfigs.last?.port, config.port)
}

func testMoveUpAndDownRespectBoundaries() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex),
        commandProfile(id: "c", authProfileID: "c.json", provider: .claude)
    ]
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex), profile("c.json", type: .claude)]
    )

    XCTAssertFalse(viewModel.canMoveAccountUp("a"))
    XCTAssertFalse(viewModel.canMoveAccountDown("c"))
    XCTAssertTrue(viewModel.canMoveAccountUp("b"))
    XCTAssertTrue(viewModel.canMoveAccountDown("b"))

    viewModel.moveAccountUp("b")
    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["b", "a", "c"])

    viewModel.moveAccountDown("a")
    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["b", "c", "a"])
}

func testMoveAccountRollsBackWhenSavingFails() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
    ]
    let store = StubConfigStore(
        config: config,
        saveError: NSError(
            domain: "AccountOrder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Disk full"]
        )
    )
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)],
        configStore: store
    )
    let originalOrder = viewModel.providerRows.map(\.id.rawValue)
    let originalConfigOrder = viewModel.config.accountOrder

    viewModel.moveAccount("b", before: "a")

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), originalOrder)
    XCTAssertEqual(viewModel.config.accountOrder, originalConfigOrder)
    XCTAssertEqual(viewModel.settingsMessage, "Account order could not be saved: Disk full")
}

func testNoOpMovesDoNotSave() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
    ]
    let store = StubConfigStore(config: config)
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)],
        configStore: store
    )

    viewModel.moveAccount("a", before: "a")
    viewModel.moveAccountUp("a")
    viewModel.moveAccountDown("b")

    XCTAssertTrue(store.savedConfigs.isEmpty)
}
```

Use `ProviderRowState.ID` string literal conformance as shown; if XCTest overload resolution needs explicit types, wrap values with `ProviderRowState.ID(rawValue:)` without changing the public signatures.

- [ ] **Step 7: Run move tests and verify failure**

Run:

```bash
swift test --filter DashboardAccountOrderingTests
```

Expected: compilation fails because the move and capability methods do not exist.

- [ ] **Step 8: Implement the dedicated move persistence path**

Add these `DashboardViewModel` methods near the provider lifecycle actions:

```swift
func canMoveAccountUp(_ id: ProviderRowState.ID) -> Bool {
    guard let index = providerRows.firstIndex(where: { $0.id == id }) else { return false }
    return index > providerRows.startIndex
}

func canMoveAccountDown(_ id: ProviderRowState.ID) -> Bool {
    guard let index = providerRows.firstIndex(where: { $0.id == id }) else { return false }
    return index < providerRows.index(before: providerRows.endIndex)
}

func moveAccountUp(_ id: ProviderRowState.ID) {
    guard let index = providerRows.firstIndex(where: { $0.id == id }), index > 0 else { return }
    moveAccount(id, before: providerRows[index - 1].id)
}

func moveAccountDown(_ id: ProviderRowState.ID) {
    guard let index = providerRows.firstIndex(where: { $0.id == id }),
          index + 1 < providerRows.count else { return }
    let targetID = index + 2 < providerRows.count ? providerRows[index + 2].id : nil
    moveAccount(id, before: targetID)
}

func moveAccount(
    _ id: ProviderRowState.ID,
    before targetID: ProviderRowState.ID?
) {
    let movedRows = AccountOrdering.moving(providerRows, id: id, before: targetID)
    guard movedRows != providerRows else { return }

    let oldRows = providerRows
    let oldConfig = config
    var updatedConfig = config
    updatedConfig.accountOrder = movedRows.map(\.id.rawValue)

    providerRows = movedRows
    config = updatedConfig

    do {
        try configStore.save(updatedConfig)
        lastPersistedConfig = updatedConfig
    } catch {
        providerRows = oldRows
        config = oldConfig
        settingsMessage = "Account order could not be saved: \(error.localizedDescription)"
    }
}
```

This path intentionally does not call `saveConfig`, because changing display order must not validate/reinstall shell functions, sync auth prefixes, or restart the server.

- [ ] **Step 9: Run Dashboard account-order tests**

Run:

```bash
swift test --filter DashboardAccountOrderingTests
```

Expected: all account-order view model tests pass.

- [ ] **Step 10: Add lifecycle preservation tests**

Add tests that exercise existing lifecycle paths rather than calling the pure helper directly:

```swift
func testNewAccountIsAppendedWithoutChangingExistingRelativeOrder() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
    ]
    config.accountOrder = ["b", "a"]
    let authStore = StubAuthProfileStore(
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)]
    )
    let viewModel = makeViewModel(
        config: config,
        profiles: [],
        authProfileStore: authStore
    )
    authStore.nextProfiles = [
        profile("a.json", type: .claude),
        profile("b.json", type: .codex),
        profile("c.json", type: .claude)
    ]

    viewModel.refreshProfiles()

    XCTAssertEqual(Array(viewModel.providerRows.map(\.id.rawValue).prefix(2)), ["b", "a"])
    XCTAssertEqual(viewModel.providerRows.last?.authProfileID, "c.json")
}

func testProfileRefreshPreservesStoredRelativeOrder() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
    ]
    config.accountOrder = ["b", "a"]
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)]
    )

    viewModel.refreshProfiles()

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["b", "a"])
}

func testDeletingAccountRemovesItsIDAndPreservesSurvivorOrder() {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
        commandProfile(id: "b", authProfileID: "b.json", provider: .codex),
        commandProfile(id: "c", authProfileID: "c.json", provider: .claude)
    ]
    config.accountOrder = ["c", "b", "a"]
    let store = StubConfigStore(config: config)
    let authStore = StubAuthProfileStore(
        profiles: [
            profile("a.json", type: .claude),
            profile("b.json", type: .codex),
            profile("c.json", type: .claude)
        ],
        supportsIDDelete: true
    )
    let viewModel = makeViewModel(
        config: config,
        profiles: [],
        configStore: store,
        authProfileStore: authStore
    )

    viewModel.removeProvider("b")

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["c", "a"])
    XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["c", "a"])
}

func testAPIKeyReRegistrationAppendsAfterSurvivingAccounts() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        commandProfile(id: "a", authProfileID: "a.json", provider: .claude)
    ]
    config.accountOrder = ["claude-api", "a"]
    let store = StubConfigStore(config: config)
    let secrets = InMemorySecretStore()
    try secrets.set("old-key", for: .claudeAPIKey)
    let viewModel = makeViewModel(
        config: config,
        profiles: [profile("a.json", type: .claude)],
        configStore: store,
        secretStore: secrets
    )

    viewModel.removeAPIProvider(.claudeAPI)
    XCTAssertEqual(viewModel.config.accountOrder, ["a"])

    try viewModel.saveClaudeAPISettings(
        functionName: "ccapi",
        nickname: "API",
        dangerousPermissionsEnabled: false,
        key: "new-key"
    )

    XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["a", "claude-api"])
    XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["a", "claude-api"])
}
```

- [ ] **Step 11: Run lifecycle and existing Dashboard tests**

Run:

```bash
swift test --filter 'DashboardAccountOrderingTests|DashboardViewModelRefreshTests'
```

Expected: all selected tests pass with 0 failures.

- [ ] **Step 12: Commit view-model ordering**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: apply account order across dashboard state

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Add drag handles, drop positions, and accessible move commands

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:27-96,561-756`
- Create: `Tests/CLIProxyManagerAppTests/AccountReorderingUITests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift:335-438`

**Interfaces:**
- Consumes: `DashboardViewModel.moveAccount(_:before:)`, move up/down and capability methods
- Produces: `AccountReorderDropZone` private SwiftUI component
- UI transfer payload: account ID as `String`
- UI drop position: integer insertion offset `0...providerRows.count`

- [ ] **Step 1: Write failing menu-order preservation test**

Add to `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift`:

```swift
func testConnectedProvidersPreserveInputRelativeOrderAfterFiltering() {
    let providers = [
        ProviderRowState(
            id: "codex-work",
            name: "Codex OAuth",
            nickname: "Codex",
            functionName: "codex",
            connectionTitle: "Connected",
            connectionDetail: "codex@example.com",
            isConnected: true
        ),
        ProviderRowState(
            id: "disabled",
            name: "Claude OAuth",
            nickname: "Disabled",
            functionName: "disabled",
            connectionTitle: "Disabled",
            connectionDetail: "disabled@example.com",
            isConnected: false,
            isDisabled: true
        ),
        ProviderRowState(
            id: "claude-work",
            name: "Claude OAuth",
            nickname: "Claude",
            functionName: "claude",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )
    ]

    let snapshot = MenuBarStatusSnapshot(
        serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
        providers: providers
    )

    XCTAssertEqual(snapshot.connectedProviders.map(\.id.rawValue), ["codex-work", "claude-work"])
}
```

- [ ] **Step 2: Run the menu snapshot test**

Run:

```bash
swift test --filter MenuBarStatusSnapshotTests/testConnectedProvidersPreserveInputRelativeOrderAfterFiltering
```

Expected: PASS, documenting that menu bar and Usage HUD already preserve the shared input order. No production change is required for these views.

- [ ] **Step 3: Write failing SwiftUI source-contract tests**

Create `Tests/CLIProxyManagerAppTests/AccountReorderingUITests.swift`:

```swift
import XCTest

final class AccountReorderingUITests: XCTestCase {
    func testDashboardUsesDedicatedDragHandleAndStringDropDestination() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("line.3.horizontal"))
        XCTAssertTrue(source.contains(".draggable(account.id.rawValue)"))
        XCTAssertTrue(source.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(source.contains("Reorder account"))
    }

    func testDashboardProvidesMoveUpAndMoveDownFallbackCommands() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("Move Up"))
        XCTAssertTrue(source.contains("Move Down"))
        XCTAssertTrue(source.contains("canMoveAccountUp"))
        XCTAssertTrue(source.contains("canMoveAccountDown"))
    }

    func testDashboardTracksInsertionPositionAndReducedMotion() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("activeDropIndex"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("AccountReorderDropZone"))
    }

    private func dashboardSource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 4: Run UI contract tests and verify failure**

Run:

```bash
swift test --filter AccountReorderingUITests
```

Expected: all three tests fail because the dashboard has no reorder UI.

- [ ] **Step 5: Add dashboard reorder state and insertion zones**

In `DashboardView`, add:

```swift
@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
@State private var activeDropIndex: Int?
```

Replace the account `ForEach` with an enumerated list and insertion zones:

```swift
let accounts = viewModel.providerRows.map { DashboardAccountSnapshot(provider: $0) }
ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
    AccountReorderDropZone(
        isActive: activeDropIndex == index,
        setTargeted: { isTargeted in
            if isTargeted {
                activeDropIndex = index
            } else if activeDropIndex == index {
                activeDropIndex = nil
            }
        },
        drop: { draggedID in
            viewModel.moveAccount(
                ProviderRowState.ID(rawValue: draggedID),
                before: account.id
            )
            activeDropIndex = nil
        }
    )

    ProviderAccountCardView(
        account: account,
        canReorder: accounts.count > 1,
        isDropTarget: activeDropIndex == index,
        connect: {
            if account.isAPIKeyProfile {
                openProviderSettings(account.id, isInitialSetup: false)
            } else {
                activeSheet = .addProvider
                viewModel.startOAuthLogin(account.id)
            }
        },
        settings: { openProviderSettings(account.id, isInitialSetup: false) },
        toggleAccountDetailVisibility: { viewModel.toggleAccountDetailVisibility(account.id) },
        setEnabled: { enabled in viewModel.setProviderEnabled(account.id, enabled: enabled) },
        moveUp: { viewModel.moveAccountUp(account.id) },
        moveDown: { viewModel.moveAccountDown(account.id) },
        canMoveUp: viewModel.canMoveAccountUp(account.id),
        canMoveDown: viewModel.canMoveAccountDown(account.id),
        remove: {
            if account.isAPIKeyProfile {
                viewModel.removeAPIProvider(account.id)
            } else {
                viewModel.removeProvider(account.id)
            }
        }
    )
    .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16), value: viewModel.providerRows.map(\.id))
}

AccountReorderDropZone(
    isActive: activeDropIndex == accounts.count,
    setTargeted: { isTargeted in
        if isTargeted {
            activeDropIndex = accounts.count
        } else if activeDropIndex == accounts.count {
            activeDropIndex = nil
        }
    },
    drop: { draggedID in
        viewModel.moveAccount(ProviderRowState.ID(rawValue: draggedID), before: nil)
        activeDropIndex = nil
    }
)
```

The snippet above keeps the existing connect/settings/privacy/enable/remove behavior verbatim while adding reorder arguments.

- [ ] **Step 6: Add the private drop-zone component**

Add below the account card section in `DashboardView.swift`:

```swift
private struct AccountReorderDropZone: View {
    let isActive: Bool
    let setTargeted: (Bool) -> Void
    let drop: (String) -> Void

    var body: some View {
        Rectangle()
            .fill(isActive ? BrandPalette.accent : .clear)
            .frame(height: isActive ? 3 : 6)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let draggedID = items.first else { return false }
                drop(draggedID)
                return true
            } isTargeted: { targeted in
                setTargeted(targeted)
            }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
```

The final zone after all cards makes it possible to move an account to the end. Each preceding zone represents insertion immediately before its card.

- [ ] **Step 7: Add the dedicated drag handle to ProviderAccountCardView**

Extend `ProviderAccountCardView` inputs:

```swift
let canReorder: Bool
let isDropTarget: Bool
let moveUp: () -> Void
let moveDown: () -> Void
let canMoveUp: Bool
let canMoveDown: Bool
```

Insert this view before `ProviderAvatar`:

```swift
Image(systemName: "line.3.horizontal")
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(.tertiary)
    .frame(width: 18, height: 28)
    .contentShape(Rectangle())
    .draggable(account.id.rawValue)
    .disabled(!canReorder)
    .opacity(canReorder ? 1 : 0.35)
    .accessibilityLabel("Reorder account")
    .accessibilityHint("Change the position of \(account.title) in the account list")
```

Update the card background so the current target receives a weak accent fill while preserving hover behavior:

```swift
.fill(
    isDropTarget
        ? BrandPalette.accent.opacity(0.10)
        : Color.primary.opacity(hovering ? 0.07 : 0.04)
)
```

- [ ] **Step 8: Add Move Up and Move Down to every account action menu**

At the top of each of the connected, disabled, and disconnected `Menu` blocks, add:

```swift
Button("Move Up", action: moveUp)
    .disabled(!canMoveUp)
Button("Move Down", action: moveDown)
    .disabled(!canMoveDown)
Divider()
```

Keep the existing enable/disable/remove actions after this divider. This ensures every visible account state has the non-drag fallback.

- [ ] **Step 9: Run focused UI and ordering tests**

Run:

```bash
swift test --filter 'AccountReorderingUITests|AccountOrderingTests|DashboardAccountOrderingTests|MenuBarStatusSnapshotTests'
```

Expected: all selected tests pass with 0 failures.

- [ ] **Step 10: Build the app target to catch SwiftUI API issues**

Run:

```bash
swift build --product CLIProxyManager
```

Expected: build completes successfully. Existing unrelated warnings may remain, but there must be no errors from `draggable`, `dropDestination`, bindings, or animation types.

- [ ] **Step 11: Commit the reorder UI**

```bash
git add Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Tests/CLIProxyManagerAppTests/AccountReorderingUITests.swift \
  Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift
git commit -m "feat: add account drag reordering UI

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Run regression and development-build verification

**Files:**
- Verify only; modify production or tests only if a failure exposes an issue directly caused by Tasks 1-4.

**Interfaces:**
- Consumes: all implementation from Tasks 1-4
- Produces: passing full test suite and signed development app bundle at `build/CLIProxyManager.app`

- [ ] **Step 1: Run all Swift tests**

Run:

```bash
swift test
```

Expected: all tests pass with 0 failures. The baseline before implementation was 714 tests; the final count must be higher because new tests were added.

- [ ] **Step 2: Build and sign the development app bundle**

Run:

```bash
make sign CONFIGURATION=debug
```

Expected:

- `build/CLIProxyManager.app` is produced.
- The app, bundled `cpm`, bundled `cliproxy-manager`, and Sparkle framework are signed with the configured development identity.
- Command exits with status 0.

If the local `cliproxymanager` signing identity is unavailable, report that exact environment limitation and run the non-signing fallback:

```bash
make bundle CONFIGURATION=debug
```

The fallback must still produce `build/CLIProxyManager.app`; do not claim signing verification passed.

- [ ] **Step 3: Verify repository state and review the final diff**

Run:

```bash
git status --short
git diff main...HEAD --stat
git log --oneline --decorate main..HEAD
```

Expected:

- No uncommitted implementation files remain.
- The branch contains the design commit, plan commit, and focused implementation commits.
- The diff is limited to the approved account-order feature and its tests/docs.

- [ ] **Step 4: Provide the manual UI checklist to the user**

Report the development bundle path and ask the user to verify:

1. At least three mixed OAuth/API key accounts are visible.
2. Every card shows a drag handle before the Provider avatar.
3. Dragging onto each insertion gap shows a clear accent line and target highlight.
4. Dropping at the final gap moves an account to the end.
5. `Move Up` and `Move Down` work and disable correctly at boundaries.
6. Main window, menu bar, and Usage HUD update to the same relative order immediately.
7. Quitting and reopening the app preserves the order.
8. Adding an account appends it; deleting an account preserves the surviving relative order.

Do not launch the app automatically; runtime UI verification is the user's responsibility.
