# 구독 사용량 자동화 및 메뉴바 진행률 표시 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Management key를 자동 수명주기로 관리하고 Claude/Codex 사용량을 캐시·폴링하며 메뉴바에 계정별 상세 진행률 바로 표시한다.

**Architecture:** Core의 Keychain store가 키의 안전한 생성·조회·삭제를 담당한다. `DashboardViewModel`이 토글, 시작 복구, proxy 재시작, single-flight 조회와 계정별 polling을 담당하며, 메뉴바는 캐시된 상태만 렌더링한다. Claude usage 요청은 자동 키가 실제 proxy config에 적용된 뒤에만 런타임에서 진단하고, 검증된 계약과 다를 때만 client를 수정한다.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, macOS Security framework, CLIProxyAPI loopback management API.

## Superseding storage decision (2026-07-11)

> This historical implementation plan originally specified Keychain storage. That storage decision has been superseded: subscription-usage management keys use the `0600` versioned JSON file `subscription-usage-management-key.json` under the active `ManagedPaths` root (`~/.cliproxy-manager/` for release and `~/.cliproxy-manager/dev/` for debug). Normal GUI, CLI, quota, and proxy paths must not read, migrate, or automatically delete the legacy Keychain item; it remains intentionally orphaned to prevent authentication prompts. Unrelated Claude API-key Keychain storage is unchanged.

## Global Constraints

- 지원 플랫폼은 macOS 15.0 이상이고 새 외부 의존성을 추가하지 않는다.
- management key, OAuth token, Bearer header, 관리 API request body를 UI·로그·테스트 오류·CLI 출력에 기록하지 않는다.
- Keychain 항목은 service `io.woosublee.CLIProxyManager`, account `subscription-usage-management-key`, 접근성 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`을 유지한다.
- proxy config는 사용량 활성화와 nonempty key가 동시에 만족될 때만 `remote-management.secret-key`를 포함하며 파일 권한 `0600`을 유지한다.
- GUI 토글 OFF는 Keychain의 동일 항목을 실제로 삭제한다. `cpm quota key set --stdin`, `status`, `delete`는 계속 지원한다.
- 성공 조회는 5분 후 재조회한다. transient failure는 1분부터 2배로 늘리고 최대 15분으로 제한한다. `SubscriptionUsageIssue.stopsPolling == true`인 계정은 이후 조회에서 제외하지만 나머지 계정의 polling은 유지한다.
- 메뉴바를 열어도 subscription usage 네트워크 요청을 시작하지 않는다.
- 진행률 색은 0–49% 파랑, 50–79% 주황, 80–100% 빨강이며 사용률·초기화 시각은 접근성 문자열로도 제공한다.

---

## File Structure

| 파일 | 책임 |
| --- | --- |
| `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift` | idempotent key 생성 protocol 계약 |
| `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageManagementKeyStore.swift` | Security 난수 key의 Keychain 수명주기 |
| `Tests/CLIProxyManagerCoreTests/SubscriptionUsageManagementKeyStoreTests.swift` | 격리 Keychain service로 key lifecycle 검증 |
| `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift` | `remote-management` 포함·제거와 권한 검증 |
| `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` | 자동 토글·시작 복구·조회 dedupe·polling·취소 |
| `Sources/CLIProxyManagerApp/Views/DashboardView.swift` | 앱 시작 때 lifecycle reconciliation 호출 |
| `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift` | 수동 key 입력 제거 |
| `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift` | progress 톤·색상·접근성 순수 helper |
| `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift` | 계정별 상세 progress bar 렌더링 |
| `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` | lifecycle, polling, cancellation test double와 회귀 테스트 |
| `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift` | progress presentation, privacy, accessibility 테스트 |
| `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift` | Claude/Codex request·error mapping 회귀 테스트 |
| `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift` | headless key 삭제의 비노출 regression |
| `README.md` | GUI 자동 lifecycle과 headless workflow 설명 |

## Task 1: Keychain 자동 생성 계약 구현

**Files:**
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift:110-118`
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageManagementKeyStore.swift:4-74`
- Create: `Tests/CLIProxyManagerCoreTests/SubscriptionUsageManagementKeyStoreTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift:87-101`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`의 `CommandManagementKeyStore`

