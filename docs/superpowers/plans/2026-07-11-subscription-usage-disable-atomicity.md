# Subscription Usage Disable Atomicity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Config 저장 실패가 구독 사용량 활성화 상태와 management key를 불일치시키지 않으며, 서버 중지 후 마지막 성공 사용량을 유지한다.

**Architecture:** `DashboardViewModel`에서 구독 사용량을 비활성화하거나 전체 설정을 초기화할 때 config를 먼저 영속화하고, 성공 후에만 polling을 취소하고 management key를 삭제한다. key 삭제가 실패해도 비활성 config는 유지하고 기존 앱 시작 정리 경로가 재시도한다. 일반 `refresh()`는 계속 사용량 요청을 시작하지 않아 서버 중지 후 cache를 보존한다.

**Tech Stack:** Swift 6, SwiftUI/Combine, XCTest, Swift Package Manager

## Global Constraints

- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`의 기존 미커밋 변경은 사용자 작업이므로 보존한다.
- 마지막 성공 usage snapshot은 서버가 ready가 아니어도 표시하며, 새 management API 요청은 보내지 않는다.
- Key, OAuth token, credential 값을 로그·테스트 실패 메시지·UI에 노출하지 않는다.
- Key 삭제 실패는 비활성 config를 rollback하지 않으며 다음 `prepareSubscriptionUsage()`에서 stale key 정리를 재시도한다.
- production과 DEBUG 모두 기존 `ManagedPaths` 및 `SubscriptionUsageManagementKeyConfiguring` 인터페이스를 유지한다.

---

## 파일 구조

- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - 비활성화/reset transaction 순서를 config-first로 전환하고 key cleanup 실패 메시지를 구분한다.
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - config 저장 실패 시 key·상태가 보존되는 회귀 테스트, key 삭제 실패 시 비활성 config 보존 테스트, 서버 중지 cache 보존 테스트를 추가한다.

### Task 1: 비활성화와 reset의 config-first transaction

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:283-360`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:1850-1995`

**Interfaces:**
- Consumes: `saveConfig(_:,validateShellFunctions:shellProfileValidationNames:preservingUnavailableRoundRobinProfiles:) throws`, `SubscriptionUsageManagementKeyConfiguring.deleteManagementKey() throws`, `cancelSubscriptionUsageWork()`, `setSubscriptionUsageStates(_:profileIDs:)`.
- Produces: `saveSubscriptionUsageEnabled(false)`가 config 저장 실패 시 key와 usage state를 보존하고, key 삭제 실패 시 비활성 config를 보존한다. `resetAllSettings()`도 같은 규칙을 적용한다.

- [ ] **Step 1: 비활성화 config 저장 실패 회귀 테스트를 작성한다**

`DashboardViewModelRefreshTests`에 다음 테스트를 추가한다.

```swift
func testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails() {
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(
            config: config,
            saveError: NSError(domain: "SubscriptionUsage", code: 1)
        ),
        keyStore: keyStore,
        proxyService: StubProxyServiceStarter()
    )

    XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(false))

    XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
    XCTAssertTrue(keyStore.isConfigured())
    XCTAssertEqual(keyStore.deleteCallCount, 0)
}
```

- [ ] **Step 2: 실패를 확인한다**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests.testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails
```

Expected: `XCTAssertTrue`가 실패한다. 현재 구현은 `saveConfig` 이전에 `deleteManagementKey()`를 실행한다.

- [ ] **Step 3: reset config 저장 실패 회귀 테스트를 작성한다**

동일 테스트 클래스에 다음 테스트를 추가한다.

```swift
func testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails() {
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(
            config: config,
            saveError: NSError(domain: "SubscriptionUsage", code: 1)
        ),
        keyStore: keyStore,
        proxyService: StubProxyServiceStarter()
    )

    viewModel.resetAllSettings()

    XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
    XCTAssertTrue(keyStore.isConfigured())
    XCTAssertEqual(keyStore.deleteCallCount, 0)
    XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Reset failed:") == true)
}
```

