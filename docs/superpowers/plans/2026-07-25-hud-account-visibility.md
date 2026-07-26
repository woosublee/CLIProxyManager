# Usage HUD Account Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메인 계정 카드에서 계정별 Usage HUD 표시 여부를 관리하고, 선택을 지속화하여 Expanded와 Compact HUD에만 적용한다.

**Architecture:** `AppConfig.UsageOverlay.hiddenAccountIDs`를 숨김 상태의 단일 저장소로 사용하고, `DashboardViewModel`이 이를 `ProviderRowState.showsInUsageOverlay`로 투영한다. 메인 카드는 이 값을 토글하고, 별도 `UsageOverlayAccountPresentation`이 HUD 전용 필터와 빈 상태를 계산하므로 메뉴바 presentation과 usage 조회 수명주기는 기존 동작을 유지한다.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- 새 외부 dependency를 추가하지 않는다.
- `hiddenAccountIDs`가 없는 기존 설정은 빈 배열로 decode하여 모든 기존 계정을 표시한다.
- 새 OAuth/API key 계정은 기본적으로 HUD에 표시한다.
- HUD 버튼은 Connected, Disabled, Disconnected 카드에서 항상 26×26 click target으로 표시한다.
- 버튼 symbol은 `chart.bar.xaxis`, action copy는 `Hide from Usage HUD`와 `Show in Usage HUD`를 사용한다.
- 선택은 Expanded와 Compact HUD에 공통 적용하고 기존 `accountOrder` 상대 순서를 유지한다.
- 메뉴바 계정 목록에는 hidden 설정을 적용하지 않는다.
- 계정 표시 변경은 서버 재시작, management key 변경, polling 취소, usage snapshot/cache 삭제를 유발하지 않는다.
- 모든 계정을 숨기면 HUD를 닫지 않고 `No accounts selected`를 표시한다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, development app bundle build까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Structure

- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift` — hidden account ID의 Codable 저장과 migration을 담당한다.
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift` — 계정별 HUD 표시 상태를 provider presentation에 노출한다.
- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift` — 카드에 전달할 표시 상태와 HUD 버튼 presentation을 제공한다.
- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift` — HUD 전용 필터, connected provider 변환, 빈 상태를 계산한다.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` — 표시 상태 계산, 저장, rollback, 계정 삭제 시 정리를 담당한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift` — 모든 계정 카드에 상시 HUD 버튼을 배치한다.
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — HUD presentation을 사용하고 Expanded 빈 상태를 전달한다.
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift` — 선택 상태에 맞는 빈 상태 copy를 표시한다.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` — 저장 모델의 기본값, migration, 중복 정규화, round-trip을 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` — 파생 상태, 토글 저장, rollback, side effect 부재, 삭제 정리를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift` — 카드 snapshot과 버튼 presentation을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountPresentationTests.swift` — HUD 필터, 순서, 메뉴바 독립성, 빈 상태를 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift` — 메인 카드가 HUD 버튼과 저장 action을 연결했는지 검증한다.
- Modify: `README.md` — 한국어 Usage HUD 계정 선택 사용법을 기록한다.
- Modify: `README.en.md` — 영어 Usage HUD 계정 선택 사용법을 기록한다.

---

### Task 1: Usage HUD hidden account 설정 지속화

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:334-370`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:5-212`

**Interfaces:**
- Consumes: 기존 `AppConfig.UsageOverlay` Codable 모델
- Produces: `AppConfig.UsageOverlay.hiddenAccountIDs: [String]`, 누락 필드의 빈 배열 migration, decode 시 중복 제거

- [ ] **Step 1: 기본값과 migration 실패 테스트 작성**

`AppConfigTests`의 기존 UsageOverlay 테스트 근처에 다음 테스트를 추가한다.

```swift
func testUsageOverlayDefaultsHiddenAccountIDsToEmpty() {
    XCTAssertEqual(AppConfig.UsageOverlay().hiddenAccountIDs, [])
    XCTAssertEqual(AppConfig.default.usageOverlay.hiddenAccountIDs, [])
}

func testUsageOverlayMissingHiddenAccountIDsDecodesAsEmpty() throws {
    let data = Data(#"{"isVisible":true,"alwaysOnTop":false,"backgroundOpacity":0.7,"displayMode":"compact"}"#.utf8)

    let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

    XCTAssertEqual(decoded.hiddenAccountIDs, [])
    XCTAssertEqual(decoded.displayMode, .compact)
}
```

- [ ] **Step 2: 테스트가 새 property 부재로 실패하는지 확인**

Run: `swift test --filter AppConfigTests/testUsageOverlayDefaultsHiddenAccountIDsToEmpty`

Expected: FAIL — `AppConfig.UsageOverlay`에 `hiddenAccountIDs`가 없다는 compile error