**Interfaces:**
- Produces: `func createManagementKeyIfNeeded() throws -> Bool` — 새 key를 생성했으면 `true`, 기존 key를 보존했으면 `false`.
- Consumes: 기존 `setManagementKey(_:)`, `deleteManagementKey()`, internal `managementKey()`.

- [ ] **Step 1: 실제 사용자 Keychain과 격리된 failing test를 작성한다.**

```swift
import XCTest
@testable import CLIProxyManagerCore

final class SubscriptionUsageManagementKeyStoreTests: XCTestCase {
    func testCreateManagementKeyIfNeededCreatesPersistentKeyOnlyOnce() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        defer { try? store.deleteManagementKey() }

        XCTAssertFalse(store.isConfigured())
        XCTAssertTrue(try store.createManagementKeyIfNeeded())
        let first = try store.managementKey()
        XCTAssertGreaterThanOrEqual(first.count, 43)
        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), first)
    }

    func testCreateManagementKeyIfNeededPreservesExistingKey() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        defer { try? store.deleteManagementKey() }
        try store.setManagementKey("preexisting-test-key")

        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), "preexisting-test-key")
    }

    func testDeleteManagementKeyRemovesGeneratedKey() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        try store.createManagementKeyIfNeeded()
        try store.deleteManagementKey()

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
    }
}
```

- [ ] **Step 2: 새 API 부재로 test가 실패하는지 실행한다.**

Run: `swift test --filter SubscriptionUsageManagementKeyStoreTests`

Expected: `SubscriptionUsageManagementKeyStore`에 `createManagementKeyIfNeeded`가 없다는 컴파일 오류.

- [ ] **Step 3: protocol과 Security 난수 구현을 추가한다.**

`SubscriptionUsageManagementKeyConfiguring`에 다음 선언을 추가한다.

```swift
func createManagementKeyIfNeeded() throws -> Bool
```

`SubscriptionUsageManagementKeyStore`에 아래 구현을 추가한다. 저장은 기존 `setManagementKey`를 재사용하므로 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`이 유지된다.

```swift
public func createManagementKeyIfNeeded() throws -> Bool {
    guard !isConfigured() else { return false }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw SecretStoreError.writeFailed(account)
    }
    let key = Data(bytes)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    try setManagementKey(key)
    return true
}
```

`StubManagementKeyStore`와 `CommandManagementKeyStore`에는 test 전용 구현을 추가한다.

```swift
func createManagementKeyIfNeeded() throws -> Bool {
    guard key == nil else { return false }
    key = "generated-management-key"
    return true
}
```

- [ ] **Step 4: key lifecycle과 영향을 받은 Core tests를 실행한다.**

Run: `swift test --filter 'SubscriptionUsageManagementKeyStoreTests|CLIProxyAPISubscriptionQuotaClientTests|CLIProxyManagerCommandTests'`

Expected: 선택된 XCTest가 모두 통과하고 출력에 key 값이 없다.

- [ ] **Step 5: 이 단위를 커밋한다.**

```bash
git add Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift \
  Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageManagementKeyStore.swift \
  Tests/CLIProxyManagerCoreTests/SubscriptionUsageManagementKeyStoreTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "feat: generate subscription usage management keys"
```

## Task 2: Proxy config에 management API의 포함·제거를 고정한다

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift:57-76`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:507-528` (test가 드러낸 formatting 문제만)

**Interfaces:**
- Consumes: `ProxyServiceManager(... managementKeyProvider:, subscriptionUsageEnabledProvider:)`.
- Produces: enabled + nonempty key에서만 `remote-management:`와 `secret-key:`가 있는 `0600` config.

- [ ] **Step 1: disabled여도 stale key가 존재할 수 있는 회귀 test를 작성한다.**

```swift
func testStartOmitsManagementSecretWhenSubscriptionUsageIsDisabledEvenIfAKeyExists() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        managementKeyProvider: { "stored-management-key" },
        subscriptionUsageEnabledProvider: { false }
    )

    try await manager.start(port: 8317)

    let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertFalse(config.contains("remote-management:"))
    XCTAssertFalse(config.contains("secret-key:"))
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.clipProxyConfigFile.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
}
```

- [ ] **Step 2: 현재 조건이 test를 만족하는지 실행한다.**

Run: `swift test --filter ProxyServiceManagerTests/testStartOmitsManagementSecretWhenSubscriptionUsageIsDisabledEvenIfAKeyExists`

Expected: PASS. 기존 `subscriptionUsageEnabledProvider()` guard를 regression으로 고정한다.

- [ ] **Step 3: enabled + blank key도 secret을 렌더링하지 않는 test를 추가한다.**

```swift
func testStartOmitsManagementSecretWhenConfiguredKeyIsBlank() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        managementKeyProvider: { " \n " },
        subscriptionUsageEnabledProvider: { true }
    )

    try await manager.start(port: 8317)

    let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertFalse(config.contains("remote-management:"))
}
```

- [ ] **Step 4: proxy config group을 실행한다.**

Run: `swift test --filter ProxyServiceManagerTests`

Expected: 모든 `ProxyServiceManagerTests`가 통과한다.

- [ ] **Step 5: config lifecycle test를 커밋한다.**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "test: cover subscription usage management config lifecycle"
```