- [ ] **Step 4: 실패를 확인한다**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests.testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails
```

Expected: `XCTAssertTrue`가 실패한다. 현재 구현은 reset config를 저장하기 전에 key를 삭제한다.

- [ ] **Step 5: key 삭제 실패 동작을 지원하도록 test double을 확장한다**

`SubscriptionUsageManagementKeyDouble`에 삭제 오류와 호출 기록을 추가한다.

```swift
var deleteError: Error?

func deleteManagementKey() throws {
    deleteCallCount += 1
    if let deleteError {
        throw deleteError
    }
    isConfiguredValue = false
}
```

기존 `deleteManagementKey()` 구현을 위 코드로 교체한다. 다른 test double API와 `isConfigured()` 동작은 바꾸지 않는다.

- [ ] **Step 6: key 삭제 실패의 비활성 config 보존 테스트를 작성한다**

```swift
func testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails() {
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    let configStore = StubConfigStore(config: config)
    let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    keyStore.deleteError = NSError(domain: "SubscriptionUsage", code: 2)
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: configStore,
        keyStore: keyStore,
        proxyService: StubProxyServiceStarter()
    )

    XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(false))

    XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
    XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? true)
    XCTAssertTrue(keyStore.isConfigured())
    XCTAssertEqual(keyStore.deleteCallCount, 1)
}
```

- [ ] **Step 7: `saveSubscriptionUsageEnabled(false)`를 config-first 순서로 구현한다**

`DashboardViewModel.swift`의 `else` 블록을 아래처럼 교체한다.

```swift
} else {
    var updatedConfig = config
    updatedConfig.subscriptionUsage.isEnabled = false
    try saveConfig(updatedConfig)
    cancelSubscriptionUsageWork()
    try subscriptionUsageKeyStore.deleteManagementKey()
    setSubscriptionUsageStates(.disabled)
}
```

이 순서는 config 저장 실패 시 key·polling·마지막 snapshot을 변경하지 않는다. key 삭제 실패는 `saveConfig`가 반영한 비활성 config를 rollback하지 않고 호출자에게 throw한다.

- [ ] **Step 8: `resetAllSettings()`를 config-first 순서로 구현한다**

`resetAllSettings()`의 `do` 블록에서 key 삭제를 `saveConfig(updatedConfig)` 뒤로 옮기고, key cleanup이 필요한 경우에만 수행한다.

```swift
do {
    let shouldDeleteManagementKey = config.subscriptionUsage.isEnabled || subscriptionUsageKeyStore.isConfigured()
    try saveConfig(updatedConfig)
    if shouldDeleteManagementKey {
        cancelSubscriptionUsageWork()
        try subscriptionUsageKeyStore.deleteManagementKey()
    }
    setSubscriptionUsageStates(.disabled)
    appAppearanceService.apply(showDockIcon: updatedConfig.showDockIcon)
    appAppearanceService.apply(appearance: updatedConfig.appearance)
    settingsMessage = "Settings reset to defaults."
    if serverControlState.isRunning {
        Task { [weak self] in
            await self?.restartServer()
        }
    }
} catch {
    settingsMessage = "Reset failed: \(error.localizedDescription)"
}
```

`saveConfig` 실패 시 `config`와 key는 둘 다 원래 상태로 남는다. key 삭제 실패 시 config는 이미 default로 남고 reset 실패 메시지를 표시한다.

- [ ] **Step 9: 새 transaction 테스트와 기존 관련 테스트를 실행한다**

Run:

```bash
swift test --filter 'DashboardViewModelRefreshTests.(testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails|testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails|testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails|testDisablingSubscriptionUsageDeletesKeyPersistsDisabledConfigAndRestartsProxy|testResetAllSettingsDeletesManagementKeyWhenUsageWasEnabled)'
```

Expected: 선택된 모든 XCTest가 `0 failures`로 통과한다.

- [ ] **Step 10: Commit한다**

사용자의 기존 미커밋 forced-refresh 테스트 변경을 stage하지 않는다. 이 task에서 수정한 소스와 테스트 hunk만 stage한 뒤 commit한다.

```bash
git add -p Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "fix: preserve subscription key on config save failure"
```

Expected: commit에는 transaction 순서와 새 회귀 테스트만 포함된다.

### Task 2: 서버 중지 뒤 usage cache 보존 회귀 테스트

**Files:**
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:2000-2410`