- [ ] **Step 3: 중복 정규화와 round-trip 실패 테스트 작성**

```swift
func testUsageOverlayDeduplicatesHiddenAccountIDsWhenDecoding() throws {
    let data = Data(#"{"hiddenAccountIDs":["claude","codex","claude","claude-api","codex"]}"#.utf8)

    let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

    XCTAssertEqual(decoded.hiddenAccountIDs, ["claude", "codex", "claude-api"])
}

func testUsageOverlayHiddenAccountIDsRoundTrip() throws {
    let overlay = AppConfig.UsageOverlay(
        isVisible: true,
        alwaysOnTop: true,
        backgroundOpacity: 0.45,
        displayMode: .compact,
        hiddenAccountIDs: ["codex-work", "claude-api"]
    )

    let decoded = try JSONDecoder().decode(
        AppConfig.UsageOverlay.self,
        from: JSONEncoder().encode(overlay)
    )

    XCTAssertEqual(decoded, overlay)
    XCTAssertEqual(decoded.hiddenAccountIDs, ["codex-work", "claude-api"])
}
```

- [ ] **Step 4: `UsageOverlay`에 최소 Codable 구현 추가**

`AppConfig.UsageOverlay`에 property와 initializer parameter를 추가한다.

```swift
public var hiddenAccountIDs: [String]

public init(
    isVisible: Bool = false,
    alwaysOnTop: Bool = false,
    backgroundOpacity: Double = 0.9,
    displayMode: DisplayMode = .expanded,
    hiddenAccountIDs: [String] = []
) {
    self.isVisible = isVisible
    self.alwaysOnTop = alwaysOnTop
    self.backgroundOpacity = min(max(backgroundOpacity, 0.2), 1)
    self.displayMode = displayMode
    self.hiddenAccountIDs = Self.uniqued(hiddenAccountIDs)
}
```

`CodingKeys`, decoder, 중복 제거 helper를 다음처럼 갱신한다.

```swift
private enum CodingKeys: String, CodingKey {
    case isVisible, alwaysOnTop, backgroundOpacity, displayMode, hiddenAccountIDs
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
    self.alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
    self.backgroundOpacity = min(
        max(try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.9, 0.2),
        1
    )
    self.displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .expanded
    self.hiddenAccountIDs = Self.uniqued(
        try container.decodeIfPresent([String].self, forKey: .hiddenAccountIDs) ?? []
    )
}

private static func uniqued(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
```

Synthesized `encode(to:)`가 새 필드를 기록하도록 별도 encoder는 추가하지 않는다.

- [ ] **Step 5: AppConfig focused tests 실행**

Run: `swift test --filter AppConfigTests`

Expected: PASS — 기존 display mode/opacity 테스트와 새 hidden account 테스트 모두 통과

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "feat: persist hidden Usage HUD accounts"
```

---

### Task 2: Provider 행에 HUD 표시 상태 투영

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift:31-82`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:2770-2850`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:320-388`

**Interfaces:**
- Consumes: Task 1의 `AppConfig.UsageOverlay.hiddenAccountIDs`
- Produces: `ProviderRowState.showsInUsageOverlay: Bool`, `DashboardViewModel`이 구성하는 모든 OAuth/API key 행의 파생 표시 상태

- [ ] **Step 1: Provider 행 기본값과 config 투영 실패 테스트 작성**

`DashboardViewModelTests`에 다음 테스트를 추가한다.

```swift
func testProviderRowDefaultsToShowingInUsageOverlay() {
    let row = ProviderRowState(
        id: .claude,
        name: "Claude OAuth",
        nickname: "",
        functionName: "cc",
        connectionTitle: "Connected",
        connectionDetail: "claude@example.com",
        isConnected: true
    )

    XCTAssertTrue(row.showsInUsageOverlay)
}

func testProviderRowsReflectUsageOverlayHiddenAccountIDs() {
    var config = AppConfig.default
    config.usageOverlay.hiddenAccountIDs = [ProviderRowState.ID.codex.rawValue]
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.showsInUsageOverlay, false)
}
```

- [ ] **Step 2: 테스트가 새 property 부재로 실패하는지 확인**

Run: `swift test --filter DashboardViewModelTests/testProviderRowsReflectUsageOverlayHiddenAccountIDs`

Expected: FAIL — `ProviderRowState`에 `showsInUsageOverlay`가 없다는 compile error

- [ ] **Step 3: `ProviderRowState`에 기본값이 있는 property 추가**

```swift
let showsInUsageOverlay: Bool
```

initializer 마지막 parameter와 할당을 추가한다.

```swift
showsSubscriptionUsage: Bool = true,
showsInUsageOverlay: Bool = true
```

```swift
self.showsSubscriptionUsage = showsSubscriptionUsage
self.showsInUsageOverlay = showsInUsageOverlay
```