## Task 3: ViewModel 자동 lifecycle과 시작 복구를 구현한다

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:145-177,289-435,1721-1754`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:91-103`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:50-141`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: `func prepareSubscriptionUsage() async` — enabled + missing key 복구, disabled + stale key 정리, ready proxy의 최초 fetch.
- Produces: `func saveSubscriptionUsageEnabled(_ enabled: Bool) throws` — GUI lifecycle의 단일 진입점.
- Consumes: `createManagementKeyIfNeeded()`, `deleteManagementKey()`, `ProxyServiceControlling.restart(port:)`.

- [ ] **Step 1: lifecycle test double와 failing tests를 추가한다.**

기존 `DashboardViewModelTests.swift` private double 영역에 추가한다.

```swift
private final class SubscriptionUsageManagementKeyStoreDouble: SubscriptionUsageManagementKeyConfiguring, @unchecked Sendable {
    var isConfiguredValue = false
    var createCallCount = 0
    var deleteCallCount = 0
    var createError: Error?

    func isConfigured() -> Bool { isConfiguredValue }
    func createManagementKeyIfNeeded() throws -> Bool {
        createCallCount += 1
        if let createError { throw createError }
        guard !isConfiguredValue else { return false }
        isConfiguredValue = true
        return true
    }
    func setManagementKey(_ value: String) throws { isConfiguredValue = !value.isEmpty }
    func deleteManagementKey() throws { deleteCallCount += 1; isConfiguredValue = false }
}
```

다음 async tests를 작성한다. ready proxy fixture는 기존 `StubHTTPClient(result: .success(Data("{}".utf8)))`와 `StubProxyServiceStarter`를 사용한다.

```swift
func testEnablingSubscriptionUsageCreatesMissingKeyPersistsConfigAndRestartsReadyProxy() async throws
func testEnablingSubscriptionUsagePreservesExistingManagementKey() async throws
func testDisablingSubscriptionUsageDeletesKeyPersistsDisabledConfigAndRestartsProxy() async throws
func testPrepareSubscriptionUsageRepairsEnabledConfigWithMissingKeyBeforeFirstRefresh() async throws
func testPrepareSubscriptionUsageRemovesStaleKeyWhenUsageIsDisabled() async throws
func testResetAllSettingsDeletesManagementKeyWhenUsageWasEnabled() async throws
func testKeyCreationFailureLeavesSubscriptionUsageDisabled() async throws
```

Assertions: create/delete call count, `config.subscriptionUsage.isEnabled`, `StubConfigStore.savedConfigs`, `StubProxyServiceStarter.restartPorts`, safe `settingsMessage`를 검사한다. key 문자열은 assertion이나 failure message에 넣지 않는다.

- [ ] **Step 2: 새 lifecycle API 부재로 test가 실패하는지 실행한다.**

Run: `swift test --filter DashboardViewModelRefreshTests`

Expected: `prepareSubscriptionUsage` 미정의와 수동 lifecycle 동작 불일치로 실패한다.

- [ ] **Step 3: cancellation helper와 startup reconciliation을 추가한다.**

```swift
private func cancelSubscriptionUsageWork() {
    subscriptionUsageRefreshGeneration += 1
    subscriptionUsageRefreshTask?.cancel()
    subscriptionUsageRefreshTask = nil
    subscriptionUsagePollingTask?.cancel()
    subscriptionUsagePollingTask = nil
    subscriptionUsageRetryDelayNanoseconds = 60_000_000_000
}