**Interfaces:**
- Consumes: `DashboardViewModel.refresh() async`, `subscriptionUsageStates`, `SubscriptionQuotaFetching.fetchUsage(port:profiles:) async`.
- Produces: server 상태를 warning으로 갱신하는 일반 refresh가 usage snapshot을 덮어쓰지 않고 quota fetch를 시작하지 않는다는 테스트 보장.

- [ ] **Step 1: 서버 중지 cache 보존 테스트를 작성한다**

`DashboardViewModelRefreshTests`에 다음 테스트를 추가한다.

```swift
func testRefreshAfterServerStopsPreservesLastUsageWithoutFetchingAgain() async {
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    let profile = AuthProfile(
        fileName: "claude.json",
        type: .claude,
        email: "claude@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )
    let initialUsage = availableUsageState(for: profile)
    let quotaClient = RecordingSubscriptionQuotaClient(reports: [
        SubscriptionUsageReport(
            statesByProfileID: [profile.id: initialUsage],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    ])
    let stoppedHealthClient = ProxyHealthClient(
        httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))
    )
    let viewModel = DashboardViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [profile]),
        oauthLoginService: StubOAuthLoginService(),
        proxyHealthClient: stoppedHealthClient,
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        subscriptionQuotaClient: quotaClient,
        subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
    )
    viewModel.serverStatus = readyStatus()
    await viewModel.refreshSubscriptionUsage()

    await viewModel.refresh()

    XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], initialUsage)
    let fetchCallCount = await quotaClient.fetchCallCount()
    XCTAssertEqual(fetchCallCount, 1)
    XCTAssertFalse(viewModel.canRefreshSubscriptionUsage)
}
```

The test seeds `private(set) subscriptionUsageStates` through the public usage-refresh behavior, then changes only server health via `refresh()`. Do not make the production property writable merely for the test.

- [ ] **Step 2: 테스트를 실행해 현재 정책을 검증한다**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests.testRefreshAfterServerStopsPreservesLastUsageWithoutFetchingAgain
```

Expected: PASS. `refresh()` does not call `refreshSubscriptionUsage()`, so the call count stays zero and the existing snapshot remains unchanged.

- [ ] **Step 3: full focused usage test set를 실행한다**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests
```

Expected: all selected XCTest cases pass. If the known full-suite runner stall occurs, report it separately; do not reinterpret a stalled process as a passing full suite.

- [ ] **Step 4: Commit한다**

사용자 기존 forced-refresh 테스트 hunk를 stage하지 않고 cache regression test hunk만 stage한다.

```bash
git add -p Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "test: preserve subscription usage cache while stopped"
```

Expected: commit에는 서버 중지 cache regression test만 포함된다.

## 최종 검증

- [ ] **Step 1: 변경 파일과 커밋 범위를 확인한다**

Run:

```bash
git status --short
git diff --check
git log --oneline -2
```

Expected: whitespace 오류가 없고, 사용자의 기존 미커밋 forced-refresh test 변경은 남아 있으며, 새 commits는 해당 수정만 포함한다.

- [ ] **Step 2: 핵심 테스트를 실행한다**

Run:

```bash
swift test --filter 'DashboardViewModelRefreshTests|SubscriptionUsageManagementKeyFileStoreTests'
```

Expected: 선택된 모든 XCTest가 `0 failures`로 통과한다.

- [ ] **Step 3: 결과를 보고한다**

다음을 명시한다.

- config 저장 실패 시 활성 config와 key가 함께 보존됨
- key 삭제 실패 시 비활성 config는 유지되고 다음 시작 정리가 재시도함
- 서버 중지 후 마지막 usage snapshot은 유지되고 새 API 호출은 없음
- 실행한 테스트 명령과 실제 결과
- 의도적으로 보존한 사용자 미커밋 변경 파일