- [ ] **Step 4: ViewModel의 일관된 파생 helper 추가**

`DashboardViewModel`에 다음 private helper를 추가한다.

```swift
private func showsInUsageOverlay(_ id: ProviderRowState.ID) -> Bool {
    !config.usageOverlay.hiddenAccountIDs.contains(id.rawValue)
}
```

`rebuildProviderRows`의 모든 `ProviderRowState` 생성 지점에서 ID를 먼저 확정하고 다음 argument를 전달한다.

```swift
showsInUsageOverlay: showsInUsageOverlay(ProviderRowState.ID(rawValue: rowID))
```

```swift
showsInUsageOverlay: showsInUsageOverlay(ProviderRowState.ID(rawValue: commandProfile.id))
```

```swift
showsSubscriptionUsage: false,
showsInUsageOverlay: showsInUsageOverlay(.claudeAPI)
```

```swift
showsSubscriptionUsage: false,
showsInUsageOverlay: showsInUsageOverlay(.codexAPI)
```

- [ ] **Step 5: Provider 행 focused tests 실행**

Run: `swift test --filter DashboardViewModelTests/testProviderRowDefaultsToShowingInUsageOverlay`

Run: `swift test --filter DashboardViewModelTests/testProviderRowsReflectUsageOverlayHiddenAccountIDs`

Expected: 두 테스트 PASS

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/ProviderRowState.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: derive Usage HUD visibility for accounts"
```

---

### Task 3: 계정 표시 토글 저장과 rollback

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:150-160, 870-932, 2549-2594`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:340-482`

**Interfaces:**
- Consumes: `ProviderRowState.showsInUsageOverlay`, `AppConfig.UsageOverlay.hiddenAccountIDs`, 기존 `savePrivacyOnlyConfig(_:)`
- Produces: `DashboardViewModel.setAccountVisibleInUsageOverlay(_:isVisible:) throws`, 기능 전용 localized save error

- [ ] **Step 1: 숨김·재표시 저장 실패 테스트 작성**

```swift
func testSetAccountVisibleInUsageOverlayPersistsHiddenIDAndUpdatesRow() throws {
    var config = AppConfig.default
    let store = StubConfigStore(config: config)
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

    XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, ["claude"])
    XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, ["claude"])
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, false)

    try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: true)

    XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
    XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, [])
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
}
```

- [ ] **Step 2: no-op과 rollback 실패 테스트 작성**

```swift
func testSetAccountVisibleInUsageOverlaySkipsUnknownAndUnchangedAccounts() throws {
    let store = StubConfigStore(config: .default)
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: true)
    try viewModel.setAccountVisibleInUsageOverlay("missing", isVisible: false)

    XCTAssertEqual(store.savedConfigs, [])
}

func testSetAccountVisibleInUsageOverlayRollsBackWhenSaveFails() {
    let store = StubConfigStore(
        config: .default,
        saveError: NSError(
            domain: "UsageOverlayAccountVisibility",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Save failed"]
        )
    )
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    XCTAssertThrowsError(
        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)
    ) { error in
        XCTAssertEqual(
            error.localizedDescription,
            "Usage HUD account visibility could not be saved: Save failed"
        )
    }
    XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
    XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
    XCTAssertEqual(store.savedConfigs, [])
}
```

- [ ] **Step 3: 테스트가 API 부재로 실패하는지 확인**

Run: `swift test --filter DashboardViewModelRefreshTests/testSetAccountVisibleInUsageOverlayPersistsHiddenIDAndUpdatesRow`

Expected: FAIL — `DashboardViewModel`에 method가 없다는 compile error

- [ ] **Step 4: 기능 전용 error와 저장 API 구현**

`DashboardViewModel` 내부 error type 근처에 추가한다.

```swift
private struct UsageOverlayAccountVisibilitySaveError: LocalizedError {
    let underlyingError: Error