func prepareSubscriptionUsage() async {
    do {
        if config.subscriptionUsage.isEnabled {
            let created = try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
            if created, serverControlState.isRunning {
                await restartServer()
                return
            }
        } else if subscriptionUsageKeyStore.isConfigured() {
            try subscriptionUsageKeyStore.deleteManagementKey()
        }
    } catch {
        settingsMessage = "Subscription usage setup failed: \(error.localizedDescription)"
        return
    }
    await refreshSubscriptionUsage()
}
```

`saveSubscriptionUsageEnabled(true)`는 key 생성 후 config를 저장한다. config save가 실패하고 이번 호출이 key를 생성했다면 `try? deleteManagementKey()`로 정리한 뒤 original error를 throw한다. enable 뒤 running proxy는 restart하고, stopped proxy는 `refreshSubscriptionUsage()`를 호출해 unavailable state를 즉시 표시한다.

`saveSubscriptionUsageEnabled(false)`는 `cancelSubscriptionUsageWork()`, `deleteManagementKey()`, config disabled 저장, `.disabled` state 적용 순서로 수행하고 running proxy를 restart한다. restart 실패는 key/config를 rollback하지 않고 existing `performServerAction` error를 표시한다.

`resetAllSettings()`도 `AppConfig.default`를 저장하기 전에 구독 사용량이 활성화됐거나 key가 남아 있으면 같은 `cancelSubscriptionUsageWork()`와 `deleteManagementKey()`를 실행한다. 삭제가 실패하면 reset을 중단하고 safe settings message를 표시한다. 삭제 후 저장된 default config는 usage disabled이므로 running proxy는 restart하여 `remote-management` block을 제거한다.

- [ ] **Step 4: 앱 시작과 Settings UI를 연결한다.**

`DashboardView`의 `.task`에서 `refresh()` 뒤, `performAutostartIfEnabled()` 전에 `await viewModel.prepareSubscriptionUsage()`를 호출한다. debug development bundle의 기본 데이터 root는 `ManagedPaths.defaultRootDirectory()`에 따라 `~/.cliproxy-manager/dev`이므로, runtime 검증에서도 이 경로를 사용한다.

`GeneralSettingsView`에서 `@State private var managementKey`, `Management key` SettingsRow, Save/Replace/Remove 버튼과 수동 key method 호출을 제거한다. toggle 설명을 아래로 교체한다.

```swift
"Displays Claude and Codex account usage in the menu bar. A local management key is created in Keychain automatically and removed when this setting is turned off."
```

- [ ] **Step 5: lifecycle 및 기존 ViewModel tests를 실행한다.**

Run: `swift test --filter DashboardViewModelRefreshTests`

Expected: 새 lifecycle tests와 기존 refresh tests가 모두 통과한다.

- [ ] **Step 6: 자동 lifecycle 단위를 커밋한다.**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: automate subscription usage key lifecycle"
```

## Task 4: Single-flight 조회와 계정별 polling을 구현한다

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:147-160,289-435,1721-1754`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: initializer injection `subscriptionUsageSleep: @escaping @Sendable (UInt64) async throws -> Void` with default `Task.sleep`.
- Produces: `refresh()` — health와 provider status만 갱신한다.
- Produces: `refreshSubscriptionUsage()` — in-flight task가 있으면 새 request를 만들지 않는다.
- Consumes: `SubscriptionUsageIssue.stopsPolling`.

- [ ] **Step 1: deterministic fetcher/sleeper와 failing test를 작성한다.**

```swift
private final class SubscriptionQuotaFetcherDouble: SubscriptionQuotaFetching, @unchecked Sendable {
    var reports: [SubscriptionUsageReport] = []
    private(set) var fetchCallCount = 0
    private(set) var requestedProfileIDs: [[String]] = []

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        fetchCallCount += 1
        requestedProfileIDs.append(profiles.map(\.id))
        return reports.removeFirst()
    }
}

private final class SuspendedSubscriptionQuotaFetcher: SubscriptionQuotaFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SubscriptionUsageReport, Never>?
    private var _fetchCallCount = 0

    var fetchCallCount: Int { lock.withLock { _fetchCallCount } }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await withCheckedContinuation { continuation in
            lock.withLock {
                _fetchCallCount += 1
                self.continuation = continuation
            }
        }
    }

    func finish(with report: SubscriptionUsageReport) {
        let continuation = lock.withLock { () -> CheckedContinuation<SubscriptionUsageReport, Never>? in
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(returning: report)
    }
}

private final class SubscriptionUsageSleeper: @unchecked Sendable {
    private(set) var delays: [UInt64] = []
    func sleep(_ delay: UInt64) async throws {
        delays.append(delay)
        throw CancellationError()
    }
}
```

다음 tests를 작성한다.

```swift
func testMenuRefreshDoesNotStartSubscriptionUsageFetch() async
func testSubscriptionUsageRefreshCoalescesConcurrentCallsIntoOneFetch() async
func testSuccessfulUsageRefreshSchedulesFiveMinutePoll() async
func testTransientUsageFailureDoublesRetryDelayUpToFifteenMinutes() async
func testNonRetriableProfileIsNotFetchedAgainWhileOtherProfilesContinuePolling() async
func testDisablingSubscriptionUsageInvalidatesInFlightRefreshResult() async
```

성공 delay는 `300_000_000_000`이다. transient failure delay는 `60_000_000_000`, `120_000_000_000`, `240_000_000_000`이며 계속 반복해도 `900_000_000_000`을 넘지 않음을 검사한다. permanent Claude profile과 available Codex profile의 두 번째 fetch는 Codex id만 받는지 검사한다.

- [ ] **Step 2: 기존 cancel-and-replace 구현에서 test가 실패하는지 실행한다.**

Run: `swift test --filter DashboardViewModelRefreshTests`

Expected: `refresh()`가 usage fetch를 시작하고 concurrent request가 coalesce되지 않아 새 tests가 실패한다.

- [ ] **Step 3: refresh 역할을 분리하고 profile state를 보존한다.**

`refresh()`에서 `await refreshSubscriptionUsage()`를 제거한다.

`refreshSubscriptionUsage()`의 시작은 아래 guard를 사용한다. 기존 작업을 cancel-and-replace하지 않는다.

```swift
guard subscriptionUsageRefreshTask == nil else { return }
guard config.subscriptionUsage.isEnabled else { setSubscriptionUsageStates(.disabled); return }
guard subscriptionUsageKeyStore.isConfigured() else { setSubscriptionUsageStates(.managementKeyNotConfigured); return }
guard serverStatus.severity == .ready else { setSubscriptionUsageStates(.unavailable(.proxyUnavailable)); return }
```

`Task`를 만들고 완료를 기다린 직후에는 generation이 아직 같은 경우에만 handle을 비운다. 그래야 다음 polling cycle이 실행되며 disable이 먼저 generation을 올렸을 때는 오래된 작업이 새 상태를 지우지 않는다.

```swift
subscriptionUsageRefreshTask = refreshTask
await refreshTask.value
if subscriptionUsageRefreshGeneration == generation {
    subscriptionUsageRefreshTask = nil
}
```

조회 대상 helper를 추가한다.

```swift
private func refreshableSubscriptionUsageProfiles() -> [AuthProfile] {
    authProfiles.filter { profile in
        guard case let .unavailable(issue)? = subscriptionUsageStates[profile.id] else { return true }
        return !issue.stopsPolling
    }
}
```

loading은 이 helper의 profile ids에만 적용한다. report 적용 때는 `subscriptionUsageStates.merge(report.statesByProfileID) { _, incoming in incoming }`를 사용해 permanent account의 state를 보존한다. 모든 profile이 permanent state이면 polling task를 만들지 않는다.

polling에는 initializer로 주입받은 sleeper를 쓴다.

```swift
subscriptionUsagePollingTask = Task { [weak self] in
    do { try await subscriptionUsageSleep(delay) }
    catch { return }
    await self?.refreshSubscriptionUsage()
}
```

start/restart에서 `refreshUntilServerIsReady()`가 ready로 끝난 뒤에만 `await refreshSubscriptionUsage()`를 호출한다. stop 경로에는 호출하지 않는다.

- [ ] **Step 4: ViewModel polling test를 실행한다.**

Run: `swift test --filter DashboardViewModelRefreshTests`

Expected: menu refresh count 0, direct concurrent refresh count 1, delay/backoff, permanent-account exclusion, disable invalidation tests가 통과한다.

- [ ] **Step 5: polling 단위를 커밋한다.**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "fix: poll subscription usage without menu refreshes"
```