    var errorDescription: String? {
        "Usage HUD account visibility could not be saved: \(underlyingError.localizedDescription)"
    }
}
```

계정 이동 API 근처에 다음 method를 추가한다.

```swift
func setAccountVisibleInUsageOverlay(
    _ id: ProviderRowState.ID,
    isVisible: Bool
) throws {
    guard let row = providerRows.first(where: { $0.id == id }) else { return }
    guard row.showsInUsageOverlay != isVisible else { return }

    var updatedConfig = config
    if isVisible {
        updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == id.rawValue }
    } else if !updatedConfig.usageOverlay.hiddenAccountIDs.contains(id.rawValue) {
        updatedConfig.usageOverlay.hiddenAccountIDs.append(id.rawValue)
    }

    do {
        try savePrivacyOnlyConfig(updatedConfig)
    } catch {
        throw UsageOverlayAccountVisibilitySaveError(underlyingError: error)
    }
}
```

`savePrivacyOnlyConfig`가 config와 provider 행을 미리 갱신하고 실패 시 이전 config로 rollback하므로 별도 optimistic state 구현은 추가하지 않는다.

- [ ] **Step 5: backend lifecycle 불변 테스트 작성**

```swift
func testSetAccountVisibleInUsageOverlayDoesNotChangeUsageBackendLifecycle() throws {
    var config = AppConfig.default
    config.usageOverlay.isVisible = true
    let proxyService = StubProxyServiceStarter()
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector(),
        subscriptionUsageKeyStore: keyStore,
        secretStore: InMemorySecretStore()
    )

    try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

    XCTAssertEqual(proxyService.restartPorts, [])
    XCTAssertEqual(keyStore.createCallCount, 0)
    XCTAssertEqual(keyStore.deleteCallCount, 0)
    XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
}
```

같은 단계에서 cached snapshot 유지 테스트를 추가한다.

```swift
func testSetAccountVisibleInUsageOverlayPreservesCachedSnapshot() throws {
    var config = AppConfig.default
    config.usageOverlay.isVisible = true
    let profile = AuthProfile(
        fileName: "claude.json",
        type: .claude,
        email: "claude@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )
    let snapshot = SubscriptionUsageSnapshot(
        profileID: profile.id,
        provider: .claude,
        windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 25, resetAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )
    let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [profile],
        subscriptionUsageSnapshotCache: cache
    )

    try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

    XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .available(snapshot))
    XCTAssertEqual(cache.load(), [profile.id: snapshot])
}
```

- [ ] **Step 6: ViewModel focused tests 실행**

Run: `swift test --filter DashboardViewModelRefreshTests/testSetAccountVisibleInUsageOverlay`

Expected: hide/show, no-op, rollback, backend lifecycle, cached snapshot 유지 테스트 PASS

- [ ] **Step 7: 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: save per-account Usage HUD visibility"
```

---

### Task 4: 계정 삭제 시 hidden ID 정리

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:1590-1607, 2405-2416`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:5240-5302`

**Interfaces:**
- Consumes: Task 1의 `hiddenAccountIDs`, 기존 OAuth/API key 삭제 transaction
- Produces: 삭제된 OAuth/API key ID가 hidden 목록에 남지 않는 수명주기

- [ ] **Step 1: OAuth 삭제 정리 실패 테스트 작성**

기존 `testDeletingAccountRemovesItsIDAndPreservesSurvivorOrder`의 config와 assertion을 다음처럼 확장한다.

```swift
config.accountOrder = ["c", "b", "a"]
config.usageOverlay.hiddenAccountIDs = ["b", "c"]
```

삭제 후 assertion을 추가한다.

```swift
XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, ["c"])
XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, ["c"])
```

- [ ] **Step 2: API key 삭제·재등록 기본 표시 실패 테스트 작성**

기존 `testAPIKeyReRegistrationAppendsAfterSurvivingAccounts`에 다음 초기 상태를 추가한다.

```swift
config.usageOverlay.hiddenAccountIDs = [ProviderRowState.ID.claudeAPI.rawValue]
```

`removeAPIProvider` 호출 직후 assertion을 추가한다.

```swift
XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, [])
```

재등록 후 assertion을 추가한다.

```swift
XCTAssertEqual(viewModel.providerRows.first { $0.id == .claudeAPI }?.showsInUsageOverlay, true)
```

- [ ] **Step 3: 현재 구현에서 hidden ID가 남아 테스트가 실패하는지 확인**

Run: `swift test --filter DashboardViewModelTests/testDeletingAccountRemovesItsIDAndPreservesSurvivorOrder`

Run: `swift test --filter DashboardViewModelTests/testAPIKeyReRegistrationAppendsAfterSurvivingAccounts`

Expected: FAIL — 삭제 후 hidden ID가 남음

- [ ] **Step 4: OAuth 설정 초기화 transaction에 hidden ID 제거 추가**

`resetProviderSettings(_:)`에서 `updatedConfig`를 만든 직후 추가한다.

```swift
updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == provider.rawValue }
```

OAuth command profile 존재 여부와 무관하게 같은 정리가 적용되도록 `if let index`보다 앞에 둔다.

- [ ] **Step 5: API key 삭제 transaction에 hidden ID 제거 추가**

`removeAPIProvider(_:)`의 `withAPIKeyTransaction` closure에서 `updatedConfig`를 만든 직후 추가한다.

```swift
updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == provider.rawValue }
```

command name 정리와 같은 `saveConfig` 호출에서 저장되도록 별도 save를 만들지 않는다.

- [ ] **Step 6: 삭제 수명주기 focused tests 실행**

Run: `swift test --filter DashboardViewModelTests/testDeletingAccountRemovesItsIDAndPreservesSurvivorOrder`

Run: `swift test --filter DashboardViewModelTests/testAPIKeyReRegistrationAppendsAfterSurvivingAccounts`