## Task 5: 메뉴바 상세 progress presentation을 구현한다

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift:6-12`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift:134-207`
- Modify: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift`

**Interfaces:**
- Produces: `enum SubscriptionUsageProgressTone: Equatable { case normal, warning, critical }`.
- Produces: `subscriptionUsageProgressTone(for:)` and `subscriptionUsageAccessibilityLabel(for:)`.
- Consumes: `UsageWindow` and `MenuBarConnectedProvider.subscriptionUsageState`.

- [ ] **Step 1: pure helper의 failing test를 작성한다.**

```swift
func testUsageProgressToneThresholds() {
    XCTAssertEqual(subscriptionUsageProgressTone(for: 0), .normal)
    XCTAssertEqual(subscriptionUsageProgressTone(for: 49.9), .normal)
    XCTAssertEqual(subscriptionUsageProgressTone(for: 50), .warning)
    XCTAssertEqual(subscriptionUsageProgressTone(for: 79.9), .warning)
    XCTAssertEqual(subscriptionUsageProgressTone(for: 80), .critical)
    XCTAssertEqual(subscriptionUsageProgressTone(for: 100), .critical)
}

func testUsageProgressAccessibilityLabelIncludesUsageAndResetTime() {
    let window = UsageWindow(id: "five_hour", label: "5h", usedPercent: 52, resetAt: Date(timeIntervalSince1970: 0))
    let label = subscriptionUsageAccessibilityLabel(for: window)
    XCTAssertTrue(label.contains("5h"))
    XCTAssertTrue(label.contains("52"))
    XCTAssertTrue(label.contains("resets"))
}
```

- [ ] **Step 2: helper symbol 미정의로 test가 실패하는지 실행한다.**

Run: `swift test --filter MenuBarStatusSnapshotTests`

Expected: progress helper 미정의 컴파일 오류.

- [ ] **Step 3: presentation helper와 palette를 구현한다.**

```swift
import CLIProxyManagerCore
import SwiftUI

enum SubscriptionUsageProgressTone: Equatable {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal: BrandPalette.accent
        case .warning: BrandPalette.statusWarning
        case .critical: BrandPalette.statusError
        }
    }
}

func subscriptionUsageProgressTone(for usedPercent: Double) -> SubscriptionUsageProgressTone {
    switch usedPercent {
    case ..<50: .normal
    case ..<80: .warning
    default: .critical
    }
}

func subscriptionUsageAccessibilityLabel(for window: UsageWindow) -> String {
    let used = Int(window.usedPercent.rounded())
    guard let resetAt = window.resetAt else { return "\(window.label), \(used) percent used" }
    return "\(window.label), \(used) percent used, resets \(resetAt.formatted(date: .abbreviated, time: .shortened))"
}
```

`BrandPalette`에 `static let statusWarning = Color(red: 1.0, green: 0.624, blue: 0.039)`를 추가한다.

- [ ] **Step 4: 계정 행을 multi-line progress bar layout으로 바꾼다.**

`MenuBarAccountRow`에서 account identifier를 우선시한다.

```swift
Text(provider.displayName)
    .font(.system(size: 12.5, weight: .semibold))
Text(provider.connectionDetail)
    .font(.system(size: 11.5))
    .foregroundStyle(.secondary)
    .lineLimit(2)
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
```

available + privacy off 상태에서 window마다 다음 row를 렌더링한다.

```swift
let percent = min(max(window.usedPercent, 0), 100)
HStack(spacing: 7) {
    Text(window.label).frame(width: 52, alignment: .leading)
    ProgressView(value: percent, total: 100)
        .tint(subscriptionUsageProgressTone(for: percent).color)
        .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
    Text("\(Int(percent.rounded()))%")
        .frame(width: 34, alignment: .trailing)
}
.font(.system(size: 10.5, design: .monospaced))
```

`resetAt`이 있으면 row 아래에 `Next reset: ...` 보조 문자열을 출력한다. `$ functionName`은 10.5pt monospaced 보조 행으로 낮춘다. `.loading`, `.unavailable`, `Subscription usage hidden` semantics는 유지한다.

- [ ] **Step 5: 메뉴 presentation tests를 실행한다.**

Run: `swift test --filter MenuBarStatusSnapshotTests`

Expected: threshold, accessibility, existing privacy snapshot tests가 모두 통과한다.

- [ ] **Step 6: 메뉴 UI 단위를 커밋한다.**

```bash
git add Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift \
  Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift \
  Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift \
  Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift
git commit -m "feat: show subscription usage progress in menu bar"
```

## Task 6: Claude/Codex management API 진단 회귀 테스트를 보강한다

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift:5-127`
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift:75-375` (runtime evidence가 계약 차이를 증명할 때만)

**Interfaces:**
- Consumes: `CLIProxyAPISubscriptionQuotaClient.fetchUsage(port:profiles:)`.
- Produces: provider 401/403 → `.credentialExpired`, management 401/403 → `.managementKeyRejected`, malformed body → `.schemaMismatch`.

- [ ] **Step 1: Claude 오류 mapping의 failing tests를 작성한다.**

기존 `StubSubscriptionUsageTransport` response queue를 사용해 아래 tests를 추가한다.

```swift
func testManagementAuthorizationFailureMapsToManagementKeyRejected() async
func testClaudeProviderUnauthorizedResponseMapsToCredentialExpired() async
func testClaudeMalformedUsagePayloadMapsToSchemaMismatch() async
```

세 test는 `.unavailable(...)` enum만 검사한다. 첫 test는 `auth-files` 401을 반환하고, 둘째는 성공한 auth-files 뒤 api-call body에 `status_code:401`을 반환하며, 셋째는 성공한 auth-files 뒤 malformed Claude JSON body를 반환한다.

- [ ] **Step 2: 새 오류 mapping tests를 실행한다.**

Run: `swift test --filter CLIProxyAPISubscriptionQuotaClientTests`

Expected: mapping이 이미 존재하면 PASS, 어느 mapping이 빠졌으면 해당 test만 FAIL한다.

- [ ] **Step 3: 실패한 mapping만 최소 수정한다.**

관리 endpoint status는 `issue(forManagementStatus:)`에서 아래처럼 매핑한다.

```swift
case 401, 403: .managementKeyRejected
case 404, 405, 501: .managementAPINotSupported
case 429, 500...599: .transientFailure
default: .proxyUnavailable
```

provider response status는 `fetchUsage(for:credential:...)`에서 아래처럼 매핑한다.

```swift
if apiResponse.statusCode == 401 || apiResponse.statusCode == 403 {
    return .unavailable(.credentialExpired)
}
if apiResponse.statusCode == 404 || apiResponse.statusCode == 405 || apiResponse.statusCode == 501 {
    return .unavailable(.providerContractUnsupported)
}
```

현재 tests가 PASS면 client source는 바꾸지 않는다. endpoint, headers, parser의 변경은 Task 8 runtime evidence가 확인한 경우에만 별도 red-green cycle로 수행한다.

- [ ] **Step 4: Core quota/client regression을 실행한다.**

Run: `swift test --filter 'CLIProxyAPISubscriptionQuotaClientTests|CLIProxyManagerCommandTests'`

Expected: Claude/Codex parsing, key missing no-network, key body non-leak, CLI output non-leak tests가 모두 통과한다.

- [ ] **Step 5: 진단 regression을 커밋한다.**

```bash
git add Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "test: cover subscription usage management failures"
```

## Task 7: 문서와 전체 자동화 검증을 완료한다

**Files:**
- Modify: `README.md:101-115`
- Verify: `Package.swift`, `Makefile`, `build/development/CLIProxyManager.app`

**Interfaces:**
- Consumes: GUI 자동 key lifecycle과 유지되는 `cpm quota key set --stdin|status|delete`.
- Produces: 사용자가 key를 직접 입력하지 않아도 되는 GUI 설명과 headless 사용법.

- [ ] **Step 1: README의 GUI 설명을 자동 lifecycle로 교체한다.**

기존 문단을 아래로 교체한다.

```markdown
CLIProxyManager can show Claude and Codex OAuth subscription usage in each account row of the menu bar. Enable **Subscription Usage (Experimental)** in Server Settings; the app creates the local CLIProxyAPI management key in Keychain automatically. Turning the setting off removes that Keychain item and removes the proxy management configuration. The app never reads, displays, or exports OAuth tokens.
```

headless 예시는 유지하고 바로 앞에 아래 문장을 넣는다.

```markdown
For headless automation, you may explicitly store and delete the local management key with `cpm quota key`; the GUI does not require manual key input.
```

- [ ] **Step 2: 전체 XCTest suite를 실행한다.**

Run: `swift test`

Expected: exit code 0, 실패 0. 실패가 발생하면 해당 task로 돌아가 원인을 재현하는 failing test부터 수정한다.

- [ ] **Step 3: development app bundle을 빌드·서명·검증한다.**

현재 환경에서 검증된 identity를 사용한다.

```bash
make sign CONFIGURATION=debug BUILD_DIR=build/development CODESIGN_IDENTITY=Quill
xattr -r -c build/development/CLIProxyManager.app
codesign --verify --deep --strict --verbose=2 build/development/CLIProxyManager.app
```

Expected: `valid on disk` 및 designated requirement 충족. Signing identity가 없으면 `security find-identity -v -p codesigning` 결과를 확인한 후 유효한 identity로 같은 명령을 실행한다.

- [ ] **Step 4: 실제 앱과 local CLIProxyAPI를 통해 Claude/Codex를 검증한다.**

앱 실행 전 `~/.cliproxy-manager/functions.zsh`와 `~/.zshrc`를 timestamped backup으로 복사한다. `open -n build/development/CLIProxyManager.app`로 development bundle을 실행한다. UI에서 **Subscription Usage**를 켠 뒤 아래 검증을 수행한다.

```bash
security find-generic-password \
  -s io.woosublee.CLIProxyManager \
  -a subscription-usage-management-key >/dev/null