Expected: 두 테스트 PASS

- [ ] **Step 7: 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "fix: clear HUD visibility when removing accounts"
```

---

### Task 5: 메인 계정 카드 HUD 버튼

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift:3-50`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:69-108, 627-878`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift:4-184`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift`

**Interfaces:**
- Consumes: `ProviderRowState.showsInUsageOverlay`, `DashboardViewModel.setAccountVisibleInUsageOverlay(_:isVisible:)`
- Produces: `DashboardAccountSnapshot.showsInUsageOverlay`, `UsageOverlayAccountButtonPresentation`, 모든 카드 상태의 상시 HUD 버튼

- [ ] **Step 1: snapshot과 버튼 presentation 실패 테스트 작성**

`DashboardAccountSnapshotTests`에 추가한다.

```swift
func testAccountSnapshotPreservesUsageOverlayVisibility() {
    let row = ProviderRowState(
        id: .claude,
        name: "Claude OAuth",
        nickname: "",
        functionName: "cc",
        connectionTitle: "Connected",
        connectionDetail: "claude@example.com",
        isConnected: true,
        showsInUsageOverlay: false
    )

    let snapshot = DashboardAccountSnapshot(provider: row)

    XCTAssertFalse(snapshot.showsInUsageOverlay)
    XCTAssertEqual(snapshot.usageOverlayButtonPresentation.symbolName, "chart.bar.xaxis")
    XCTAssertEqual(snapshot.usageOverlayButtonPresentation.accessibilityLabel, "Show in Usage HUD")
    XCTAssertFalse(snapshot.usageOverlayButtonPresentation.isHighlighted)
}

func testVisibleHUDAccountButtonPresentationOffersHideAction() {
    let presentation = UsageOverlayAccountButtonPresentation(showsInUsageOverlay: true)

    XCTAssertEqual(presentation.symbolName, "chart.bar.xaxis")
    XCTAssertEqual(presentation.accessibilityLabel, "Hide from Usage HUD")
    XCTAssertTrue(presentation.isHighlighted)
}
```

- [ ] **Step 2: 테스트가 새 snapshot API 부재로 실패하는지 확인**

Run: `swift test --filter DashboardAccountSnapshotTests/testAccountSnapshotPreservesUsageOverlayVisibility`

Expected: FAIL — snapshot property와 presentation type 부재

- [ ] **Step 3: 버튼 presentation과 snapshot property 구현**

`DashboardAccountSnapshot.swift`에 추가한다.

```swift
struct UsageOverlayAccountButtonPresentation: Equatable {
    let symbolName = "chart.bar.xaxis"
    let accessibilityLabel: String
    let isHighlighted: Bool

    init(showsInUsageOverlay: Bool) {
        accessibilityLabel = showsInUsageOverlay
            ? "Hide from Usage HUD"
            : "Show in Usage HUD"
        isHighlighted = showsInUsageOverlay
    }
}
```

`DashboardAccountSnapshot`에 property와 computed presentation을 추가한다.

```swift
let showsInUsageOverlay: Bool

var usageOverlayButtonPresentation: UsageOverlayAccountButtonPresentation {
    UsageOverlayAccountButtonPresentation(showsInUsageOverlay: showsInUsageOverlay)
}
```

initializer에 다음 할당을 추가한다.

```swift
showsInUsageOverlay = provider.showsInUsageOverlay
```

- [ ] **Step 4: 카드 UI 구조 실패 테스트 파일 작성**

`Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift`를 생성한다.

```swift
import Foundation
import XCTest