```

Expected: exit code 0이며 key 값은 출력하지 않는다.

proxy config 파일에서 key 문자열을 출력하지 않고 management block의 존재만 확인한다.

```bash
grep -q '^remote-management:$' ~/.cliproxy-manager/dev/cliproxyapi/config.yaml
grep -q '^  secret-key:' ~/.cliproxy-manager/dev/cliproxyapi/config.yaml
```

Expected: 두 command 모두 exit code 0. 메뉴바에서 Claude와 Codex의 각 available window가 bar·percentage·reset text로 보이는지 확인한다. 팝오버를 연속으로 열어도 `Checking subscription usage…`로 반복 전환되지 않고 캐시가 즉시 보이는지 확인한다.

Claude가 표시되지 않으면, raw secret 없이 HTTP status와 normalized state만 기록해 다음 순서로 isolate한다: auth-files profile/auth_index match → api-call provider status → request header/endpoint contract → JSON window parser. 확정된 단계의 red test를 먼저 추가한 뒤 해당 client branch만 수정한다.

- [ ] **Step 5: toggle OFF의 실제 정리를 검증하고 shell 설정을 복원한다.**

UI에서 토글을 끈 뒤 아래 command를 실행한다.

```bash
if security find-generic-password \
  -s io.woosublee.CLIProxyManager \
  -a subscription-usage-management-key >/dev/null 2>&1; then
  exit 1
fi
grep -q '^remote-management:$' ~/.cliproxy-manager/dev/cliproxyapi/config.yaml && exit 1 || true
```

Expected: Keychain lookup은 실패하고 proxy config에는 management block이 없다. 메뉴바 사용량 UI가 숨겨진다. app launch 전에 만든 `functions.zsh`와 `.zshrc` backup을 원본에 복원하고 `cmp -s`로 동일함을 확인한다.

- [ ] **Step 6: 문서와 최종 검증 단위를 커밋한다.**

```bash
git add README.md
git commit -m "docs: describe automatic subscription usage setup"
git status --short
git log --oneline -7
```

Expected: 최종 구현 커밋이 작업 트리에 반영되고 예기치 않은 파일이 남지 않는다.

## Final Verification Checklist

- [ ] `swift test`가 exit code 0으로 완료되었다.
- [ ] development bundle의 strict codesign verification이 성공했다.
- [ ] enable은 Keychain key를 생성하고 ready proxy를 재시작해 `remote-management`을 적용했다.
- [ ] disable은 in-flight work를 취소하고 Keychain key·proxy config block·메뉴바 usage UI를 제거했다.
- [ ] menu popover는 일반 status만 refresh하고 usage network fetch를 시작하지 않는다.
- [ ] 정상 polling은 5분, transient polling은 1–15분 exponential backoff, permanent account는 account-level stop을 따른다.
- [ ] Claude와 Codex가 local management API를 경유해 실제로 확인되었거나, 실패 지점이 normalized state와 HTTP status로 재현·test화되었다.
- [ ] management key나 OAuth token은 화면·로그·CLI·테스트 출력에 노출되지 않았다.