final class UsageOverlayAccountVisibilityUITests: XCTestCase {
    func testDashboardProvidesPersistentUsageHUDButtonAndSaveAction() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var usageOverlayButton"))
        XCTAssertTrue(source.contains("account.usageOverlayButtonPresentation"))
        XCTAssertTrue(source.contains("setAccountVisibleInUsageOverlay"))
        XCTAssertTrue(source.contains("isVisible: !account.showsInUsageOverlay"))
        XCTAssertTrue(source.contains(".frame(width: 26, height: 26)"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 5: `DashboardView`에서 toggle closure 연결**

`ProviderAccountCardView` 호출에 다음 closure를 추가한다.

```swift
toggleUsageOverlayVisibility: {
    viewModel.saveSetting {
        try viewModel.setAccountVisibleInUsageOverlay(
            account.id,
            isVisible: !account.showsInUsageOverlay
        )
    }
},
```

`ProviderAccountCardView` stored closure에 추가한다.

```swift
let toggleUsageOverlayVisibility: () -> Void
```

- [ ] **Step 6: 공통 HUD 버튼 구현 후 세 상태 action에 삽입**

`ProviderAccountCardView`에 다음 view를 추가한다.

```swift
private var usageOverlayButton: some View {
    let presentation = account.usageOverlayButtonPresentation
    return Button(action: toggleUsageOverlayVisibility) {
        Image(systemName: presentation.symbolName)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .foregroundStyle(
                presentation.isHighlighted
                    ? BrandPalette.accent
                    : Color.primary.opacity(0.55)
            )
            .background {
                if presentation.isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(BrandPalette.accent.opacity(0.12))
                }
            }
    }
    .buttonStyle(.plain)
    .help(presentation.accessibilityLabel)
    .accessibilityLabel(presentation.accessibilityLabel)
}
```

`actions`의 Connected, Disabled, Disconnected 분기에 이미 존재하는 각 `HStack(spacing: 4)`의 첫 child로 `usageOverlayButton`을 삽입한다. 기존 Settings, Connect, More menu 순서는 유지하여 결과가 각각 다음 순서가 되게 한다.

```text
Connected:    usageOverlayButton, Settings, More
Disabled:     usageOverlayButton, Settings, More
Disconnected: usageOverlayButton, Connect, More
```

- [ ] **Step 7: 카드 focused tests 실행**

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Expected: 모든 snapshot 및 source 구조 테스트 PASS

- [ ] **Step 8: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift
git commit -m "feat: add Usage HUD toggle to account cards"
```

---

### Task 6: HUD 필터와 빈 상태 presentation

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:4-58, 93-125, 215-247`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:4-23`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountPresentationTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift:409-483`

**Interfaces:**
- Consumes: `ProviderRowState.showsInUsageOverlay`, 기존 `MenuBarStatusSnapshot`
- Produces: `UsageOverlayAccountPresentation.providers`, `UsageOverlayAccountPresentation.emptyMessage`, Expanded/Compact 공통 필터 결과

- [ ] **Step 1: HUD 필터와 순서 실패 테스트 작성**

`UsageOverlayAccountPresentationTests.swift`를 생성한다.

```swift
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class UsageOverlayAccountPresentationTests: XCTestCase {
    func testPresentationFiltersHiddenAccountsAndPreservesSelectedOrder() {
        let presentation = makePresentation(rows: [
            row(id: "first", showsInUsageOverlay: true),
            row(id: "hidden", showsInUsageOverlay: false),
            row(id: "last", showsInUsageOverlay: true)
        ])

        XCTAssertEqual(presentation.providers.map(\.id.rawValue), ["first", "last"])
        XCTAssertNil(presentation.emptyMessage)
    }

    func testPresentationKeepsSelectedAPIKeyAccount() {
        let presentation = makePresentation(rows: [
            ProviderRowState(
                id: .claudeAPI,
                providerType: .claude,
                name: "Claude API Key",
                nickname: "API",
                functionName: "ccapi",
                connectionTitle: "Configured",
                connectionDetail: "CLIProxyAPI",
                isConnected: true,
                subscriptionUsageState: .disabled,
                showsSubscriptionUsage: false,
                showsInUsageOverlay: true
            )
        ])

        XCTAssertEqual(presentation.providers.map(\.id), [.claudeAPI])
    }

    private func makePresentation(rows: [ProviderRowState]) -> UsageOverlayAccountPresentation {
        UsageOverlayAccountPresentation(
            serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
            serverControlState: .running,
            providerRows: rows,
            port: 18_317
        )
    }

    private func row(
        id: ProviderRowState.ID,
        isConnected: Bool = true,
        isDisabled: Bool = false,
        showsInUsageOverlay: Bool
    ) -> ProviderRowState {
        ProviderRowState(
            id: id,
            name: "Claude OAuth",
            nickname: id.rawValue,
            functionName: "cmd-\(id.rawValue)",
            connectionTitle: isDisabled ? "Disabled" : isConnected ? "Connected" : "Disconnected",
            connectionDetail: "account@example.com",
            isConnected: isConnected,
            isDisabled: isDisabled,
            showsInUsageOverlay: showsInUsageOverlay
        )
    }
}
```

- [ ] **Step 2: 빈 상태 실패 테스트 추가**

같은 test class에 추가한다.

```swift
func testPresentationShowsNoAccountsSelectedWhenAllRegisteredAccountsAreHidden() {
    let presentation = makePresentation(rows: [
        row(id: "hidden", showsInUsageOverlay: false)
    ])

    XCTAssertEqual(presentation.providers, [])
    XCTAssertEqual(presentation.emptyMessage, "No accounts selected")
}

func testPresentationShowsNoConnectedAccountsWhenSelectedAccountsAreUnavailable() {
    let presentation = makePresentation(rows: [
        row(id: "disabled", isConnected: false, isDisabled: true, showsInUsageOverlay: true),
        row(id: "disconnected", isConnected: false, showsInUsageOverlay: true)
    ])

    XCTAssertEqual(presentation.providers, [])
    XCTAssertEqual(presentation.emptyMessage, "No connected accounts")
}

func testPresentationKeepsExistingEmptyCopyWhenNoAccountsAreRegistered() {
    let presentation = makePresentation(rows: [])

    XCTAssertEqual(presentation.providers, [])
    XCTAssertEqual(presentation.emptyMessage, "No connected accounts")
}
```

- [ ] **Step 3: 테스트가 새 presentation type 부재로 실패하는지 확인**

Run: `swift test --filter UsageOverlayAccountPresentationTests`

Expected: FAIL — `UsageOverlayAccountPresentation` type 부재

- [ ] **Step 4: HUD 전용 presentation model 구현**

`Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift`를 생성한다.

```swift
import CLIProxyManagerCore

struct UsageOverlayAccountPresentation: Equatable {
    let providers: [MenuBarConnectedProvider]
    let emptyMessage: String?

    init(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState,
        providerRows: [ProviderRowState],
        port: Int
    ) {
        let selectedRows = providerRows.filter(\.showsInUsageOverlay)
        let connectedProviders = MenuBarStatusSnapshot(
            serverStatus: serverStatus,
            serverControlState: serverControlState,
            providers: selectedRows,
            port: port,
            showsSubscriptionUsage: true
        ).connectedProviders
        self.providers = connectedProviders

        if !providerRows.isEmpty, selectedRows.isEmpty {
            emptyMessage = "No accounts selected"
        } else if connectedProviders.isEmpty {
            emptyMessage = "No connected accounts"
        } else {
            emptyMessage = nil
        }
    }
}
```

- [ ] **Step 5: 메뉴바가 hidden property를 무시하는 회귀 테스트 추가**

`MenuBarStatusSnapshotTests`에 추가한다.

```swift
func testMenuBarSnapshotIgnoresUsageOverlayVisibility() {
    let provider = ProviderRowState(
        id: .claude,
        name: "Claude OAuth",
        nickname: "Work",
        functionName: "cc-work",
        connectionTitle: "Connected",
        connectionDetail: "work@example.com",
        isConnected: true,
        showsInUsageOverlay: false
    )

    let snapshot = MenuBarStatusSnapshot(
        serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
        providers: [provider]
    )

    XCTAssertEqual(snapshot.connectedProviders.map(\.id), [.claude])
}
```

- [ ] **Step 6: `UsageOverlayView`를 presentation model에 연결**

기존 `providers` computed property를 다음 property로 교체한다.

```swift
private var accountPresentation: UsageOverlayAccountPresentation {
    UsageOverlayAccountPresentation(
        serverStatus: viewModel.serverStatus,
        serverControlState: viewModel.serverControlState,
        providerRows: viewModel.providerRows,
        port: viewModel.config.port
    )
}
```

Expanded content 호출을 다음처럼 변경한다.

```swift
ExpandedUsageOverlayContent(
    providers: accountPresentation.providers,
    emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
    refreshStatus: refreshStatus
)
```

Compact content의 visible/measurement 두 호출을 모두 다음처럼 변경한다.

```swift
CompactUsageOverlayView(
    providers: accountPresentation.providers,
    emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
    maximumAccountHeight: presentationState.compactAccountMaximumHeight,
    onMeasurementChange: recordCompactAccountHeight
)
```

`ExpandedUsageOverlayContent`에 property를 추가한다.

```swift
let emptyMessage: String
```

호출부에서 optional을 제거하기 위해 전달할 때 `accountPresentation.emptyMessage ?? "No connected accounts"`를 사용하고, 빈 provider branch를 다음처럼 변경한다.

```swift
Text(emptyMessage)
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
```

- [ ] **Step 7: Compact empty copy와 여러 줄 표시 구현**

`CompactUsageOverlayView` stored property를 추가한다.

```swift
let emptyMessage: String
```

기존 `Text("No accounts")`를 교체한다.

```swift
Text(emptyMessage)
    .font(.system(size: 9.5, weight: .medium))
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
```

모든 initializer call은 Step 6에서 명시적으로 값을 전달하므로 default argument는 추가하지 않는다.

- [ ] **Step 8: HUD 및 메뉴바 focused tests 실행**

Run: `swift test --filter UsageOverlayAccountPresentationTests`

Run: `swift test --filter MenuBarStatusSnapshotTests/testMenuBarSnapshotIgnoresUsageOverlayVisibility`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Expected: 필터, 빈 상태, 메뉴바 독립성, compact provider ID 측정 회귀 테스트 PASS

- [ ] **Step 9: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountPresentationTests.swift Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift
git commit -m "feat: filter accounts shown in Usage HUD"
```

---

### Task 7: 사용자 문서 갱신

**Files:**
- Modify: `README.md:61-70`
- Modify: `README.en.md:61-70`

**Interfaces:**
- Consumes: Task 5~6에서 완성된 메인 카드 버튼과 HUD 동작
- Produces: 현재 Usage 설정 위치와 계정별 HUD 표시 관리 방법을 설명하는 한국어·영어 문서

- [ ] **Step 1: 한국어 Usage HUD 설명 갱신**

`README.md`의 Usage HUD 첫 문단을 현재 설정 구조에 맞게 교체한다.

```markdown
**Settings → Usage**에서 메뉴바 사용량과 별도 Usage HUD 표시를 각각 설정할 수 있습니다.
```

기존 bullet에 다음 항목을 추가한다.

```markdown
- 메인 화면의 각 계정 카드에서 Usage HUD 버튼을 눌러 HUD에 표시할 계정을 선택할 수 있습니다. 선택은 전체 보기와 compact 보기에 함께 적용되고 앱 재실행 후에도 유지됩니다.
```

- [ ] **Step 2: 영어 Usage HUD 설명 갱신**

`README.en.md`의 첫 문단을 교체한다.

```markdown
Use **Settings → Usage** to configure subscription usage in the menu bar and the separate Usage HUD independently.
```

기존 bullet에 다음 항목을 추가한다.

```markdown
- Use the Usage HUD button on each account card in the main window to choose which accounts appear in the HUD. The selection applies to both full and compact views and is restored after relaunch.
```

- [ ] **Step 3: 문서 diff 검사**

Run: `git diff --check -- README.md README.en.md`

Expected: 출력 없음

- [ ] **Step 4: 커밋**

```bash
git add README.md README.en.md
git commit -m "docs: explain Usage HUD account selection"
```

---

### Task 8: 전체 회귀 테스트와 development app bundle 검증

**Files:**
- 없음 — 검증 전용 task

**Interfaces:**
- Consumes: Task 1~7의 모든 변경사항
- Produces: 통과한 전체 테스트 스위트, 검증된 development app bundle, 사용자 수동 확인 목록

- [ ] **Step 1: HUD 기능 focused tests 일괄 실행**

Run: `swift test --filter AppConfigTests`

Run: `swift test --filter DashboardViewModelRefreshTests/testSetAccountVisibleInUsageOverlay`

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Run: `swift test --filter UsageOverlayAccountPresentationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Expected: 모든 focused test PASS

- [ ] **Step 2: 전체 테스트 스위트 실행**

Run: `swift test`

Expected: 모든 테스트 PASS, 0 failures

실패가 발생하면 완료를 주장하지 말고 `superpowers:systematic-debugging`을 사용해 원인을 확인한 뒤 해당 task의 red-green cycle로 돌아간다.

- [ ] **Step 3: development app bundle 빌드**

Run: `make bundle`

Expected: `Bundled build/CLIProxyManager.app` 출력, build error 없음

- [ ] **Step 4: local code signing과 bundle 검증**

Run: `make verify`

Expected: `codesign verification passed` 출력

- [ ] **Step 5: clean worktree 확인**

Run: `git status --short --branch`

Expected: 현재 branch header만 출력되고 변경 파일 없음

- [ ] **Step 6: 사용자 수동 확인 항목 안내**

자동으로 앱을 실행하지 않는다. 사용자에게 development app에서 다음을 확인하도록 안내한다.

1. Connected, Disabled, Disconnected 카드 모두에 `chart.bar.xaxis` 버튼이 표시되는지 확인한다.
2. 기존 account privacy `eye` 버튼과 HUD 버튼의 역할이 명확히 구분되는지 확인한다.
3. 버튼을 눌렀을 때 Expanded와 Compact HUD에서 해당 계정이 즉시 사라지거나 다시 나타나는지 확인한다.
4. 계정을 숨긴 뒤 compact HUD가 남는 빈 공간 없이 높이를 다시 맞추는지 확인한다.
5. 모든 계정을 숨겼을 때 HUD chrome은 남고 `No accounts selected`가 표시되는지 확인한다.
6. 선택된 계정이 모두 disabled/disconnected이면 `No connected accounts`가 표시되는지 확인한다.
7. 메뉴바에는 HUD에서 숨긴 계정도 계속 표시되는지 확인한다.
8. 앱 재실행 후 계정 선택 상태가 복원되는지 확인한다.
9. 숨긴 계정을 삭제한 뒤 다시 등록하면 기본 표시 상태로 돌아오는지 확인한다.

- [ ] **Step 7: 구현 커밋 순서 확인**

Run: `git log --oneline -7`

Expected: config 저장, provider 투영, 표시 토글, 삭제 정리, 카드 버튼, HUD 필터, README 갱신에 대응하는 Task 1~7 커밋이 최신 순서로 존재한다. 검증 중 수정이 필요해지면 이 task에서 catch-all commit을 만들지 말고, 원래 요구사항을 소유한 task로 돌아가 대응 테스트를 먼저 실패시킨 뒤 수정·검증·커밋한다.
