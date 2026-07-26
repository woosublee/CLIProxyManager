# API Key Estimated Cost Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude API Key와 OpenAI/Codex API Key 요청을 CLIProxyAPI usage queue에서 안전하게 수집해 계정별 Day/Mon 예상 USD 비용을 메뉴바와 Usage HUD에 표시한다.

**Architecture:** Core에 narrow queue client, record normalizer, owner-only 월별 token ledger, versioned static price catalog, `Decimal` estimator, serialized collector actor를 둔다. App은 기존 OAuth subscription state와 API cost state를 `ProviderUsageState`로 합치고, `DashboardViewModel`은 collector의 report stream을 받아 마지막 성공 값과 partial issue를 보존한다. 기존 `subscriptionUsage` persisted key와 OAuth snapshot cache는 유지하되 API ledger lifecycle은 별도로 관리한다.

**Tech Stack:** Swift 5.10, macOS 15+, SwiftUI, Foundation `Codable`/`Decimal`/`Calendar`, Swift Concurrency actor/`AsyncStream`, Darwin owner-only file I/O, XCTest, Swift Package Manager

## Global Constraints

- CLIProxyAPI 대상 버전은 번들된 `v7.2.97`이며 endpoint는 `GET http://127.0.0.1:<port>/v0/management/usage-queue?count=200`이다.
- queue는 response 전에 destructive pop되고 acknowledgement가 없으므로 exactly-once나 공식 청구액을 주장하지 않는다. UI와 접근성 문구는 항상 `Estimated API cost`로 표현한다.
- queue retention은 정확히 `3,600`초, collector 정상 polling은 `30`초, transient retry 최대 간격은 `900`초로 한다.
- response raw `Data`, `api_key`, request ID, auth index 원문, failure body, response headers를 로그·오류 문자열·ledger·diagnostics에 저장하지 않는다. `APIUsageQueueRecord`에는 `api_key`, `request_id`, `authIndex`, `fail`, `responseHeaders` property를 선언하지 않는다. `auth_index`는 decode 중 non-empty 여부만 `hasAuthIndex: Bool`로 파생하고 원문 `String`은 즉시 폐기한다.
- queue decode 실패 오류에는 HTTP body를 포함하지 않는다. local URLSession은 ephemeral, redirect 금지, cookie/cache 비활성화, request timeout 10초, resource timeout 20초를 유지한다.
- 실제 queue `auth_type` 값 `apikey`를 지원하고 forward compatibility alias `api_key`, `api-key`도 같은 값으로 정규화한다. OAuth record는 무시한다.
- accounting은 `accounting_version == 2`, `token_breakdown.schema_version == 2`, non-negative 및 합계 invariant를 모두 만족하는 `complete` record만 금액 bucket에 넣는다. `unclassified`/`inconsistent`는 count-only issue bucket에 넣는다.
- failed request도 complete token이 있으면 token과 비용에 포함하고 `failedRequestCount`만 별도 증가시킨다.
- 금액은 ledger에 저장하지 않는다. local date·profile·provider·model·effective tier·pricing variant·price epoch별 integer token/count만 저장한다.
- 최초 tracking 활성화 시 `TimeZone.current.identifier`를 metadata에 고정한다. 이후 시스템 시간대가 바뀌어도 Gregorian `Calendar`와 저장된 IANA time zone으로 Day/Mon 경계를 계산한다.
- ledger directory permission은 `0700`, metadata/month/corrupt-backup/process-lock file permission은 `0600`이다. 같은 directory의 임시 파일을 `fsync` 후 atomic `rename`한다. Metadata/month write는 process lock 아래에서 target schema를 다시 확인하며, corrupt backup move는 existing destination을 교체하지 않는 `RENAME_EXCL` 동등 semantics를 사용한다.
- ledger write debounce는 `1_000_000_000`ns이며 정상 stop과 명시적 reload 종료 시 `flush()`한다. Usage 표시를 꺼도 API ledger를 삭제하지 않는다.
- 가격 계산은 끝까지 `Decimal`을 사용한다. exact model ID 또는 명시된 canonical alias만 허용한다.
- Claude cache write는 queue가 TTL을 구분하지 않으므로 5분 rate로 계산하고 `cacheWriteTTLAssumedDefault`를 표시한다.
- Claude 4.6+는 queue가 `inference_geo`를 노출하지 않으므로 global rate로 계산하고 `inferenceGeoAssumedGlobal`을 표시한다. US-only inference는 실제 비용이 10% 높을 수 있음을 tooltip에 명시한다.
- Claude Opus 5/4.8/4.7은 queue가 request speed를 노출하지 않으므로 standard speed rate로 계산하고 `fastModeAssumedStandard`를 표시한다. Fast mode request는 실제 비용이 더 높을 수 있음을 tooltip에 명시한다.
- OpenAI GPT-5.6 Sol/Terra/Luna, GPT-5.5/5.5 Pro, GPT-5.4/5.4 Pro는 input total이 `272_000`보다 클 때 `standardLongContext`를 사용한다. GPT-5.4 mini/nano에는 long-context variant를 적용하지 않는다. priority + long-context 조합은 공식 rate가 없으므로 unpriced 처리한다.
- GPT-5.6 cache write는 공식 cache-write rate를 적용한다. cache-write rate가 없는 OpenAI entry에서 cache write token이 0보다 크면 해당 request를 fully-priced로 세지 않는다.
- API Key stable profile ID는 `claude-api`, `codex-api`다. API key 교체 후에도 같은 provider-level ledger를 이어서 사용한다.
- 메뉴바와 compact HUD는 `Day`/`Mon` 비용만 표시한다. expanded HUD만 `TOK · REQ`를 표시하며 progress bar를 사용하지 않는다.
- 비용 formatting: 0은 `$0.00`, `0 < cost < 0.01`은 `<$0.01`, 그 외는 소수점 둘째 자리. tooltip은 최소 넷째 자리까지 표시한다.
- mixed `UPDATED` 시각은 화면에 표시되는 성공 snapshot 시각들의 최솟값이다.
- persisted JSON의 `subscriptionUsage` key와 OAuth subscription snapshot cache 경로는 변경하지 않는다.
- 새 외부 dependency를 추가하지 않는다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, `make bundle`, `make verify`까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Responsibility Map

### Core 새 파일

- `Sources/CLIProxyManagerCore/APIUsage/ManagementAPIHTTPTransport.swift`: subscription quota와 usage queue가 공유하는 local-only HTTP transport.
- `Sources/CLIProxyManagerCore/APIUsage/APIUsageQueueModels.swift`: narrow queue decode model과 typed client error/protocol.
- `Sources/CLIProxyManagerCore/APIUsage/CLIProxyAPIUsageQueueClient.swift`: Management API authorization, status mapping, array decode.
- `Sources/CLIProxyManagerCore/APIUsage/APIUsageAccounting.swift`: auth/provider/profile mapping, v2 invariant 검증, effective tier 및 pricing variant 분류.
- `Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerModels.swift`: metadata, partial interval, monthly ledger, bucket, period boundary/read model.
- `Sources/CLIProxyManagerCore/APIUsage/APIPriceCatalog.swift`: versioned static rates와 exact alias/effective epoch lookup.
- `Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerStore.swift`: owner-only atomic persistence, debounce, merge, corruption recovery.
- `Sources/CLIProxyManagerCore/APIUsage/APICostEstimator.swift`: `Decimal` 비용, Day/Mon snapshot, ordered issues와 last-success state.
- `Sources/CLIProxyManagerCore/APIUsage/APIUsageCollector.swift`: serialized batch drain, polling/backoff, lifecycle, report `AsyncStream`.

### App 새 파일

- `Sources/CLIProxyManagerApp/Models/ProviderUsageState.swift`: OAuth와 API cost state sum type.
- `Sources/CLIProxyManagerApp/Models/APICostUsagePresentation.swift`: 비용/token/request/tooltip/accessibility formatting과 provider display dispatcher.

### 주요 수정 파일

- `ManagedPaths.swift`, `AppConfig.swift`, `ProxyServiceManager.swift`: usage 활성화와 queue config/ledger 경로.
- `CLIProxyAPISubscriptionQuotaClient.swift`: shared transport 사용.
- `DashboardViewModel.swift`: collector DI/lifecycle/state/reload/row wiring.
- `ProviderRowState.swift`, `MenuBarStatusSnapshot.swift`, `CompactUsagePresentation.swift`: provider usage 일반화.
- `SubscriptionUsageWarningIcon.swift`, `MenuBarStatusView.swift`, `CompactUsageOverlayView.swift`, `UsageOverlayView.swift`, `UsageOverlaySurfaceView.swift`, `UsageSettingsView.swift`: mixed UI.

---

## Task 1: Usage 활성화 이름과 CLIProxyAPI queue 설정

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:393-411`
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:26-38`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:237-308,522-612`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

**Interfaces:**
- Produces: `AppConfig.isUsageEnabled: Bool`
- Produces: compatibility alias `AppConfig.isSubscriptionUsageEnabled: Bool`
- Produces: `ManagedPaths.apiUsageDirectory`, `apiUsageMetadataFile`, `apiUsageMonthlyLedgerFile(month:)`
- Produces: `ProxyServiceManager` initializer argument `usageEnabledProvider: (@Sendable () -> Bool)?`

- [ ] **Step 1: 실패하는 config/path 테스트 작성**

`AppConfigTests.swift`에 추가:

```swift
func testUsageEnabledIsComputedFromEitherDisplayAndKeepsCompatibilityAlias() {
    var config = AppConfig.default
    XCTAssertFalse(config.isUsageEnabled)
    XCTAssertEqual(config.isSubscriptionUsageEnabled, config.isUsageEnabled)

    config.subscriptionUsage.showInMenuBar = true
    XCTAssertTrue(config.isUsageEnabled)

    config.subscriptionUsage.showInMenuBar = false
    config.usageOverlay.isVisible = true
    XCTAssertTrue(config.isUsageEnabled)
}

func testManagedPathsExposeAPIUsageLedgerFiles() {
    let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/cpm"))

    XCTAssertEqual(paths.apiUsageDirectory.path, "/tmp/cpm/api-usage")
    XCTAssertEqual(paths.apiUsageMetadataFile.path, "/tmp/cpm/api-usage/metadata.json")
    XCTAssertEqual(paths.apiUsageMonthlyLedgerFile(month: "2026-07").path, "/tmp/cpm/api-usage/2026-07.json")
}
```

- [ ] **Step 2: 실패하는 proxy config 테스트 작성**

`ProxyServiceManagerTests.swift`에 추가하고 기존 `subscriptionUsageEnabledProvider:` 호출은 `usageEnabledProvider:`로 변경:

```swift
func testStartEnablesUsageQueueOnlyWhenUsageAndAPIKeyAreBothPresent() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        managementKeyProvider: { "management-key" },
        usageEnabledProvider: { true },
        claudeAPIKeyProvider: { "claude-key" },
        codexAPIKeyProvider: { nil }
    )

    try await manager.start(port: 8317)

    let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertTrue(yaml.contains("usage-statistics-enabled: true"))
    XCTAssertTrue(yaml.contains("redis-usage-queue-retention-seconds: 3600"))
    XCTAssertTrue(yaml.contains("remote-management:"))
}

func testStartOmitsUsageQueueWhenUsageIsDisabledEvenWithAPIKey() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        managementKeyProvider: { "management-key" },
        usageEnabledProvider: { false },
        claudeAPIKeyProvider: { "claude-key" },
        codexAPIKeyProvider: { nil }
    )

    try await manager.start(port: 8317)

    let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertFalse(yaml.contains("usage-statistics-enabled:"))
    XCTAssertFalse(yaml.contains("redis-usage-queue-retention-seconds:"))
}

func testStartOmitsUsageQueueWhenOnlyOAuthUsageIsEnabled() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        managementKeyProvider: { "management-key" },
        usageEnabledProvider: { true },
        claudeAPIKeyProvider: { nil },
        codexAPIKeyProvider: { nil }
    )

    try await manager.start(port: 8317)

    let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertFalse(yaml.contains("usage-statistics-enabled:"))
    XCTAssertFalse(yaml.contains("redis-usage-queue-retention-seconds:"))
    XCTAssertTrue(yaml.contains("remote-management:"))
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `swift test --filter 'AppConfigTests|ProxyServiceManagerTests'`
Expected: FAIL — `isUsageEnabled`, API usage paths, `usageEnabledProvider`와 queue YAML이 없음.

- [ ] **Step 4: 최소 구현**

`AppConfig.swift`:

```swift
public var isUsageEnabled: Bool {
    subscriptionUsage.showInMenuBar || usageOverlay.isVisible
}

public var isSubscriptionUsageEnabled: Bool { isUsageEnabled }
```

`ManagedPaths.swift`:

```swift
public var apiUsageDirectory: URL {
    rootDirectory.appendingPathComponent("api-usage", isDirectory: true)
}

public var apiUsageMetadataFile: URL {
    apiUsageDirectory.appendingPathComponent("metadata.json")
}

public func apiUsageMonthlyLedgerFile(month: String) -> URL {
    apiUsageDirectory.appendingPathComponent("\(month).json")
}
```

`ProxyServiceManager`의 stored closure와 두 initializer label을 `usageEnabledProvider`로 바꾸고 default closure는 `(try? AppConfigStore(paths: paths).load().isUsageEnabled) ?? false`를 사용한다. `config(for:)`에서 API key를 한 번만 읽은 뒤 다음 section을 추가한다:

```swift
let claudeAPIKey = nonEmpty(claudeAPIKeyProvider())
let codexAPIKey = nonEmpty(codexAPIKeyProvider())
let hasManagedAPIKey = claudeAPIKey != nil || codexAPIKey != nil
let usageQueueConfiguration = usageEnabledProvider() && hasManagedAPIKey
    ? """
      usage-statistics-enabled: true
      redis-usage-queue-retention-seconds: 3600
      """
    : ""
```

`claudeAPIConfiguration`은 이미 읽은 `claudeAPIKey`를 사용하고, base/fast 양쪽 section 배열에 `usageQueueConfiguration`을 `managementConfiguration` 다음에 넣는다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter 'AppConfigTests|ProxyServiceManagerTests'`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: enable API usage queue for usage displays"
```

---

## Task 2: Shared Management transport와 narrow usage queue client

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/ManagementAPIHTTPTransport.swift`
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIUsageQueueModels.swift`
- Create: `Sources/CLIProxyManagerCore/APIUsage/CLIProxyAPIUsageQueueClient.swift`
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift:1-72`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIUsageQueueClientTests.swift`
- Modify test fixture: `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift:281-305`

**Interfaces:**
- Produces: `ManagementAPIHTTPTransport.send(_:) async throws -> (Data, HTTPURLResponse)`
- Produces: `APIUsageQueueFetching.popUsage(port:count:) async throws -> [APIUsageQueueRecord]`
- Produces: `APIUsageQueueClientError`
- Produces: narrow `APIUsageQueueRecord` and v2 token breakdown structs.

- [ ] **Step 1: queue decode와 request 테스트 작성**

새 테스트 파일:

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIUsageQueueClientTests: XCTestCase {
    func testPopUsageUsesLocalManagementEndpointAndNarrowDecodeModel() async throws {
        let body = Data(#"""
        [{
          "timestamp":"2026-07-25T01:02:03Z",
          "provider":"claude",
          "executor_type":"ClaudeExecutor",
          "model":"claude-opus-5",
          "alias":"cpm-claude-api/claude-opus-5",
          "auth_type":"apikey",
          "auth_index":"auth-1",
          "api_key":"sk-ant-secret",
          "request_id":"req-secret",
          "failed":false,
          "accounting_version":2,
          "token_breakdown":{
            "schema_version":2,"quality":"complete","total_tokens":30,
            "input":{"total_tokens":10,"uncached_tokens":7,"cache_read_tokens":2,"cache_write_tokens":1},
            "output":{"total_tokens":20,"non_reasoning_tokens":15,"reasoning_tokens":5},
            "unclassified_tokens":0
          },
          "service_tier":"default",
          "response_service_tier":"standard",
          "fail":{"status_code":500,"body":"sensitive"},
          "response_headers":{"Authorization":["secret"]}
        }]
        """#.utf8)
        let transport = StubManagementTransport(data: body, statusCode: 200)
        let client = CLIProxyAPIUsageQueueClient(
            keyStore: StubManagementKeyProvider(key: "management-key"),
            transport: transport
        )

        let records = try await client.popUsage(port: 18_317, count: 200)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "claude-opus-5")
        XCTAssertTrue(records[0].hasAuthIndex)
        XCTAssertEqual(records[0].tokenBreakdown.input.cacheWriteTokens, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18317/v0/management/usage-queue?count=200")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer management-key")
        let decodedLabels = Set(Mirror(reflecting: records[0]).children.compactMap(\.label))
        XCTAssertTrue(decodedLabels.isDisjoint(with: ["apiKey", "requestID", "fail", "responseHeaders"]))
    }

    func testDecodeFailureDoesNotExposeRawBody() async {
        let transport = StubManagementTransport(data: Data(#"[{"api_key":"sk-secret"}]"#.utf8), statusCode: 200)
        let client = CLIProxyAPIUsageQueueClient(
            keyStore: StubManagementKeyProvider(key: "management-key"),
            transport: transport
        )

        do {
            _ = try await client.popUsage(port: 18_317, count: 200)
            XCTFail("Expected schema mismatch")
        } catch {
            XCTAssertEqual(error as? APIUsageQueueClientError, .schemaMismatch)
            XCTAssertFalse(String(describing: error).contains("sk-secret"))
        }
    }
}
```

같은 파일 아래에 test doubles를 실제 protocol signature로 추가:

```swift
private final class StubManagementTransport: ManagementAPIHTTPTransport, @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.data = data
        self.response = HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, response)
    }
}

private struct StubManagementKeyProvider: SubscriptionUsageManagementKeyProviding {
    let key: String
    func isConfigured() -> Bool { !key.isEmpty }
    func managementKey() throws -> String { key }
    func createManagementKeyIfNeeded() throws -> Bool { false }
    func setManagementKey(_: String) throws {}
    func deleteManagementKey() throws {}
}
```

- [ ] **Step 2: status mapping 테스트 추가**

```swift
func testStatusCodesMapWithoutIncludingBody() async {
    for (status, expected) in [(401, .managementKeyRejected), (404, .managementAPINotSupported), (429, .transientFailure), (503, .transientFailure)] as [(Int, APIUsageQueueClientError)] {
        let transport = StubManagementTransport(data: Data(#"{"error":"sk-secret"}"#.utf8), statusCode: status)
        let client = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: "key"), transport: transport)
        do {
            _ = try await client.popUsage(port: 18_317, count: 200)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? APIUsageQueueClientError, expected)
            XCTAssertFalse(String(describing: error).contains("sk-secret"))
        }
    }
}

func testMissingManagementKeyAndInvalidArgumentsFailBeforeTransport() async {
    let transport = StubManagementTransport(data: Data("[]".utf8), statusCode: 200)
    let missingKeyClient = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: ""), transport: transport)
    do {
        _ = try await missingKeyClient.popUsage(port: 18_317, count: 200)
        XCTFail("Expected missing key")
    } catch {
        XCTAssertEqual(error as? APIUsageQueueClientError, .managementKeyNotConfigured)
    }

    let client = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: "key"), transport: transport)
    for (port, count, expected) in [(0, 200, .invalidPort), (18_317, 0, .invalidCount)] as [(Int, Int, APIUsageQueueClientError)] {
        do {
            _ = try await client.popUsage(port: port, count: count)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? APIUsageQueueClientError, expected)
        }
    }
    XCTAssertTrue(transport.requests.isEmpty)
}
```

- [ ] **Step 3: 실패 확인**

Run: `swift test --filter CLIProxyAPIUsageQueueClientTests`
Expected: FAIL — 새 transport/model/client가 없음.

- [ ] **Step 4: shared transport 구현 및 subscription client 전환**

`ManagementAPIHTTPTransport.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ManagementAPIHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionManagementAPIHTTPTransport: ManagementAPIHTTPTransport {
    private let session: URLSession

    init(session: URLSession = Self.makeSession()) { self.session = session }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectManagementDelegate(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ManagementAPITransportError.invalidResponse }
        return (data, response)
    }
}

private final class NoRedirectManagementDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ManagementAPITransportError: Error { case invalidResponse }
```

`CLIProxyAPISubscriptionQuotaClient`의 기존 transport protocol/session/delegate를 삭제하고 stored type과 initializer default를 `ManagementAPIHTTPTransport`/`URLSessionManagementAPIHTTPTransport()`로 바꾼다. test double conformance도 새 protocol로 바꾼다.

- [ ] **Step 5: narrow model과 client 구현**

`APIUsageQueueModels.swift`에는 다음 exact public declarations를 둔다:

```swift
public enum APIUsageTokenAccountingQuality: String, Decodable, Equatable, Sendable {
    case complete, inconsistent, unclassified
}

public struct APIUsageTokenInputBreakdown: Decodable, Equatable, Sendable {
    public let totalTokens: Int64
    public let uncachedTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens", uncachedTokens = "uncached_tokens", cacheReadTokens = "cache_read_tokens", cacheWriteTokens = "cache_write_tokens" }
}

public struct APIUsageTokenOutputBreakdown: Decodable, Equatable, Sendable {
    public let totalTokens: Int64
    public let nonReasoningTokens: Int64
    public let reasoningTokens: Int64
    enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens", nonReasoningTokens = "non_reasoning_tokens", reasoningTokens = "reasoning_tokens" }
}

public struct APIUsageTokenBreakdown: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let quality: APIUsageTokenAccountingQuality
    public let totalTokens: Int64
    public let input: APIUsageTokenInputBreakdown
    public let output: APIUsageTokenOutputBreakdown
    public let unclassifiedTokens: Int64
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", quality, totalTokens = "total_tokens", input, output, unclassifiedTokens = "unclassified_tokens" }
}

public struct APIUsageQueueRecord: Decodable, Equatable, Sendable {
    public let timestamp: Date
    public let provider: String
    public let executorType: String
    public let model: String
    public let alias: String
    public let authType: String
    public let hasAuthIndex: Bool
    public let failed: Bool
    public let accountingVersion: Int
    public let tokenBreakdown: APIUsageTokenBreakdown
    public let serviceTier: String
    public let responseServiceTier: String?

    enum CodingKeys: String, CodingKey {
        case timestamp, provider, model, alias, failed
        case executorType = "executor_type"
        case authType = "auth_type"
        case authIndex = "auth_index"
        case accountingVersion = "accounting_version"
        case tokenBreakdown = "token_breakdown"
        case serviceTier = "service_tier"
        case responseServiceTier = "response_service_tier"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        provider = try container.decode(String.self, forKey: .provider)
        executorType = try container.decode(String.self, forKey: .executorType)
        model = try container.decode(String.self, forKey: .model)
        alias = try container.decode(String.self, forKey: .alias)
        authType = try container.decode(String.self, forKey: .authType)
        let rawAuthIndex = try container.decode(String.self, forKey: .authIndex)
        hasAuthIndex = !rawAuthIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        failed = try container.decode(Bool.self, forKey: .failed)
        accountingVersion = try container.decode(Int.self, forKey: .accountingVersion)
        tokenBreakdown = try container.decode(APIUsageTokenBreakdown.self, forKey: .tokenBreakdown)
        serviceTier = try container.decode(String.self, forKey: .serviceTier)
        responseServiceTier = try container.decodeIfPresent(String.self, forKey: .responseServiceTier)
    }
}

public enum APIUsageQueueClientError: Error, Equatable, Sendable {
    case invalidPort
    case invalidCount
    case managementKeyNotConfigured
    case managementKeyRejected
    case managementAPINotSupported
    case transientFailure
    case proxyUnavailable
    case schemaMismatch
}

public protocol APIUsageQueueFetching: Sendable {
    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord]
}
```

세 token breakdown struct에는 위 field 순서와 같은 argument label의 `public init`를 추가한다. `APIUsageQueueRecord`는 외부에서 임의 생성하지 않고 decode 전용으로 유지한다. `auth_index` 원문은 custom `init(from:)`의 local scope 밖으로 나가지 않으며 `hasAuthIndex`만 저장한다.

`CLIProxyAPIUsageQueueClient`는 `count > 0`, valid port, Bearer/Accept headers, fixed typed status mapping을 사용한다. Fractional seconds와 non-fractional RFC3339를 모두 허용하도록 decoder를 다음처럼 구성한다.

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid usage timestamp")
    }
    return date
}
```

Port는 `1...65_535`, count는 양수만 허용해 각각 `.invalidPort`, `.invalidCount`를 request 전에 throw한다. HTTP mapping은 401/403→`.managementKeyRejected`, 404/405/501→`.managementAPINotSupported`, 429/500...599→`.transientFailure`, transport failure와 그 밖의 non-2xx→`.proxyUnavailable`이다. Key store가 비어 있으면 request 전 `.managementKeyNotConfigured`를 throw한다. `CLIProxyAPIUsageQueueClient`는 `public init()`에서 `SubscriptionUsageManagementKeyFileStore()`와 `URLSessionManagementAPIHTTPTransport()`를 사용하고, test용 internal initializer `init(keyStore:transport:)`를 제공한다. `catch DecodingError`는 오직 `.schemaMismatch`만 throw하고 body를 message에 넣지 않는다.

- [ ] **Step 6: 두 client 회귀 테스트**

Run: `swift test --filter 'CLIProxyAPIUsageQueueClientTests|CLIProxyAPISubscriptionQuotaClientTests'`
Expected: PASS.

- [ ] **Step 7: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift Tests/CLIProxyManagerCoreTests/CLIProxyAPIUsageQueueClientTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift
git commit -m "feat: add narrow CLIProxyAPI usage queue client"
```

---

## Task 3: v2 accounting 검증과 API Key profile mapping

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIUsageAccounting.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APIUsageAccountingTests.swift`

**Interfaces:**
- Consumes: `APIUsageQueueRecord`
- Produces: `APIUsageProvider`, `APIUsagePricingVariant`, `APIUsageAggregateInput`, `APIUsageIssueInput`, `APIUsageRecordDisposition`
- Produces: `APIUsageRecordMapper.classify(_:)`

- [ ] **Step 1: failing accounting tests 작성**

```swift
import XCTest
@testable import CLIProxyManagerCore

final class APIUsageAccountingTests: XCTestCase {
    func testClaudeAPIKeyRecordMapsToStableProfileAndPrefersResponseTier() {
        let record = makeRecord(provider: "claude", executor: "ClaudeExecutor", alias: "cpm-claude-api/claude-opus-5", authType: "apikey", responseTier: "standard")

        XCTAssertEqual(APIUsageRecordMapper().classify(record), .aggregate(APIUsageAggregateInput(
            timestamp: record.timestamp, profileID: "claude-api", provider: .claude,
            model: "claude-opus-5", effectiveServiceTier: "standard", pricingVariant: .standard,
            tokenBreakdown: record.tokenBreakdown, failed: false
        )))
    }

    func testCodexLongContextUsesStableProfileAndLongContextVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_001)

        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.profileID, "codex-api")
        XCTAssertEqual(input.provider, .openAI)
        XCTAssertEqual(input.pricingVariant, .standardLongContext)
    }

    func testLongContextBoundaryIsStrictlyGreaterThan272K() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_000)
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .standard)
    }

    func testGPT54MiniDoesNotUseLongContextVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.4-mini", alias: "cpm-codex-api/gpt-5.4-mini", inputTotal: 300_000)
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .standard)
    }

    func testAPIKeyAuthAliasesAreAcceptedAndOAuthIsIgnored() {
        for authType in ["apikey", "api_key", "api-key"] {
            guard case .aggregate = APIUsageRecordMapper().classify(makeRecord(authType: authType)) else {
                return XCTFail("Expected API key alias \(authType) to aggregate")
            }
        }
        XCTAssertEqual(APIUsageRecordMapper().classify(makeRecord(authType: "oauth")), .ignored)
    }

    func testEmptyAuthIndexCannotMapProviderAndRawValueIsNotStored() {
        let record = makeRecord(authIndex: "   ")
        XCTAssertFalse(record.hasAuthIndex)
        guard case let .issue(issue) = APIUsageRecordMapper().classify(record) else {
            return XCTFail("Expected mapping issue")
        }
        XCTAssertEqual(issue.reason, .unknownProviderMapping)
        XCTAssertFalse(Mirror(reflecting: record).children.compactMap(\.label).contains("authIndex"))
    }

    func testOnlyProviderMatchedManagedModelAliasesAreCanonicalized() {
        let managed = makeRecord(
            provider: "codex",
            executor: "CodexExecutor",
            model: "cpm-codex-api/gpt-5.6-sol-fast(xhigh)",
            alias: "cpm-codex-api/gpt-5.6-sol-fast(xhigh)"
        )
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(managed) else {
            return XCTFail("Expected aggregate")
        }
        XCTAssertEqual(input.model, "gpt-5.6-sol")

        for model in [
            "third-party/gpt-5.6-sol",
            "gpt-5.6-sol(fake)",
            "cpm-claude-api/gpt-5.6-sol"
        ] {
            let record = makeRecord(
                provider: "codex",
                executor: "CodexExecutor",
                model: model,
                alias: "cpm-codex-api/\(model)"
            )
            guard case let .aggregate(unknown) = APIUsageRecordMapper().classify(record) else {
                return XCTFail("Expected aggregate for \(model)")
            }
            XCTAssertEqual(unknown.model, model)
        }
    }

    func testPriorityLongContextIsPreservedAsUnsupportedVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_001, responseTier: "priority")
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .priorityLongContext)
    }

    func testUnclassifiedAccountingBecomesIssueCount() {
        let record = makeRecord(quality: .unclassified)
        XCTAssertEqual(APIUsageRecordMapper().classify(record), .issue(APIUsageIssueInput(timestamp: record.timestamp, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting)))
    }

    func testInvalidV2InvariantBecomesIssueInsteadOfAggregate() {
        let record = makeInvalidRecord(totalTokens: 999)
        guard case let .issue(issue) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected issue") }
        XCTAssertEqual(issue.reason, .incompleteTokenAccounting)
    }

    func testUnsupportedAccountingVersionAndUnknownProviderBecomeTypedIssues() {
        var unsupportedObject = recordJSONObject()
        unsupportedObject["accounting_version"] = 3
        guard case let .issue(unsupported) = APIUsageRecordMapper().classify(decodeRecord(unsupportedObject)) else { return XCTFail("Expected issue") }
        XCTAssertEqual(unsupported.reason, .unsupportedAccountingVersion)

        let unknown = makeRecord(provider: "other", executor: "OtherExecutor", alias: "other/model")
        guard case let .issue(mapping) = APIUsageRecordMapper().classify(unknown) else { return XCTFail("Expected issue") }
        XCTAssertNil(mapping.profileID)
        XCTAssertEqual(mapping.reason, .unknownProviderMapping)
    }

    func testCompleteFailedRequestRemainsAnAggregate() {
        var object = recordJSONObject()
        object["failed"] = true
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(decodeRecord(object)) else { return XCTFail("Expected aggregate") }
        XCTAssertTrue(input.failed)
        XCTAssertEqual(input.tokenBreakdown.totalTokens, 30)
    }
}
```

Test helper는 다음처럼 JSON object를 decode해 구현하고 fixture에는 API key를 넣지 않는다.

```swift
private func recordJSONObject(
    provider: String = "claude",
    executor: String = "ClaudeExecutor",
    model: String = "claude-opus-5",
    alias: String = "cpm-claude-api/claude-opus-5",
    authType: String = "apikey",
    authIndex: String = "auth-1",
    inputTotal: Int64 = 10,
    total: Int64? = nil,
    quality: APIUsageTokenAccountingQuality = .complete,
    responseTier: String? = nil
) -> [String: Any] {
    let isComplete = quality == .complete
    let resolvedTotal = total ?? (inputTotal + 20)
    let normalizedInput = isComplete ? inputTotal : 0
    let outputTotal = isComplete ? resolvedTotal - inputTotal : 0
    var object: [String: Any] = [
        "timestamp": "2026-07-25T01:02:03Z",
        "provider": provider,
        "executor_type": executor,
        "model": model,
        "alias": alias,
        "auth_type": authType,
        "auth_index": authIndex,
        "failed": false,
        "accounting_version": 2,
        "token_breakdown": [
            "schema_version": 2,
            "quality": quality.rawValue,
            "total_tokens": resolvedTotal,
            "input": ["total_tokens": normalizedInput, "uncached_tokens": normalizedInput, "cache_read_tokens": 0, "cache_write_tokens": 0],
            "output": ["total_tokens": outputTotal, "non_reasoning_tokens": outputTotal, "reasoning_tokens": 0],
            "unclassified_tokens": isComplete ? 0 : resolvedTotal
        ],
        "service_tier": "default"
    ]
    if let responseTier { object["response_service_tier"] = responseTier }
    return object
}

private func decodeRecord(_ object: [String: Any]) -> APIUsageQueueRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(APIUsageQueueRecord.self, from: JSONSerialization.data(withJSONObject: object))
}

private func makeRecord(
    provider: String = "claude",
    executor: String = "ClaudeExecutor",
    model: String = "claude-opus-5",
    alias: String = "cpm-claude-api/claude-opus-5",
    authType: String = "apikey",
    authIndex: String = "auth-1",
    inputTotal: Int64 = 10,
    total: Int64? = nil,
    quality: APIUsageTokenAccountingQuality = .complete,
    responseTier: String? = nil
) -> APIUsageQueueRecord {
    decodeRecord(recordJSONObject(provider: provider, executor: executor, model: model, alias: alias, authType: authType, authIndex: authIndex, inputTotal: inputTotal, total: total, quality: quality, responseTier: responseTier))
}

private func makeInvalidRecord(totalTokens: Int64) -> APIUsageQueueRecord {
    var object = recordJSONObject()
    var breakdown = object["token_breakdown"] as! [String: Any]
    breakdown["total_tokens"] = totalTokens
    object["token_breakdown"] = breakdown
    return decodeRecord(object)
}
```

두 helper 모두 raw secret field를 추가하지 않는다.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter APIUsageAccountingTests`
Expected: FAIL — accounting types/mapper 없음.

- [ ] **Step 3: exact domain types 구현**

```swift
public enum APIUsageProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case openAI = "openai"
    public var profileID: String { self == .claude ? "claude-api" : "codex-api" }
}

public enum APIUsagePricingVariant: String, Codable, Hashable, Sendable {
    case standard
    case priority
    case standardLongContext
    case priorityLongContext
}

public enum APIUsageLedgerIssueReason: String, Codable, Equatable, Sendable {
    case unsupportedAccountingVersion
    case incompleteTokenAccounting
    case unknownProviderMapping
}

public struct APIUsageAggregateInput: Equatable, Sendable {
    public let timestamp: Date
    public let profileID: String
    public let provider: APIUsageProvider
    public let model: String
    public let effectiveServiceTier: String
    public let pricingVariant: APIUsagePricingVariant
    public let tokenBreakdown: APIUsageTokenBreakdown
    public let failed: Bool
}

public struct APIUsageIssueInput: Equatable, Sendable {
    public let timestamp: Date
    public let profileID: String?
    public let provider: APIUsageProvider?
    public let reason: APIUsageLedgerIssueReason
}

public enum APIUsageRecordDisposition: Equatable, Sendable {
    case ignored
    case aggregate(APIUsageAggregateInput)
    case issue(APIUsageIssueInput)
}
```

- [ ] **Step 4: mapper 규칙 구현**

`APIUsageRecordMapper.classify`는 다음 순서로 구현한다.

```swift
public struct APIUsageRecordMapper: Sendable {
    public init() {}

    public func classify(_ record: APIUsageQueueRecord) -> APIUsageRecordDisposition {
        let authType = normalized(record.authType)
        guard ["apikey", "api_key", "api-key"].contains(authType) else { return .ignored }
        guard let provider = mappedProvider(record) else {
            return .issue(.init(timestamp: record.timestamp, profileID: nil, provider: nil, reason: .unknownProviderMapping))
        }
        guard record.accountingVersion == 2, record.tokenBreakdown.schemaVersion == 2 else {
            return .issue(.init(timestamp: record.timestamp, profileID: provider.profileID, provider: provider, reason: .unsupportedAccountingVersion))
        }
        guard record.tokenBreakdown.quality == .complete, valid(record.tokenBreakdown) else {
            return .issue(.init(timestamp: record.timestamp, profileID: provider.profileID, provider: provider, reason: .incompleteTokenAccounting))
        }
        let model = canonicalModel(record.model, provider: provider)
        let rawTier = normalized(record.responseServiceTier.flatMap(nonEmpty) ?? record.serviceTier)
        let tier = canonicalServiceTier(rawTier, provider: provider)
        let longContextModels: Set<String> = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-pro"]
        let longContext = provider == .openAI && longContextModels.contains(model) && record.tokenBreakdown.input.totalTokens > 272_000
        let priority = tier == "priority"
        let variant: APIUsagePricingVariant = switch (priority, longContext) {
        case (false, false): .standard
        case (true, false): .priority
        case (false, true): .standardLongContext
        case (true, true): .priorityLongContext
        }
        return .aggregate(.init(
            timestamp: record.timestamp,
            profileID: provider.profileID,
            provider: provider,
            model: model,
            effectiveServiceTier: tier.isEmpty ? "default" : tier,
            pricingVariant: variant,
            tokenBreakdown: record.tokenBreakdown,
            failed: record.failed
        ))
    }
}
```

`mappedProvider`는 raw `auth_index`를 보관하지 않고 `record.hasAuthIndex == true`이며 다음을 모두 만족할 때만 매핑한다.

```swift
guard record.hasAuthIndex else { return nil }
let provider = normalized(record.provider)
let executor = normalized(record.executorType)
let alias = normalized(record.alias)
if ["claude", "anthropic"].contains(provider), executor.contains("claude"), alias.hasPrefix("cpm-claude-api/") {
    return .claude
}
if ["codex", "openai"].contains(provider), (executor.contains("codex") || executor.contains("openai")), alias.hasPrefix("cpm-codex-api/") {
    return .openAI
}
return nil
```

`canonicalServiceTier`는 Claude의 empty/`default`/`auto`/`standard`/`standard_only`를 `standard`로, OpenAI의 empty/`default`/`auto`/`standard`를 `default`로, OpenAI `priority`를 `priority`로 변환한다. 그 밖의 값은 lowercased raw value를 보존해 estimator가 `.unsupportedServiceTier`를 생성하게 한다.

`valid(_:)`는 모든 값 non-negative, input/output sub-sum, total sum, complete일 때 unclassified 0을 검사한다. `canonicalModel(_:provider:)`은 trim/lowercase 후 provider와 일치하는 app-managed routing prefix만 제거한다: Claude는 `cpm-claude-api/`, OpenAI는 `cpm-codex-api/`다. OpenAI model에만 `CodexFastMode.canonicalModel(from:)`을 적용해 검증된 managed `-fast` alias와 `AppConfig.CodexReasoning`에 존재하는 reasoning suffix를 제거한다. 알 수 없는 routing prefix, 괄호 suffix 또는 provider와 불일치하는 managed prefix는 원문을 유지해 후속 estimator가 `.unknownModel`로 처리하게 한다. 임의 `/` 마지막 component나 첫 `(` 앞부분을 취하지 않는다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter APIUsageAccountingTests`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APIUsageAccounting.swift Tests/CLIProxyManagerCoreTests/APIUsageAccountingTests.swift
git commit -m "feat: validate and classify API usage records"
```

---

## Task 4: Ledger Codable 모델과 DST-safe period 계산

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerModels.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APIUsageLedgerModelsTests.swift`

**Interfaces:**
- Consumes: accounting aggregate/issue inputs.
- Produces: `APIUsageTrackingMetadata`, `APIUsageMonthlyLedger`, bucket/issue/partial models.
- Produces: `APIUsagePeriodCalculator.bounds(at:timeZoneID:)` and `APIUsageLedgerReadModel`.

- [ ] **Step 1: round-trip와 timezone tests 작성**

```swift
final class APIUsageLedgerModelsTests: XCTestCase {
    func testMonthlyLedgerRoundTripsWithoutSensitiveIdentityFields() throws {
        let bucket = APIUsageLedgerBucket(
            key: .init(localDate: "2026-07-25", profileID: "claude-api", provider: .claude, model: "claude-opus-5", effectiveServiceTier: "standard", pricingVariant: .standard, priceEpochStart: Date(timeIntervalSince1970: 10)),
            uncachedInputTokens: 10, cacheReadTokens: 2, cacheWriteTokens: 1,
            nonReasoningOutputTokens: 20, reasoningOutputTokens: 5, totalTokens: 38,
            requestCount: 1, failedRequestCount: 0,
            firstObservedAt: Date(timeIntervalSince1970: 20), lastObservedAt: Date(timeIntervalSince1970: 20)
        )
        let ledger = APIUsageMonthlyLedger(schemaVersion: 1, month: "2026-07", reportingTimeZoneID: "Asia/Seoul", buckets: [bucket], issues: [])

        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(APIUsageMonthlyLedger.self, from: data), ledger)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["api_key", "auth_index", "request_id", "failure", "response_headers"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testPeriodBoundsUseStoredTimeZoneAcrossDSTAndSystemZoneChanges() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-03-08T10:30:00Z")!
        let result = APIUsagePeriodCalculator.bounds(at: instant, timeZoneID: "America/Los_Angeles")

        XCTAssertFalse(result.usedUTCFallback)
        XCTAssertEqual(result.localDate, "2026-03-08")
        XCTAssertEqual(result.month, "2026-03")
        XCTAssertEqual(result.dayStart, ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z"))
        XCTAssertEqual(result.dayEnd, ISO8601DateFormatter().date(from: "2026-03-09T07:00:00Z"))
    }

    func testPeriodBoundsHandleMonthAndYearRollover() {
        let instant = ISO8601DateFormatter().date(from: "2027-01-01T07:30:00Z")!
        let result = APIUsagePeriodCalculator.bounds(at: instant, timeZoneID: "America/Los_Angeles")

        XCTAssertEqual(result.localDate, "2026-12-31")
        XCTAssertEqual(result.month, "2026-12")
        XCTAssertEqual(result.dayEnd, ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
        XCTAssertEqual(result.monthEnd, ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
    }

    func testInvalidTimeZoneFallsBackToUTCAndMarksResult() {
        let result = APIUsagePeriodCalculator.bounds(at: Date(timeIntervalSince1970: 0), timeZoneID: "Invalid/Zone")
        XCTAssertTrue(result.usedUTCFallback)
        XCTAssertEqual(result.resolvedTimeZoneID, "UTC")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter APIUsageLedgerModelsTests`
Expected: FAIL — ledger/bounds types 없음.

- [ ] **Step 3: Codable models 구현**

다음 declarations를 exact field names로 구현한다:

```swift
public enum APIUsageLedgerSchema {
    public static let currentVersion = 1
}

public struct APIUsageTrackingMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var reportingTimeZoneID: String
    public var trackingStartedAt: Date
    public var lastSuccessfulDrainAt: Date?
    public var lastObservedRequestAt: Date?
    public var collectorPausedAt: Date?
    public var partialIntervals: [APIUsagePartialInterval]
}

public enum APIUsagePartialIntervalReason: String, Codable, Equatable, Sendable {
    case trackingStartedMidPeriod, trackingWasDisabled, collectionGap, persistenceFailure, corruptedLedger
}

public struct APIUsagePartialInterval: Codable, Equatable, Sendable {
    public let start: Date
    public var end: Date?
    public let reason: APIUsagePartialIntervalReason
}

public struct APIUsageLedgerBucketKey: Codable, Hashable, Sendable {
    public let localDate: String
    public let profileID: String
    public let provider: APIUsageProvider
    public let model: String
    public let effectiveServiceTier: String
    public let pricingVariant: APIUsagePricingVariant
    public let priceEpochStart: Date?
}

public struct APIUsageLedgerBucket: Codable, Equatable, Sendable {
    public let key: APIUsageLedgerBucketKey
    public var uncachedInputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var nonReasoningOutputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64
    public var requestCount: Int64
    public var failedRequestCount: Int64
    public var firstObservedAt: Date
    public var lastObservedAt: Date
}

public struct APIUsageLedgerIssueBucket: Codable, Equatable, Sendable {
    public let localDate: String
    public let profileID: String?
    public let provider: APIUsageProvider?
    public let reason: APIUsageLedgerIssueReason
    public var count: Int64
}

public struct APIUsageMonthlyLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let month: String
    public let reportingTimeZoneID: String
    public var buckets: [APIUsageLedgerBucket]
    public var issues: [APIUsageLedgerIssueBucket]
}

public struct APIUsagePeriodBounds: Equatable, Sendable {
    public let intervalReference: Date
    public let localDate: String
    public let month: String
    public let dayStart: Date
    public let dayEnd: Date
    public let monthStart: Date
    public let monthEnd: Date
    public let resolvedTimeZoneID: String
    public let usedUTCFallback: Bool
}

public struct APIUsageLedgerReadModel: Equatable, Sendable {
    public let metadata: APIUsageTrackingMetadata
    public let bounds: APIUsagePeriodBounds
    public let currentMonth: APIUsageMonthlyLedger
}
```

각 public struct에는 위 field 순서와 같은 argument label의 `public init`를 추가한다. `APIUsageTrackingMetadata` initializer의 optional timestamp default는 `nil`, `partialIntervals` default는 `[]`; monthly ledger의 `buckets`/`issues` default는 `[]`로 둔다.

- [ ] **Step 4: Calendar period calculator 구현**

`APIUsagePeriodCalculator.bounds`는 `TimeZone(identifier:) ?? TimeZone(secondsFromGMT: 0)!`, Gregorian calendar, `startOfDay`, `date(byAdding:.day,value:1)`, `dateComponents([.year,.month])`를 사용한다. fixed 24-hour arithmetic을 사용하지 않는다. `en_US_POSIX` locale의 `yyyy-MM-dd`/`yyyy-MM` formatter를 해당 timezone에 고정한다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter APIUsageLedgerModelsTests`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerModels.swift Tests/CLIProxyManagerCoreTests/APIUsageLedgerModelsTests.swift
git commit -m "feat: add API usage ledger models and period bounds"
```

---

## Task 5: Versioned static price catalog와 epoch lookup

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIPriceCatalog.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APIPriceCatalogTests.swift`

**Interfaces:**
- Consumes: provider/model/tier/variant/timestamp.
- Produces: `APIPriceRates`, `APIPriceEntry`, `APIPriceCatalog.current`, `entry(provider:model:serviceTier:variant:at:)`, `classification(provider:model:serviceTier:variant:at:)`.

- [ ] **Step 1: failing catalog tests 작성**

```swift
final class APIPriceCatalogTests: XCTestCase {
    func testClaudeSonnetIntroductoryPriceEndsAtSeptemberBoundary() throws {
        let catalog = APIPriceCatalog.current
        let august = try XCTUnwrap(catalog.entry(provider: .claude, model: "claude-sonnet-5", serviceTier: "standard", variant: .standard, at: iso("2026-08-31T23:59:59Z")))
        let september = try XCTUnwrap(catalog.entry(provider: .claude, model: "claude-sonnet-5", serviceTier: "standard", variant: .standard, at: iso("2026-09-01T00:00:00Z")))
        XCTAssertEqual(august.rates.uncachedInputUSDPerMillion, Decimal(string: "2"))
        XCTAssertEqual(september.rates.uncachedInputUSDPerMillion, Decimal(string: "3"))
        XCTAssertNotEqual(august.effectiveFrom, september.effectiveFrom)
    }

    func testGPT56HasShortLongPriorityAndCacheWriteRates() throws {
        let catalog = APIPriceCatalog.current
        let short = try XCTUnwrap(catalog.entry(provider: .openAI, model: "gpt-5.6-terra", serviceTier: "default", variant: .standard, at: iso("2026-07-25T12:00:00Z")))
        let long = try XCTUnwrap(catalog.entry(provider: .openAI, model: "gpt-5.6-terra", serviceTier: "default", variant: .standardLongContext, at: iso("2026-07-25T12:00:00Z")))
        let priority = try XCTUnwrap(catalog.entry(provider: .openAI, model: "gpt-5.6-terra", serviceTier: "priority", variant: .priority, at: iso("2026-07-25T12:00:00Z")))
        XCTAssertEqual(short.rates.cacheWriteUSDPerMillion, Decimal(string: "3.125"))
        XCTAssertEqual(long.rates.outputUSDPerMillion, Decimal(string: "22.5"))
        XCTAssertEqual(priority.rates.outputUSDPerMillion, Decimal(string: "30"))
        XCTAssertNil(catalog.entry(provider: .openAI, model: "gpt-5.6-terra", serviceTier: "priority", variant: .priorityLongContext, at: iso("2026-07-25T12:00:00Z")))
    }

    func testCatalogDoesNotGuessUnknownModelFamily() {
        XCTAssertNil(APIPriceCatalog.current.entry(provider: .claude, model: "claude-opus-future", serviceTier: "standard", variant: .standard, at: Date()))
    }

    func testCatalogRequiresExactModelSpelling() {
        let at = iso("2026-07-25T12:00:00Z")
        for model in [" GPT-5.6-TERRA ", "gpt-5.6-Terra"] {
            XCTAssertNil(APIPriceCatalog.current.entry(
                provider: .openAI,
                model: model,
                serviceTier: "default",
                variant: .standard,
                at: at
            ))
            XCTAssertEqual(APIPriceCatalog.current.classification(
                provider: .openAI,
                model: model,
                serviceTier: "default",
                variant: .standard,
                at: at
            ), .unknownModel)
        }
    }

    func testClassificationDistinguishesUnavailablePriceEpoch() {
        XCTAssertEqual(APIPriceCatalog.current.classification(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standard,
            at: iso("2026-07-24T23:59:59Z")
        ), .priceEpochUnavailable)
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter APIPriceCatalogTests`
Expected: FAIL — catalog types 없음.

- [ ] **Step 3: catalog declarations와 lookup 구현**

```swift
public struct APIPriceRates: Equatable, Sendable {
    public let uncachedInputUSDPerMillion: Decimal
    public let cacheReadUSDPerMillion: Decimal?
    public let cacheWriteUSDPerMillion: Decimal?
    public let outputUSDPerMillion: Decimal
}

public struct APIPriceEntry: Equatable, Sendable {
    public let provider: APIUsageProvider
    public let model: String
    public let serviceTier: String
    public let variant: APIUsagePricingVariant
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let rates: APIPriceRates
}

public enum APIPriceClassification: Equatable, Sendable {
    case priced(APIPriceEntry)
    case unknownModel
    case unsupportedServiceTier
    case unknownPricingVariant
    case priceEpochUnavailable
}

public struct APIPriceCatalog: Equatable, Sendable {
    public let version: Int
    public let entries: [APIPriceEntry]
    public func entry(provider: APIUsageProvider, model: String, serviceTier: String, variant: APIUsagePricingVariant, at: Date) -> APIPriceEntry?
    public func classification(provider: APIUsageProvider, model: String, serviceTier: String, variant: APIUsagePricingVariant, at: Date) -> APIPriceClassification
}
```

Lookup은 canonical exact model, normalized tier, exact variant, `effectiveFrom <= at < effectiveUntil`을 모두 만족하는 entry 중 가장 최신 `effectiveFrom`을 선택한다. Model은 trim/lowercase하지 않고 exact 문자열로 비교하며, Claude canonical alias도 `claude-haiku-4-5-20251001`처럼 허용 목록에 있는 exact date-suffix key만 명시적으로 base ID에 매핑한다. Tier만 기존 canonical lowercase 값에 맞게 normalize한다. `classification`은 해당 provider/exact-model entry가 하나도 없으면 `.unknownModel`, model은 있지만 tier가 없으면 `.unsupportedServiceTier`, model+tier는 있지만 variant가 없으면 `.unknownPricingVariant`, model+tier+variant는 존재하지만 해당 timestamp에 active epoch가 없으면 `.priceEpochUnavailable`, active exact match면 `.priced(entry)`를 반환한다. 임의 case folding, whitespace trim, prefix/family/version fallback은 금지한다.

- [ ] **Step 4: current catalog rates 입력**

`baseline = 2026-07-25T00:00:00Z`, Sonnet 5 standard epoch = `2026-09-01T00:00:00Z`. helper factory를 사용하되 다음 rate를 모두 exact `Decimal(string:)`으로 입력한다.

```text
Claude Fable 5: 10 / 1 / 12.5 / 50
Claude Opus 5, 4.8, 4.7, 4.6, 4.5: 5 / 0.5 / 6.25 / 25
Claude Sonnet 5 through 2026-08-31: 2 / 0.2 / 2.5 / 10
Claude Sonnet 5 from 2026-09-01: 3 / 0.3 / 3.75 / 15
Claude Sonnet 4.6, 4.5: 3 / 0.3 / 3.75 / 15
Claude Haiku 4.5: 1 / 0.1 / 1.25 / 5

GPT-5.6 Sol standard: 5 / 0.5 / 6.25 / 30
GPT-5.6 Sol long: 10 / 1 / 12.5 / 45
GPT-5.6 Sol priority: 10 / 1 / 12.5 / 60
GPT-5.6 Terra standard: 2.5 / 0.25 / 3.125 / 15
GPT-5.6 Terra long: 5 / 0.5 / 6.25 / 22.5
GPT-5.6 Terra priority: 5 / 0.5 / 6.25 / 30
GPT-5.6 Luna standard: 1 / 0.1 / 1.25 / 6
GPT-5.6 Luna long: 2 / 0.2 / 2.5 / 9
GPT-5.6 Luna priority: 2 / 0.2 / 2.5 / 12
GPT-5.5 standard: 5 / 0.5 / nil / 30
GPT-5.5 long: 10 / 1 / nil / 45
GPT-5.5 priority: 12.5 / 1.25 / nil / 75
GPT-5.5-pro standard: 30 / nil / nil / 180
GPT-5.5-pro long: 60 / nil / nil / 270
GPT-5.4 standard: 2.5 / 0.25 / nil / 15
GPT-5.4 long: 5 / 0.5 / nil / 22.5
GPT-5.4 priority: 5 / 0.5 / nil / 30
GPT-5.4-pro standard: 30 / nil / nil / 180
GPT-5.4-pro long: 60 / nil / nil / 270
GPT-5.4-mini standard: 0.75 / 0.075 / nil / 4.5
GPT-5.4-mini priority: 1.5 / 0.15 / nil / 9
GPT-5.4-nano standard: 0.2 / 0.02 / nil / 1.25
```

각 줄 순서는 `uncached input / cache read / cache write / output`이다. Source URL을 code comment로 두되 network fetch는 구현하지 않는다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter APIPriceCatalogTests`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APIPriceCatalog.swift Tests/CLIProxyManagerCoreTests/APIPriceCatalogTests.swift
git commit -m "feat: add versioned API price catalog"
```

---

## Task 6: Owner-only monthly ledger store와 debounce persistence

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerStore.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APIUsageLedgerStoreTests.swift`

**Interfaces:**
- Consumes: `[APIUsageLedgerMutation]`, `APIPriceCatalog` epoch lookup.
- Produces: `APIUsageLedgerStoring` async protocol.
- Produces: `APIUsageLedgerStore.prepareTracking`, `merge`, `markPaused`, `markResumed`, `markCollectionGap`, `markSuccessfulDrain`, `readCurrentPeriods`, `flush`.

- [ ] **Step 1: merge/permission/restart tests 작성**

```swift
final class APIUsageLedgerStoreTests: XCTestCase {
    func testMergePersistsMonthlyAggregateAndRestoresAfterRestart() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "Asia/Seoul")
        let input = makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        let epoch = try XCTUnwrap(APIPriceCatalog.current.entry(provider: .claude, model: "claude-opus-5", serviceTier: "standard", variant: .standard, at: now)?.effectiveFrom)

        try await store.merge([.aggregate(input, priceEpochStart: epoch)])
        try await store.flush()

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let read = try await restored.readCurrentPeriods(at: now)
        XCTAssertEqual(read.currentMonth.buckets.first?.requestCount, 1)
        XCTAssertEqual(read.currentMonth.buckets.first?.totalTokens, input.tokenBreakdown.totalTokens)
        XCTAssertEqual(fileMode(paths.apiUsageDirectory), 0o700)
        XCTAssertEqual(fileMode(paths.apiUsageMetadataFile), 0o600)
        XCTAssertEqual(fileMode(paths.apiUsageMonthlyLedgerFile(month: "2026-07")), 0o600)
    }

    func testPrepareTrackingKeepsTheFirstReportingTimeZone() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "Asia/Seoul")
        try await store.flush()

        try await store.prepareTracking(at: iso("2026-07-25T16:00:00Z"), reportingTimeZoneID: "UTC")
        let read = try await store.readCurrentPeriods(at: iso("2026-07-25T16:00:00Z"))

        XCTAssertEqual(read.metadata.reportingTimeZoneID, "Asia/Seoul")
        XCTAssertEqual(read.bounds.localDate, "2026-07-26")
    }

    func testPersistedLedgerSchemaContainsNoRawQueueSecretFields() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "UTC")
        try await store.merge([.aggregate(makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: now)])
        try await store.flush()

        let persisted = try [paths.apiUsageMetadataFile, paths.apiUsageMonthlyLedgerFile(month: "2026-07")]
            .map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
        for forbiddenKey in ["\"api_key\"", "\"request_id\"", "\"auth_index\"", "\"fail\"", "\"response_headers\""] {
            XCTAssertFalse(persisted.contains(forbiddenKey), "Persisted forbidden queue field: \(forbiddenKey)")
        }
    }

    func testUsageDisablePauseDoesNotDeleteLedgerAndCreatesPartialInterval() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")
        try await store.markPaused(at: iso("2026-07-25T02:00:00Z"), proxyCouldServeRequests: true)
        try await store.markResumed(at: iso("2026-07-25T03:00:00Z"))
        try await store.flush()

        let read = try await store.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.apiUsageMetadataFile.path))
        XCTAssertEqual(read.metadata.partialIntervals.last?.reason, .trackingWasDisabled)
        XCTAssertEqual(read.metadata.partialIntervals.last?.end, iso("2026-07-25T03:00:00Z"))
    }

    func testCorruptedLedgerIsMovedWithoutPrintingPayloadAndPeriodBecomesPartial() async throws {
        let paths = try makePaths()
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")
        try await initial.flush()
        let file = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try Data("not-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        _ = try await restored.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
        try await restored.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: paths.apiUsageDirectory.path)
        let backupName = try XCTUnwrap(names.first { $0.hasPrefix("2026-07.corrupt-") })
        XCTAssertEqual(fileMode(paths.apiUsageDirectory.appendingPathComponent(backupName)), 0o600)
        let metadata = try JSONDecoder().decode(APIUsageTrackingMetadata.self, from: Data(contentsOf: paths.apiUsageMetadataFile))
        XCTAssertTrue(metadata.partialIntervals.contains { $0.reason == .corruptedLedger })
    }

    func testSymlinkLedgerPathIsRejectedWithoutTouchingTarget() async throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.apiUsageDirectory, withIntermediateDirectories: true)
        let target = paths.rootDirectory.appendingPathComponent("target.json")
        try Data("sentinel".utf8).write(to: target)
        let ledger = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try FileManager.default.createSymbolicLink(at: ledger, withDestinationURL: target)
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")

        do {
            try await store.merge([.aggregate(makeAggregate(timestamp: iso("2026-07-25T02:00:00Z"), profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: iso("2026-07-25T00:00:00Z"))])
            try await store.flush()
            XCTFail("Expected invalid file")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .invalidFile)
            XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
        }
    }

    func testInsecureLedgerPermissionsAreRejected() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "UTC")
        try await store.merge([.aggregate(makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: now)])
        try await store.flush()
        let ledger = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledger.path)

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        do {
            _ = try await restored.readCurrentPeriods(at: now)
            XCTFail("Expected invalid file")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .invalidFile)
        }
    }

    func testFutureLedgerSchemaIsRejectedWithoutDowngradeOrOverwrite() async throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.apiUsageDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.apiUsageDirectory.path)
        let data = Data(#"{"schemaVersion":99,"reportingTimeZoneID":"UTC","trackingStartedAt":"2026-07-25T00:00:00Z","partialIntervals":[]}"#.utf8)
        try data.write(to: paths.apiUsageMetadataFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiUsageMetadataFile.path)
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        do {
            _ = try await store.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(try Data(contentsOf: paths.apiUsageMetadataFile), data)
        }
    }

    func testFlushDoesNotOverwriteFutureSchemaInstalledAfterCacheLoad() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: .max)
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")
        try await store.flush()
        try await store.merge([.aggregate(makeAggregate(timestamp: at, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: at)])
        try await store.flush()
        try await store.merge([.issue(.init(timestamp: at, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting))])

        let file = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        let future = Data(#"{"schemaVersion":99,"month":"2026-07","reportingTimeZoneID":"UTC","buckets":[],"issues":[]}"#.utf8)
        try future.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        do {
            try await store.flush()
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(try Data(contentsOf: file), future)
        }
    }

    func testOverflowMarksEveryDiscardedMutationDayPartial() async throws {
        let paths = try makePaths()
        let day24 = iso("2026-07-24T04:00:00Z")
        let day25 = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")
        try await initial.flush()

        let overflowInput = makeAggregate(timestamp: day25, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        let key = APIUsageLedgerBucketKey(localDate: "2026-07-25", profileID: overflowInput.profileID, provider: overflowInput.provider, model: overflowInput.model, effectiveServiceTier: overflowInput.effectiveServiceTier, pricingVariant: overflowInput.pricingVariant, priceEpochStart: day25)
        let maxBucket = APIUsageLedgerBucket(key: key, uncachedInputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, nonReasoningOutputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, requestCount: .max, failedRequestCount: 0, firstObservedAt: day25, lastObservedAt: day25)
        let seeded = APIUsageMonthlyLedger(schemaVersion: 1, month: "2026-07", reportingTimeZoneID: "UTC", buckets: [maxBucket])
        try JSONEncoder.apiUsage.encode(seeded).write(to: paths.apiUsageMonthlyLedgerFile(month: "2026-07"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiUsageMonthlyLedgerFile(month: "2026-07").path)

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let normalInput = makeAggregate(timestamp: day24, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        do {
            try await restored.merge([
                .aggregate(normalInput, priceEpochStart: day24),
                .aggregate(overflowInput, priceEpochStart: day25)
            ])
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .persistenceFailure)
        }
        try await restored.flush()

        let read = try await restored.readCurrentPeriods(at: day25)
        XCTAssertFalse(read.currentMonth.buckets.contains { $0.key.localDate == "2026-07-24" })
        let failures = read.metadata.partialIntervals.filter { $0.reason == .persistenceFailure }
        for timestamp in [day24, day25] {
            let bounds = APIUsagePeriodCalculator.bounds(at: timestamp, timeZoneID: "UTC")
            XCTAssertTrue(failures.contains {
                $0.start < bounds.dayEnd && ($0.end ?? .distantFuture) > bounds.dayStart
            })
        }
    }

    func testCorruptBackupExclusiveMoveDoesNotReplaceRacingDestination() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await initial.flush()
        let source = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try Data("not-json".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        let collision = BackupCollisionHook()
        let restored = APIUsageLedgerStore(
            paths: paths,
            writeDelayNanoseconds: 0,
            beforeCorruptBackupMove: { try collision.install(at: $0) }
        )
        _ = try await restored.readCurrentPeriods(at: at)
        try await restored.flush()

        let occupied = try XCTUnwrap(collision.installedURL())
        XCTAssertEqual(try Data(contentsOf: occupied), BackupCollisionHook.sentinel)
        XCTAssertEqual(fileMode(occupied), 0o600)
        let backups = try FileManager.default.contentsOfDirectory(at: paths.apiUsageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("2026-07.corrupt-") }
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { fileMode($0) == 0o600 })
    }
}
```

- [ ] **Step 2: issue bucket와 debounce tests 추가**

```swift
func testIssueInputsAggregateByDateProfileAndReason() async throws {
    let paths = try makePaths()
    let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
    let at = iso("2026-07-25T05:00:00Z")
    try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")
    let issue = APIUsageIssueInput(timestamp: at, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting)
    try await store.merge([.issue(issue), .issue(issue)])
    try await store.flush()
    let read = try await store.readCurrentPeriods(at: at)
    XCTAssertEqual(read.currentMonth.issues.first?.count, 2)
}

private func makePaths() throws -> ManagedPaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("APIUsageLedgerStoreTests")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return ManagedPaths(rootDirectory: root)
}

private func iso(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func fileMode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        .map { $0 & 0o777 }
}

private func makeAggregate(timestamp: Date, profileID: String, provider: APIUsageProvider, model: String) -> APIUsageAggregateInput {
    let input = APIUsageTokenInputBreakdown(totalTokens: 10, uncachedTokens: 7, cacheReadTokens: 2, cacheWriteTokens: 1)
    let output = APIUsageTokenOutputBreakdown(totalTokens: 20, nonReasoningTokens: 15, reasoningTokens: 5)
    let breakdown = APIUsageTokenBreakdown(schemaVersion: 2, quality: .complete, totalTokens: 30, input: input, output: output, unclassifiedTokens: 0)
    return APIUsageAggregateInput(timestamp: timestamp, profileID: profileID, provider: provider, model: model, effectiveServiceTier: "standard", pricingVariant: .standard, tokenBreakdown: breakdown, failed: false)
}

private final class BackupCollisionHook: @unchecked Sendable {
    static let sentinel = Data("existing-backup".utf8)
    private let lock = NSLock()
    private var installed: URL?

    func install(at url: URL) throws {
        try lock.withLock {
            guard installed == nil else { return }
            try Self.sentinel.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            installed = url
        }
    }

    func installedURL() -> URL? {
        lock.withLock { installed }
    }
}
```

- [ ] **Step 3: 실패 확인**

Run: `swift test --filter APIUsageLedgerStoreTests`
Expected: FAIL — store/protocol/mutation 없음.

- [ ] **Step 4: store protocol과 mutation 구현**

```swift
public enum APIUsageLedgerMutation: Equatable, Sendable {
    case aggregate(APIUsageAggregateInput, priceEpochStart: Date?)
    case issue(APIUsageIssueInput)
}

public enum APIUsageLedgerStoreError: Error, Equatable, Sendable {
    case notInitialized
    case unsupportedSchemaVersion(Int)
    case invalidFile
    case persistenceFailure
}

public protocol APIUsageLedgerStoring: Sendable {
    func prepareTracking(at: Date, reportingTimeZoneID: String) async throws
    func merge(_ mutations: [APIUsageLedgerMutation]) async throws
    func markPaused(at: Date, proxyCouldServeRequests: Bool) async throws
    func markResumed(at: Date) async throws
    func markCollectionGap(from: Date, to: Date) async throws
    func markSuccessfulDrain(at: Date, lastObservedRequestAt: Date?) async throws
    func readCurrentPeriods(at: Date) async throws -> APIUsageLedgerReadModel
    func flush() async throws
}
```

`readCurrentPeriods`는 metadata file이 없으면 `.notInitialized`를 throw하고 `prepareTracking`만 최초 metadata를 생성한다. `public actor APIUsageLedgerStore`는 다음 initializer와 in-memory metadata, `[String: APIUsageMonthlyLedger]` cache, dirty metadata/month set, pending write task를 가진다.

```swift
public init(
    paths: ManagedPaths = ManagedPaths(),
    fileManager: FileManager = .default,
    writeDelayNanoseconds: UInt64 = 1_000_000_000,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
)
```


- [ ] **Step 5: merge와 partial interval 규칙 구현**

Aggregate mutation은 stored timezone으로 timestamp의 `localDate`/`month`를 만들고 exact bucket key를 찾는다. 새 bucket 생성 또는 다음 integer checked-add를 수행한다:

```swift
bucket.uncachedInputTokens += input.tokenBreakdown.input.uncachedTokens
bucket.cacheReadTokens += input.tokenBreakdown.input.cacheReadTokens
bucket.cacheWriteTokens += input.tokenBreakdown.input.cacheWriteTokens
bucket.nonReasoningOutputTokens += input.tokenBreakdown.output.nonReasoningTokens
bucket.reasoningOutputTokens += input.tokenBreakdown.output.reasoningTokens
bucket.totalTokens += input.tokenBreakdown.totalTokens
bucket.requestCount += 1
bucket.failedRequestCount += input.failed ? 1 : 0
bucket.firstObservedAt = min(bucket.firstObservedAt, input.timestamp)
bucket.lastObservedAt = max(bucket.lastObservedAt, input.timestamp)
```

overflow는 persistence failure로 처리한다. Merge가 atomic candidate 전체를 폐기하므로 batch를 처리하기 전에 모든 mutation의 stored-time-zone local day를 수집하고, overflow 시 commit되지 않은 모든 mutation day에 `.persistenceFailure` partial interval을 기록한다. `markPaused(at:proxyCouldServeRequests:)`는 `true`일 때만 `collectorPausedAt`을 시작하고, `false`이면 요청 누락 가능성이 없으므로 open pause를 만들지 않는다. `markResumed`는 open `collectorPausedAt`이 있을 때 `[pausedAt,resumedAt]` `.trackingWasDisabled` interval을 추가하고 field를 nil로 만든다. `markCollectionGap`과 pause/resume interval은 같은 reason의 겹치거나 맞닿은 interval을 union해 중복 metadata 증가를 막는다. issue mutation은 date/profile/provider/reason key로 count를 증가시킨다. 첫 metadata 생성 시 tracking instant가 month start보다 늦으면 `.trackingStartedMidPeriod` interval을 `[monthStart, trackingStartedAt]`으로 기록한다. overlap 판정은 `interval.start < periodEnd && (interval.end ?? now) > periodStart`의 strict comparison을 사용하므로 local midnight에 시작한 경우 새 Day는 complete이고, 다음 month에서는 이 interval이 더 이상 겹치지 않는다.

- [ ] **Step 6: secure atomic writer 구현**

Darwin `mkdir/chmod/open(O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600)/fchmod/write/fsync/rename`을 사용한다. directory는 `0700`; 기존 file은 regular file, current uid, `0600`인지 검증한다. 같은 directory의 `.store.lock`을 `0600`, `O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC`로 열고 descriptor를 검증한 뒤 `flock(LOCK_EX)`를 사용해 metadata/month target schema 재검사부터 atomic rename까지 serialize한다. Existing target의 version envelope를 lock 안에서 다시 읽고 current version보다 높으면 `.unsupportedSchemaVersion`으로 중단한다. JSONEncoder는 `.sortedKeys`, `.iso8601` date strategy를 사용한다. raw corrupt bytes를 message/log에 넣지 않는다. Corrupt month move는 `renamex_np(..., RENAME_EXCL)` 또는 동등한 exclusive rename을 사용해 destination이 생겼으면 `EEXIST`에서 다음 suffix로 재시도하며, 기존 backup을 절대 교체하지 않는다. 테스트 전용 internal initializer는 `beforeCorruptBackupMove: @escaping @Sendable (URL) throws -> Void` hook을 추가할 수 있고 public initializer 계약은 유지한다.

- [ ] **Step 7: 테스트 통과 확인**

Run: `swift test --filter APIUsageLedgerStoreTests`
Expected: PASS.

- [ ] **Step 8: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APIUsageLedgerStore.swift Tests/CLIProxyManagerCoreTests/APIUsageLedgerStoreTests.swift
git commit -m "feat: persist owner-only API usage ledgers"
```

---

## Task 7: Decimal cost estimator와 Core state

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APICostEstimator.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APICostEstimatorTests.swift`

**Interfaces:**
- Consumes: `APIUsageLedgerReadModel`, `APIPriceCatalog`, enabled provider/profile map.
- Produces: `APICostPeriod`, `APICostPeriodSnapshot`, `APICostSnapshot`, `APICostIssue`, `APICostUsageState`.
- Produces: `APICostEstimator.states(for:ledger:now:)`.

- [ ] **Step 1: cost/issue tests 작성**

```swift
final class APICostEstimatorTests: XCTestCase {
    func testClaudeCostUsesDecimalAndDoesNotDoubleCountReasoning() throws {
        let ledger = readModel(bucket: makeBucket(provider: .claude, model: "claude-opus-5", uncached: 1_000_000, read: 1_000_000, write: 1_000_000, nonReasoning: 500_000, reasoning: 500_000, requests: 2))
        let state = APICostEstimator(catalog: .current).states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"]
        guard case let .partial(snapshot, issues) = state else { return XCTFail("Expected assumptions to be partial") }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "36.75")) // 5 + 0.5 + 6.25 + 25
        XCTAssertEqual(snapshot.day.totalTokens, 4_000_000)
        XCTAssertEqual(snapshot.day.requestCount, 2)
        XCTAssertTrue(issues.contains(.cacheWriteTTLAssumedDefault))
        XCTAssertTrue(issues.contains(.inferenceGeoAssumedGlobal))
        XCTAssertTrue(issues.contains(.fastModeAssumedStandard))
        XCTAssertEqual(snapshot.day.issues, issues)
        XCTAssertEqual(snapshot.month.issues, issues)
    }

    func testOpenAICacheWriteUsesItsSeparatePublishedRate() {
        let ledger = readModel(bucket: makeBucket(provider: .openAI, model: "gpt-5.6-terra", uncached: 1_000_000, read: 1_000_000, write: 1_000_000, nonReasoning: 500_000, reasoning: 500_000, requests: 1))
        let state = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]
        guard case let .available(snapshot) = state else { return XCTFail("Expected available") }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "20.875"))
    }

    func testMissingCacheRateKeepsKnownCostAndMarksRequestUnpriced() {
        let ledger = readModel(bucket: makeBucket(provider: .openAI, model: "gpt-5.4", uncached: 1_000_000, write: 1_000_000, requests: 1))
        let state = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]
        guard case let .partial(snapshot, issues) = state else { return XCTFail("Expected partial") }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 1)
        XCTAssertTrue(issues.contains(.unknownPricingVariant))
    }

    func testUnknownModelKeepsKnownTotalsAndMarksRequestsUnpriced() {
        let ledger = readModel(bucket: makeBucket(provider: .openAI, model: "gpt-unknown", uncached: 100, requests: 3))
        let state = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]
        guard case let .partial(snapshot, issues) = state else { return XCTFail("Expected partial") }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 0)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 3)
        XCTAssertTrue(issues.contains(.unknownModel))
    }

    func testUnavailablePriceEpochIsDistinctFromUnknownVariant() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 100,
            requests: 2,
            priceEpochStart: nil
        ))
        let futureEntry = APIPriceEntry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standard,
            effectiveFrom: ISO8601DateFormatter().date(from: "2026-07-26T00:00:00Z")!,
            effectiveUntil: nil,
            rates: .init(
                uncachedInputUSDPerMillion: 1,
                cacheReadUSDPerMillion: nil,
                cacheWriteUSDPerMillion: nil,
                outputUSDPerMillion: 1
            )
        )
        let state = APICostEstimator(catalog: .init(version: 1, entries: [futureEntry]))
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]
        guard case let .partial(snapshot, issues) = state else { return XCTFail("Expected partial") }
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
        XCTAssertTrue(issues.contains(.priceEpochUnavailable))
        XCTAssertFalse(issues.contains(.unknownPricingVariant))
    }

    func testExactZeroIsAvailableWhenTrackingCoversWholePeriodAndNoRequestsExist() {
        let ledger = completeEmptyReadModel()
        let state = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]
        guard case let .available(snapshot) = state else { return XCTFail("Expected available zero") }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.requestCount, 0)
    }

    func testInvalidStoredTimeZoneUsesUTCAndMarksBothPeriodsPartial() {
        let base = completeEmptyReadModel()
        var metadata = base.metadata
        metadata.reportingTimeZoneID = "Invalid/Zone"
        let bounds = APIUsagePeriodCalculator.bounds(at: base.bounds.intervalReference, timeZoneID: metadata.reportingTimeZoneID)
        let ledger = APIUsageLedgerReadModel(metadata: metadata, bounds: bounds, currentMonth: base.currentMonth)
        guard case let .partial(snapshot, issues) = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: bounds.intervalReference)["codex-api"] else { return XCTFail("Expected partial") }
        XCTAssertEqual(snapshot.reportingTimeZoneID, "UTC")
        XCTAssertEqual(snapshot.day.issues, [.invalidReportingTimeZone])
        XCTAssertEqual(snapshot.month.issues, [.invalidReportingTimeZone])
        XCTAssertEqual(issues, [.invalidReportingTimeZone])
    }

    func testPartialIntervalsAndIssueBucketsApplyOnlyWhenTheyOverlapPeriod() {
        let ledger = readModelWithCurrentCollectionGapAndIncompleteIssue()
        guard case let .partial(snapshot, issues) = APICostEstimator(catalog: .current).states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"] else { return XCTFail("Expected partial") }
        XCTAssertTrue(issues.contains(.collectionGap))
        XCTAssertTrue(issues.contains(.incompleteTokenAccounting))
        XCTAssertGreaterThan(snapshot.day.unpricedRequestCount, 0)
    }

    func testMonthOnlyPartialIntervalDoesNotLeakIntoDayIssues() {
        let ledger = readModelWithMonthOnlyTrackingGap()
        guard case let .partial(snapshot, issues) = APICostEstimator(catalog: .current).states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"] else { return XCTFail("Expected partial") }
        XCTAssertEqual(snapshot.day.issues, [])
        XCTAssertEqual(snapshot.month.issues, [.trackingStartedMidPeriod])
        XCTAssertEqual(issues, [.trackingStartedMidPeriod])
    }

    private func makeBucket(
        provider: APIUsageProvider,
        model: String,
        uncached: Int64,
        read: Int64 = 0,
        write: Int64 = 0,
        nonReasoning: Int64 = 0,
        reasoning: Int64 = 0,
        requests: Int64,
        priceEpochStart: Date? = ISO8601DateFormatter().date(from: "2026-07-25T00:00:00Z")
    ) -> APIUsageLedgerBucket {
        let at = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        return APIUsageLedgerBucket(
            key: .init(localDate: "2026-07-25", profileID: provider.profileID, provider: provider, model: model, effectiveServiceTier: provider == .claude ? "standard" : "default", pricingVariant: .standard, priceEpochStart: priceEpochStart),
            uncachedInputTokens: uncached, cacheReadTokens: read, cacheWriteTokens: write,
            nonReasoningOutputTokens: nonReasoning, reasoningOutputTokens: reasoning,
            totalTokens: uncached + read + write + nonReasoning + reasoning,
            requestCount: requests, failedRequestCount: 0,
            firstObservedAt: at, lastObservedAt: at
        )
    }

    private func readModel(bucket: APIUsageLedgerBucket) -> APIUsageLedgerReadModel {
        let at = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
        let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: "UTC")
        let metadata = APIUsageTrackingMetadata(schemaVersion: 1, reportingTimeZoneID: "UTC", trackingStartedAt: bounds.monthStart, lastSuccessfulDrainAt: at, lastObservedRequestAt: at, collectorPausedAt: nil, partialIntervals: [])
        let month = APIUsageMonthlyLedger(schemaVersion: 1, month: bounds.month, reportingTimeZoneID: "UTC", buckets: [bucket], issues: [])
        return .init(metadata: metadata, bounds: bounds, currentMonth: month)
    }

    private func completeEmptyReadModel() -> APIUsageLedgerReadModel {
        var model = readModel(bucket: makeBucket(provider: .openAI, model: "gpt-5.4", uncached: 0, requests: 0))
        model = .init(metadata: model.metadata, bounds: model.bounds, currentMonth: .init(schemaVersion: 1, month: model.bounds.month, reportingTimeZoneID: "UTC", buckets: [], issues: []))
        return model
    }

    private func readModelWithCurrentCollectionGapAndIncompleteIssue() -> APIUsageLedgerReadModel {
        let base = readModel(bucket: makeBucket(provider: .claude, model: "claude-opus-5", uncached: 10, requests: 1))
        var metadata = base.metadata
        metadata.partialIntervals = [.init(start: base.bounds.dayStart, end: base.bounds.intervalReference, reason: .collectionGap)]
        var month = base.currentMonth
        month.issues = [.init(localDate: base.bounds.localDate, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting, count: 2)]
        return .init(metadata: metadata, bounds: base.bounds, currentMonth: month)
    }

    private func readModelWithMonthOnlyTrackingGap() -> APIUsageLedgerReadModel {
        let base = readModel(bucket: makeBucket(provider: .openAI, model: "gpt-5.4", uncached: 10, requests: 1))
        var metadata = base.metadata
        metadata.partialIntervals = [.init(start: base.bounds.monthStart, end: base.bounds.dayStart, reason: .trackingStartedMidPeriod)]
        return .init(metadata: metadata, bounds: base.bounds, currentMonth: base.currentMonth)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter APICostEstimatorTests`
Expected: FAIL — estimator/state 없음.

- [ ] **Step 3: Core state declarations 구현**

```swift
public enum APICostPeriod: String, Equatable, Sendable { case day, month }

public struct APICostPeriodSnapshot: Equatable, Sendable {
    public let period: APICostPeriod
    public let estimatedUSD: Decimal
    public let totalTokens: Int64
    public let requestCount: Int64
    public let failedRequestCount: Int64
    public let pricedRequestCount: Int64
    public let unpricedRequestCount: Int64
    public let intervalStart: Date
    public let intervalEnd: Date
    public let issues: [APICostIssue]
}

public struct APICostSnapshot: Equatable, Sendable {
    public let profileID: String
    public let provider: APIUsageProvider
    public let day: APICostPeriodSnapshot
    public let month: APICostPeriodSnapshot
    public let reportingTimeZoneID: String
    public let updatedAt: Date
}

public enum APICostIssue: String, Codable, CaseIterable, Equatable, Sendable {
    case proxyUnavailable, managementKeyNotConfigured, managementKeyRejected, managementAPINotSupported
    case transientCollectionFailure, trackingStartedMidPeriod, collectionGap, trackingWasDisabled
    case unsupportedAccountingVersion, incompleteTokenAccounting, unknownProviderMapping, unknownModel, unsupportedServiceTier
    case unknownPricingVariant, priceEpochUnavailable, cacheWriteTTLAssumedDefault, inferenceGeoAssumedGlobal, fastModeAssumedStandard
    case unsupportedLedgerVersion, corruptedLedger, persistenceFailure, invalidReportingTimeZone
}
```

`APICostPeriodSnapshot`과 `APICostSnapshot`에는 위 field 순서와 동일한 label의 `public init`를 추가한다.

```swift
public enum APICostUsageState: Equatable, Sendable {
    case disabled
    case loading
    case available(APICostSnapshot)
    case partial(APICostSnapshot, [APICostIssue])
    case unavailable(APICostIssue)

    public var snapshot: APICostSnapshot? {
        switch self {
        case .available(let snapshot), .partial(let snapshot, _): snapshot
        case .disabled, .loading, .unavailable: nil
        }
    }

    public var issues: [APICostIssue] {
        switch self {
        case .partial(_, let issues): issues
        case .unavailable(let issue): [issue]
        case .disabled, .loading, .available: []
        }
    }
}
```

- [ ] **Step 4: Decimal estimator 구현**

`APICostEstimator`는 `public init(catalog: APIPriceCatalog = .current)`와 `public func states(for profiles: [APIUsageProvider: String], ledger: APIUsageLedgerReadModel, now: Date) -> [String: APICostUsageState]`를 제공한다. `APICostSnapshot.updatedAt`은 `metadata.lastSuccessfulDrainAt ?? metadata.trackingStartedAt`을 사용한다. Day snapshot은 `intervalStart = bounds.dayStart`, Mon snapshot은 `intervalStart = bounds.monthStart`, 두 snapshot의 `intervalEnd = min(now, 해당 calendar boundary)`로 둔다. 각 period에서 profile bucket을 합산한다. `priceEpochStart`가 있으면 provider/model/tier/variant와 exact `effectiveFrom`으로 entry를 찾고, nil이면 `[firstObservedAt,lastObservedAt]` 전체를 단 하나의 동일 active entry가 덮는 경우에만 가격을 적용한다. 관측 구간이 matching entry의 `effectiveFrom`, `effectiveUntil` 또는 active-entry gap을 가로지르거나 처음부터 active entry가 없으면 `.priceEpochUnavailable`을 추가하고 bucket을 unpriced 처리한다. entry가 있으면 다음 helper로 category cost를 더한다:

```swift
private func cost(tokens: Int64, rate: Decimal) -> Decimal {
    Decimal(tokens) * rate / Decimal(1_000_000)
}
```

Output cost는 `cost(tokens: nonReasoningOutputTokens, rate:) + cost(tokens: reasoningOutputTokens, rate:)`처럼 각 category를 Decimal로 변환한 뒤 더하여 reasoning을 한 번만 과금하면서 중간 `Int64` 합산 overflow도 피한다. nonzero cache-read 또는 cache-write token인데 해당 rate가 nil이면 다른 known category cost는 유지하되 bucket의 request count를 `unpricedRequestCount`로 세고 `.unknownPricingVariant`를 추가한다. catalog classification은 unknown model, unsupported tier, unknown variant, unavailable price epoch issue를 구분한다.

Estimator는 persisted data를 신뢰하지 않고 각 bucket을 합산 전에 검증한다. 모든 token/request count는 non-negative, `failedRequestCount <= requestCount`, checked category sum은 `totalTokens`와 일치, `firstObservedAt <= lastObservedAt`, `localDate`는 strict Gregorian `yyyy-MM-dd`이며 `currentMonth.month`에 속해야 한다. Issue bucket도 non-negative count와 같은 local-date 규칙을 만족해야 한다. 위반 항목은 합산에서 제외하고 Mon에 `.corruptedLedger`를 추가하며, localDate가 current Day와 같거나 malformed라 영향 범위를 좁힐 수 없으면 Day에도 추가한다. Mon은 `localDate`가 `bounds.month`에 속하는 valid 항목만 합산한다. 여러 valid bucket/issue의 token/request/count 합계는 `addingReportingOverflow`를 사용하고 overflow를 일으킨 항목을 제외한 뒤 해당 period에 `.corruptedLedger`를 추가한다. 따라서 public snapshot의 금액·token·count는 음수가 되거나 Int64 overflow로 trap하지 않는다.

Partial interval과 issue bucket을 Day/Mon interval에 겹치는 경우만 적용하고 각 결과를 해당 `APICostPeriodSnapshot.issues`에 저장한다. state-level `.partial(snapshot, issues)`의 `issues`는 Day/Mon issue의 중복 없는 union이며 `APICostIssue.allCases` 순서로 안정화한다. `profileID == nil`인 `.unknownProviderMapping` issue bucket은 어떤 API Key 계정인지 안전하게 판별할 수 없으므로 현재 enabled API provider state 모두에 `.unknownProviderMapping`과 unpriced count를 적용한다. invalid stored timezone이면 UTC bounds를 사용하고 snapshot `reportingTimeZoneID`도 `UTC`로 설정한 뒤 `.invalidReportingTimeZone`을 추가한다. Claude cache write, inference geography, request speed assumption issue를 ordered set에 추가한다. Guessing하는 version parser 대신 catalog의 explicit canonical model set을 사용한다: geo set은 `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-5`, `claude-sonnet-4-6`; speed set은 `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`이다.

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter APICostEstimatorTests`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APICostEstimator.swift Tests/CLIProxyManagerCoreTests/APICostEstimatorTests.swift
git commit -m "feat: estimate Day and month API costs"
```

---

## Task 8: Serialized collector actor, batching, polling, gap detection

**Files:**
- Create: `Sources/CLIProxyManagerCore/APIUsage/APIUsageCollector.swift`
- Test: `Tests/CLIProxyManagerCoreTests/APIUsageCollectorTests.swift`

**Interfaces:**
- Consumes: `APIUsageQueueFetching`, `APIUsageRecordMapper`, `APIUsageLedgerStoring`, `APIPriceCatalog`, `APICostEstimator`.
- Produces: `APIUsageCollectorConfiguration`, `APIUsageCollectionReport`, `APIUsageCollecting`.
- Produces: report stream and lifecycle methods `restore/start/update/reload/stop`.

- [ ] **Step 1: batch/serialization tests 작성**

```swift
final class APIUsageCollectorTests: XCTestCase {
    func testReloadDrainsFullBatchesUntilShortBatchAndMergesEachRecordOnce() async throws {
        let queue = RecordingQueueClient(batches: [Array(repeating: makeQueueRecord(), count: 200), [makeQueueRecord()]])
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger, now: { iso("2026-07-25T12:00:00Z") })
        let config = APIUsageCollectorConfiguration(usageEnabled: true, proxyReady: true, port: 18_317, enabledProviders: [.claude], reportingTimeZoneID: "Asia/Seoul")

        _ = await collector.reload(configuration: config)

        XCTAssertEqual(await queue.requestedCounts(), [200, 200])
        XCTAssertEqual(await ledger.aggregateMutationCount(), 201)
        XCTAssertEqual(await ledger.flushCount(), 1)
    }

    func testConcurrentReloadsAreSerializedWithoutDoubleMerge() async {
        let queue = SuspendedQueueClient(record: makeQueueRecord())
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)
        let config = enabledConfiguration()

        async let first = collector.reload(configuration: config)
        async let second = collector.reload(configuration: config)
        await queue.waitUntilSuspended()
        await queue.resumeAll()
        _ = await (first, second)

        XCTAssertEqual(await ledger.aggregateMutationCount(), 1)
    }
}
```

- [ ] **Step 2: lifecycle/security/gap tests 추가**

```swift
func testStopFlushesAndDoesNotDeleteLedger() async {
    let ledger = RecordingLedgerStore()
    let collector = APIUsageCollector(queueClient: RecordingQueueClient(batches: [[]]), ledgerStore: ledger)
    await collector.start(configuration: enabledConfiguration())
    await collector.stop(reason: .trackingDisabled(proxyCouldServeRequests: true), at: iso("2026-07-25T13:00:00Z"))
    XCTAssertEqual(await ledger.pauseCount(), 1)
    XCTAssertEqual(await ledger.flushCount(), 2) // first metadata flush + stop flush
    XCTAssertEqual(await ledger.deleteCount(), 0)
}

func testDisabledUsageBecomingProxyReadyStartsPartialPauseAtReadyTime() async {
    let ledger = RecordingLedgerStore()
    let now = iso("2026-07-25T12:00:00Z")
    let collector = APIUsageCollector(queueClient: RecordingQueueClient(batches: [[]]), ledgerStore: ledger, now: { now })
    let config = APIUsageCollectorConfiguration(usageEnabled: false, proxyReady: true, port: 18_317, enabledProviders: [.claude], reportingTimeZoneID: "UTC")

    await collector.update(configuration: config)

    XCTAssertEqual(await ledger.pauseCount(), 1)
}

func testCollectorMarksGapWhenLastDrainExceedsRetention() async {
    let ledger = RecordingLedgerStore(lastSuccessfulDrainAt: iso("2026-07-25T10:00:00Z"))
    let collector = APIUsageCollector(queueClient: RecordingQueueClient(batches: [[]]), ledgerStore: ledger, now: { iso("2026-07-25T12:00:01Z") })
    _ = await collector.reload(configuration: enabledConfiguration())
    XCTAssertEqual(await ledger.collectionGaps(), [.init(start: iso("2026-07-25T10:00:00Z"), end: iso("2026-07-25T12:00:01Z"))])
}

func testQueueFailuresKeepStoredSnapshotAndMapTypedIssue() async {
    let ledger = RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage())
    let queue = RecordingQueueClient(error: APIUsageQueueClientError.managementKeyRejected)
    let report = await APIUsageCollector(queueClient: queue, ledgerStore: ledger).reload(configuration: enabledConfiguration())
    guard case let .partial(snapshot, issues) = report.statesByProfileID["claude-api"] else { return XCTFail("Expected partial") }
    XCTAssertGreaterThan(snapshot.day.estimatedUSD, 0)
    XCTAssertTrue(snapshot.day.issues.contains(.managementKeyRejected))
    XCTAssertTrue(snapshot.month.issues.contains(.managementKeyRejected))
    XCTAssertTrue(issues.contains(.managementKeyRejected))
}

func testPoppedBatchMergeFailureKeepsStoredSnapshotAndMarksPersistenceFailure() async {
    let ledger = RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage(), mergeError: .persistenceFailure)
    let queue = RecordingQueueClient(batches: [[makeQueueRecord()]])
    let report = await APIUsageCollector(queueClient: queue, ledgerStore: ledger).reload(configuration: enabledConfiguration())
    guard case let .partial(snapshot, issues) = report.statesByProfileID["claude-api"] else { return XCTFail("Expected partial") }
    XCTAssertGreaterThan(snapshot.day.estimatedUSD, 0)
    XCTAssertTrue(snapshot.day.issues.contains(.persistenceFailure))
    XCTAssertTrue(snapshot.month.issues.contains(.persistenceFailure))
    XCTAssertTrue(issues.contains(.persistenceFailure))
}

private struct RecordedGap: Equatable { let start: Date; let end: Date }

private actor RecordingQueueClient: APIUsageQueueFetching {
    private var batches: [[APIUsageQueueRecord]]
    private let error: APIUsageQueueClientError?
    private var counts: [Int] = []

    init(batches: [[APIUsageQueueRecord]] = [], error: APIUsageQueueClientError? = nil) {
        self.batches = batches
        self.error = error
    }

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        counts.append(count)
        if let error { throw error }
        return batches.isEmpty ? [] : batches.removeFirst()
    }

    func requestedCounts() -> [Int] { counts }
}

private actor SuspendedQueueClient: APIUsageQueueFetching {
    private let record: APIUsageQueueRecord
    private var continuation: CheckedContinuation<[APIUsageQueueRecord], Error>?

    init(record: APIUsageQueueRecord) { self.record = record }

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while continuation == nil { await Task.yield() }
    }

    func resumeAll() {
        continuation?.resume(returning: [record])
        continuation = nil
    }
}

private actor RecordingLedgerStore: APIUsageLedgerStoring {
    private var readModel: APIUsageLedgerReadModel
    private let mergeError: APIUsageLedgerStoreError?
    private var mutations: [APIUsageLedgerMutation] = []
    private var flushes = 0
    private var pauses = 0
    private var gaps: [RecordedGap] = []

    init(lastSuccessfulDrainAt: Date? = nil, readModel: APIUsageLedgerReadModel? = nil, mergeError: APIUsageLedgerStoreError? = nil) {
        self.readModel = readModel ?? emptyReadModel(lastSuccessfulDrainAt: lastSuccessfulDrainAt)
        self.mergeError = mergeError
    }

    func prepareTracking(at: Date, reportingTimeZoneID: String) async throws {}
    func merge(_ values: [APIUsageLedgerMutation]) async throws {
        if let mergeError { throw mergeError }
        mutations.append(contentsOf: values)
    }
    func markPaused(at: Date, proxyCouldServeRequests: Bool) async throws { pauses += 1 }
    func markResumed(at: Date) async throws {}
    func markCollectionGap(from: Date, to: Date) async throws { gaps.append(.init(start: from, end: to)) }
    func markSuccessfulDrain(at: Date, lastObservedRequestAt: Date?) async throws {
        var metadata = readModel.metadata
        metadata.lastSuccessfulDrainAt = at
        metadata.lastObservedRequestAt = lastObservedRequestAt
        readModel = .init(metadata: metadata, bounds: readModel.bounds, currentMonth: readModel.currentMonth)
    }
    func readCurrentPeriods(at: Date) async throws -> APIUsageLedgerReadModel { readModel }
    func flush() async throws { flushes += 1 }

    func aggregateMutationCount() -> Int { mutations.reduce(0) { count, mutation in if case .aggregate = mutation { count + 1 } else { count } } }
    func flushCount() -> Int { flushes }
    func pauseCount() -> Int { pauses }
    func deleteCount() -> Int { 0 }
    func collectionGaps() -> [RecordedGap] { gaps }
}

private func enabledConfiguration() -> APIUsageCollectorConfiguration {
    .init(usageEnabled: true, proxyReady: true, port: 18_317, enabledProviders: [.claude], reportingTimeZoneID: "UTC")
}

private func iso(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

private func makeQueueRecord() -> APIUsageQueueRecord {
    let data = Data(#"{"timestamp":"2026-07-25T12:00:00Z","provider":"claude","executor_type":"ClaudeExecutor","model":"claude-opus-5","alias":"cpm-claude-api/claude-opus-5","auth_type":"apikey","auth_index":"auth-1","failed":false,"accounting_version":2,"token_breakdown":{"schema_version":2,"quality":"complete","total_tokens":30,"input":{"total_tokens":10,"uncached_tokens":10,"cache_read_tokens":0,"cache_write_tokens":0},"output":{"total_tokens":20,"non_reasoning_tokens":20,"reasoning_tokens":0},"unclassified_tokens":0},"service_tier":"standard"}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(APIUsageQueueRecord.self, from: data)
}

private func emptyReadModel(lastSuccessfulDrainAt: Date?) -> APIUsageLedgerReadModel {
    let at = iso("2026-07-25T12:00:00Z")
    let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: "UTC")
    let metadata = APIUsageTrackingMetadata(schemaVersion: 1, reportingTimeZoneID: "UTC", trackingStartedAt: bounds.monthStart, lastSuccessfulDrainAt: lastSuccessfulDrainAt, lastObservedRequestAt: nil, collectorPausedAt: nil, partialIntervals: [])
    return .init(metadata: metadata, bounds: bounds, currentMonth: .init(schemaVersion: 1, month: bounds.month, reportingTimeZoneID: "UTC", buckets: [], issues: []))
}

private func readModelWithPricedClaudeUsage() -> APIUsageLedgerReadModel {
    let base = emptyReadModel(lastSuccessfulDrainAt: iso("2026-07-25T11:59:00Z"))
    let bucket = APIUsageLedgerBucket(key: .init(localDate: base.bounds.localDate, profileID: "claude-api", provider: .claude, model: "claude-opus-5", effectiveServiceTier: "standard", pricingVariant: .standard, priceEpochStart: iso("2026-07-25T00:00:00Z")), uncachedInputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0, nonReasoningOutputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000_000, requestCount: 1, failedRequestCount: 0, firstObservedAt: base.bounds.intervalReference, lastObservedAt: base.bounds.intervalReference)
    return .init(metadata: base.metadata, bounds: base.bounds, currentMonth: .init(schemaVersion: 1, month: base.bounds.month, reportingTimeZoneID: "UTC", buckets: [bucket], issues: []))
}
```

- [ ] **Step 3: 실패 확인**

Run: `swift test --filter APIUsageCollectorTests`
Expected: FAIL — collector interfaces 없음.

- [ ] **Step 4: public configuration/report/protocol 구현**

```swift
public struct APIUsageCollectorConfiguration: Equatable, Sendable {
    public let usageEnabled: Bool
    public let proxyReady: Bool
    public let port: Int
    public let enabledProviders: Set<APIUsageProvider>
    public let reportingTimeZoneID: String
}

public struct APIUsageCollectionReport: Equatable, Sendable {
    public let statesByProfileID: [String: APICostUsageState]
    public let collectedAt: Date
}
```

`APIUsageCollectorConfiguration`과 `APIUsageCollectionReport`에 위 field 순서와 동일한 label의 `public init`를 추가한다.

```swift
public enum APIUsageCollectorStopReason: Equatable, Sendable {
    case trackingDisabled(proxyCouldServeRequests: Bool)
    case applicationTermination
}

public protocol APIUsageCollecting: Sendable {
    func reports() async -> AsyncStream<APIUsageCollectionReport>
    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func start(configuration: APIUsageCollectorConfiguration) async
    func update(configuration: APIUsageCollectorConfiguration) async
    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport
    func stop(reason: APIUsageCollectorStopReason, at: Date) async
}
```

- [ ] **Step 5: actor drain 구현**

`APIUsageCollector`는 다음 public initializer를 제공한다.

```swift
public init(
    queueClient: any APIUsageQueueFetching = CLIProxyAPIUsageQueueClient(),
    ledgerStore: any APIUsageLedgerStoring = APIUsageLedgerStore(),
    mapper: APIUsageRecordMapper = APIUsageRecordMapper(),
    catalog: APIPriceCatalog = .current,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
)
```

`APIUsageCollector`는 `reloadTask: Task<APIUsageCollectionReport,Never>?`를 actor-isolated로 두어 concurrent reload callers가 같은 task value를 await하게 한다. reload 시작 시 ledger metadata를 읽고 `proxyReady == true`, `lastSuccessfulDrainAt != nil`, `now - lastSuccessfulDrainAt > 3_600`이면 pop 전에 `markCollectionGap(from:lastSuccessfulDrainAt,to:now)`를 호출한다. 한 pass는 최대 2,000 records, batch size 200이다. batch response를 받은 뒤 cancellation을 검사하기 전에 mapper→catalog epoch→ledger merge를 완료한다. pop 후 merge 전 record를 버리지 않는다.

```swift
while processed < 2_000 {
    let records = try await queueClient.popUsage(port: configuration.port, count: 200)
    let mutations = records.compactMap(makeMutation)
    try await ledgerStore.merge(mutations)
    processed += records.count
    if records.count < 200 { break }
}
try await ledgerStore.markSuccessfulDrain(at: now(), lastObservedRequestAt: latestTimestamp)
if flushAfterDrain {
    try await ledgerStore.flush()
}

private func makeMutation(_ record: APIUsageQueueRecord) -> APIUsageLedgerMutation? {
    switch mapper.classify(record) {
    case .ignored:
        return nil
    case .issue(let issue):
        return .issue(issue)
    case .aggregate(let input):
        let epoch = catalog.entry(provider: input.provider, model: input.model, serviceTier: input.effectiveServiceTier, variant: input.pricingVariant, at: input.timestamp)?.effectiveFrom
        return .aggregate(input, priceEpochStart: epoch)
    }
}
```

Public `reload`은 `flushAfterDrain: true`, startup/polling drain은 `false`를 사용해 1초 store debounce를 유지한다. API Key가 없는 provider record와 OAuth는 mapper가 `.ignored`로 제거한다. queue error는 `.managementKeyNotConfigured`→동명 issue, `.managementKeyRejected`→동명 issue, `.managementAPINotSupported`/`.schemaMismatch`/`.invalidCount`→`.managementAPINotSupported`, `.invalidPort`/`.proxyUnavailable`→`.proxyUnavailable`, `.transientFailure`→`.transientCollectionFailure`로 매핑한다. snapshot이 있으면 해당 issue를 Day/Mon `APICostPeriodSnapshot.issues` 양쪽에 `APICostIssue.allCases` 순서로 추가하고 state-level 배열을 두 period의 stable union으로 다시 만든다. snapshot이 없으면 `.unavailable(issue)`이다. `APIUsageLedgerStoreError.notInitialized`는 `.loading`, `.unsupportedSchemaVersion`은 `.unsupportedLedgerVersion`, 다른 read/write 오류는 `.persistenceFailure`로 같은 방식으로 매핑하며 future-version file을 overwrite하지 않는다.

- [ ] **Step 6: polling/stream 구현**

`stop(reason:.trackingDisabled)`은 polling을 취소하고 `markPaused(at:proxyCouldServeRequests:)` 후 flush한다. `.applicationTermination`은 partial interval을 만들지 않고 pending write만 flush한다. `reports()`는 한 subscriber용 `AsyncStream`을 반환하고 continuation termination에서 제거한다. `restore`는 network를 호출하지 않는다: disabled면 configured provider profile마다 `.disabled`, metadata가 아직 없으면 `.loading`, ledger가 있으면 estimator state를 반환한다. `start`는 metadata prepare→최초 metadata flush→resume→immediate drain→poll task 시작 순서다. success는 30초, `.transientFailure`와 `.proxyUnavailable`은 60→120→240→480→900초로 backoff한다. management key/configuration/schema/unsupported-route 오류는 자동 retry를 중단하고 다음 explicit `update`, server transition, API key change, 또는 `reload`가 새 drain을 시작하게 한다. full 2,000-record pass는 sleep 없이 다음 pass를 수행한다. `update`가 usage disabled이면 현재 proxy readiness로 `.trackingDisabled` stop을 기록한다. API key provider set만 비어 있고 Usage 자체는 enabled이면 poll을 중지하되 partial interval을 만들지 않는다. 따라서 Usage가 꺼진 채 proxy가 stopped→ready로 바뀌는 update도 그 ready 시점부터 pause interval을 시작한다. Usage가 enabled이지만 proxy not ready이면 stored report에 `.proxyUnavailable`을 merge하고 network call을 하지 않는다. not-ready→ready 전환, port 변경, enabled provider 추가 시에는 polling deadline을 기다리지 않고 immediate drain을 실행한다.

- [ ] **Step 7: 테스트 통과 확인**

Run: `swift test --filter APIUsageCollectorTests`
Expected: PASS.

- [ ] **Step 8: 커밋**

```bash
git add Sources/CLIProxyManagerCore/APIUsage/APIUsageCollector.swift Tests/CLIProxyManagerCoreTests/APIUsageCollectorTests.swift
git commit -m "feat: collect API usage with serialized polling"
```

---

## Task 9: Provider usage sum type와 API cost presentation

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/ProviderUsageState.swift`
- Create: `Sources/CLIProxyManagerApp/Models/APICostUsagePresentation.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift:31-82`
- Modify: `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift:3-73`
- Modify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift:62-143`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` (row initializer labels only; collector lifecycle remains Task 10)
- Test: `Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift`
- Modify tests: `CompactUsagePresentationTests.swift`, `MenuBarStatusSnapshotTests.swift`, `ProviderSettingsViewModelTests.swift:20-33`

**Interfaces:**
- Consumes: subscription/API Core states.
- Produces: `ProviderUsageState`, `ProviderUsageDisplayState`, `APICostRowPresentation`.
- Produces: `compactUsagePresentation(for: ProviderUsageState)` and currency/token/tooltip formatters.

- [ ] **Step 1: presentation tests 작성**

```swift
final class APICostUsagePresentationTests: XCTestCase {
    func testCompactPresentationShowsDayAndMonthCostOnly() {
        let state = ProviderUsageState.apiCost(.available(makeCostSnapshot(dayCost: "0.004", monthCost: "8.73")))
        let presentation = compactUsagePresentation(for: state)
        XCTAssertEqual(presentation.rows.map(\.label), ["Day", "Mon"])
        XCTAssertEqual(presentation.rows.map(\.value), ["<$0.01", "$8.73"])
        XCTAssertFalse(presentation.rows.flatMap { [$0.label, $0.value] }.contains { $0.contains("TOK") || $0.contains("REQ") })
    }

    func testExpandedRowsIncludeCompactTokensRequestsAndExactTooltip() {
        let snapshot = makeCostSnapshot(dayCost: "0.42", monthCost: "8.73", dayTokens: 84_000, dayRequests: 14, timeZone: "Asia/Seoul", dayIssues: [.trackingStartedMidPeriod])
        let rows = apiCostRows(snapshot: snapshot)
        XCTAssertEqual(rows[0].label, "Day")
        XCTAssertEqual(rows[0].detail, "84K TOK · 14 REQ")
        XCTAssertEqual(rows[0].cost, "$0.42")
        XCTAssertTrue(rows[0].tooltip.contains("Estimated API cost"))
        XCTAssertTrue(rows[0].tooltip.contains("Asia/Seoul"))
        XCTAssertTrue(rows[0].tooltip.contains("Earlier usage"))
    }

    func testCurrencyFormattingDistinguishesZeroTinyAndNormal() {
        XCTAssertEqual(apiCostCurrency(0), "$0.00")
        XCTAssertEqual(apiCostCurrency(Decimal(string: "0.0001")!), "<$0.01")
        XCTAssertEqual(apiCostCurrency(Decimal(string: "12.345")!), "$12.35")
    }

    private func makeCostSnapshot(
        dayCost: String = "0.42",
        monthCost: String = "8.73",
        dayTokens: Int64 = 84_000,
        dayRequests: Int64 = 14,
        timeZone: String = "UTC",
        dayIssues: [APICostIssue] = [],
        monthIssues: [APICostIssue] = []
    ) -> APICostSnapshot {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let day = APICostPeriodSnapshot(period: .day, estimatedUSD: Decimal(string: dayCost)!, totalTokens: dayTokens, requestCount: dayRequests, failedRequestCount: 0, pricedRequestCount: dayRequests, unpricedRequestCount: 0, intervalStart: start, intervalEnd: end, issues: dayIssues)
        let month = APICostPeriodSnapshot(period: .month, estimatedUSD: Decimal(string: monthCost)!, totalTokens: 1_800_000, requestCount: 218, failedRequestCount: 0, pricedRequestCount: 218, unpricedRequestCount: 0, intervalStart: start, intervalEnd: end, issues: monthIssues)
        return APICostSnapshot(profileID: "claude-api", provider: .claude, day: day, month: month, reportingTimeZoneID: timeZone, updatedAt: end)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter 'APICostUsagePresentationTests|CompactUsagePresentationTests|MenuBarStatusSnapshotTests|ProviderSettingsViewModelTests'`
Expected: FAIL — provider usage/presentation API 없음.

- [ ] **Step 3: sum type와 row model 전환**

```swift
enum ProviderUsageState: Equatable {
    case subscription(AccountSubscriptionUsageState)
    case apiCost(APICostUsageState)
}
```

`ProviderRowState`와 `MenuBarConnectedProvider`의 stored `subscriptionUsageState`를 `usageState`, `showsSubscriptionUsage`를 `showsUsage`로 바꾼다. `ProviderRowState` initializer default는 `.subscription(.disabled)`와 `showsUsage: true`다. Task 11/12에서 view call site를 순차 전환할 때까지 두 model에 read-only compatibility projection을 둔다: subscription case는 associated state/`showsUsage`를 반환하고 API case는 `.disabled`/`false`를 반환한다. `DashboardViewModel.rebuildProviderRows`의 OAuth initializer는 `.subscription(existingState)`, API Key initializer는 Task 10 전까지 `.apiCost(.disabled)`를 사용한다. `MenuBarStatusSnapshot` initializer label은 persisted setting 의미를 반영해 `showsUsage:`로 바꾸고 provider capability와 AND하며, 기존 view가 컴파일되도록 default가 없는 `showsSubscriptionUsage:` forwarding overload를 Task 12까지 유지한다. `ProviderSettingsViewModelTests.testConfiguredAPIKeysAppearAsProviderRows`의 마지막 assertion은 `apiRows.map(\.usageState) == [.apiCost(.disabled), .apiCost(.disabled)]`로 바꾼다.

```swift
extension ProviderUsageState {
    var subscriptionCompatibilityState: AccountSubscriptionUsageState {
        guard case let .subscription(state) = self else { return .disabled }
        return state
    }

    var isSubscription: Bool {
        if case .subscription = self { return true }
        return false
    }
}

// Task 12에서 제거할 임시 projection.
extension ProviderRowState {
    var subscriptionUsageState: AccountSubscriptionUsageState {
        usageState.subscriptionCompatibilityState
    }
    var showsSubscriptionUsage: Bool {
        showsUsage && usageState.isSubscription
    }
}

extension MenuBarConnectedProvider {
    var subscriptionUsageState: AccountSubscriptionUsageState {
        usageState.subscriptionCompatibilityState
    }
    var showsSubscriptionUsage: Bool {
        showsUsage && usageState.isSubscription
    }
}

// Task 12에서 제거할 forwarding overload. 마지막 parameter에는 default를 두지 않는다.
extension MenuBarStatusSnapshot {
    init(
        serverStatus: DiagnosticStatus,
        serverControlState: ServerControlState = .stopped,
        providers: [ProviderRowState],
        port: Int = 18_317,
        showsSubscriptionUsage: Bool
    ) {
        self.init(
            serverStatus: serverStatus,
            serverControlState: serverControlState,
            providers: providers,
            port: port,
            showsUsage: showsSubscriptionUsage
        )
    }
}
```

- [ ] **Step 4: presentation helpers 구현**

`APICostUsagePresentation.swift`:

```swift
struct APICostRowPresentation: Equatable, Identifiable {
    let id: String
    let label: String
    let detail: String
    let cost: String
    let tooltip: String
    let accessibilityLabel: String
}

enum ProviderUsageDisplayState: Equatable {
    case hidden
    case loading(String)
    case unavailable(String)
    case subscription(SubscriptionUsageSnapshot, SubscriptionUsageIssue?)
    case apiCost(APICostSnapshot, [APICostIssue])
}
```

`providerUsageDisplayState(for:)`는 기존 subscription switch와 API cost switch를 한 곳에 둔다. `apiCostCurrency`, 4-decimal exact tooltip formatter, decimal compact token formatter(`84K`, `1.8M`), request pluralization을 구현한다. API issue message는 Core rawValue를 그대로 노출하지 않고 다음 exhaustive switch를 사용한다.

```swift
func apiCostIssueMessage(_ issue: APICostIssue) -> String {
    switch issue {
    case .proxyUnavailable: "Local proxy is unavailable."
    case .managementKeyNotConfigured: "Management key is not configured."
    case .managementKeyRejected: "Management key was rejected."
    case .managementAPINotSupported: "This CLIProxyAPI version does not support API usage collection."
    case .transientCollectionFailure: "API usage could not be collected."
    case .trackingStartedMidPeriod: "Earlier usage in this period is not included."
    case .collectionGap: "Some requests may be missing because collection was interrupted."
    case .trackingWasDisabled: "Requests made while usage tracking was disabled may be missing."
    case .unsupportedAccountingVersion: "Some requests use an unsupported accounting version."
    case .incompleteTokenAccounting: "Some requests did not provide complete token accounting."
    case .unknownProviderMapping: "Some API key requests could not be matched to a managed provider."
    case .unknownModel: "Some request models are not in the bundled price catalog."
    case .unsupportedServiceTier: "Some request service tiers are not priced."
    case .unknownPricingVariant: "Some request pricing variants are not priced."
    case .priceEpochUnavailable: "Some requests do not have a bundled price for their request date."
    case .cacheWriteTTLAssumedDefault: "Claude cache writes use the 5-minute cache rate because the queue does not expose TTL."
    case .inferenceGeoAssumedGlobal: "Claude costs use global pricing because the queue does not expose inference geography. US-only inference may cost 10% more."
    case .fastModeAssumedStandard: "Claude costs use standard-speed pricing because the queue does not expose request speed. Fast mode may cost more."
    case .unsupportedLedgerVersion: "The API usage ledger was created by a newer app version."
    case .corruptedLedger: "A damaged API usage ledger was recovered; this period may be incomplete."
    case .persistenceFailure: "API usage could not be saved completely."
    case .invalidReportingTimeZone: "The saved reporting time zone is unavailable; UTC is being used."
    }
}

func apiCostRows(snapshot: APICostSnapshot) -> [APICostRowPresentation] {
    [("day", "Day", snapshot.day), ("month", "Mon", snapshot.month)].map { id, label, period in
        let detail = "\(compactTokenCount(period.totalTokens)) TOK · \(period.requestCount) REQ"
        let range = apiCostPeriodRange(period, timeZoneID: snapshot.reportingTimeZoneID)
        var lines = [range, "Estimated API cost from requests observed through CLIProxyAPI.", "Exact estimate: \(apiCostExactCurrency(period.estimatedUSD))."]
        lines.append(contentsOf: period.issues.map(apiCostIssueMessage))
        if period.unpricedRequestCount > 0 {
            lines.append("\(period.unpricedRequestCount) requests could not be fully priced.")
        }
        return .init(
            id: id,
            label: label,
            detail: detail,
            cost: apiCostCurrency(period.estimatedUSD),
            tooltip: lines.joined(separator: "\n"),
            accessibilityLabel: "\(label), estimated API cost \(apiCostExactCurrency(period.estimatedUSD)), \(period.totalTokens) tokens, \(period.requestCount) requests"
        )
    }
}

private func apiCostPeriodRange(_ period: APICostPeriodSnapshot, timeZoneID: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "\(formatter.string(from: period.intervalStart))–\(formatter.string(from: period.intervalEnd)) · \(timeZoneID)"
}

func apiCostCurrency(_ value: Decimal) -> String {
    if value == 0 { return "$0.00" }
    if value > 0, value < Decimal(string: "0.01")! { return "<$0.01" }
    return currencyFormatter(minimum: 2, maximum: 2).string(from: NSDecimalNumber(decimal: value))!
}

func apiCostExactCurrency(_ value: Decimal) -> String {
    currencyFormatter(minimum: 4, maximum: 8).string(from: NSDecimalNumber(decimal: value))!
}

private func currencyFormatter(minimum: Int, maximum: Int) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.currencySymbol = "$"
    formatter.minimumFractionDigits = minimum
    formatter.maximumFractionDigits = maximum
    formatter.roundingMode = .halfUp
    return formatter
}

func compactTokenCount(_ value: Int64) -> String {
    guard value >= 1_000 else { return String(value) }
    let divisor = value >= 1_000_000 ? 1_000_000.0 : 1_000.0
    let suffix = value >= 1_000_000 ? "M" : "K"
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    return "\(formatter.string(from: NSNumber(value: Double(value) / divisor))!)\(suffix)"
}
```

`CompactUsagePresentation`은 기존 subscription helper를 유지하되 public dispatcher를 `ProviderUsageState`로 바꾼다. API state는 Day/Mon cost rows만 생성하고 partial issue는 `CompactUsageIndicator.warning` message에 합친다.

- [ ] **Step 5: 기존 tests call site 전환 및 통과 확인**

Run: `swift test --filter 'APICostUsagePresentationTests|CompactUsagePresentationTests|MenuBarStatusSnapshotTests|ProviderSettingsViewModelTests'`
Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git commit -m "feat: present subscription and API cost usage states"
```

---

## Task 10: DashboardViewModel collector lifecycle와 mixed refresh state

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:170-332,350-405,483-813,2770-2848,2915-2945`
- Modify: `Sources/CLIProxyManagerApp/Services/QuitCoordinator.swift:30-76`
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift:12-31`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/QuitCoordinatorTests.swift`

**Interfaces:**
- Consumes: `APIUsageCollecting`, `APIUsageCollectionReport`.
- Produces: `apiCostUsageStates`, `isAPIUsageReloadInProgress`, `lastSuccessfulUsageRefreshAt`.
- Produces: `canReloadUsage`, `isUsageReloadActionInProgress`, `prepareUsage()`, `reloadUsage()`, `prepareForTermination()`.

- [ ] **Step 1: API row와 startup restore tests 작성**

```swift
func testAPIKeyRowsReceiveCostStateAndOAuthRowsKeepSubscriptionState() async throws {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let collector = APIUsageCollectorDouble(restoredReport: reportWithClaudeCost(cost: "1.25", updatedAt: Date(timeIntervalSince1970: 100)))
    let secretStore = InMemorySecretStore(values: [.claudeAPIKey: "key"])
    let viewModel = subscriptionUsageViewModel(
        config: config, configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(), apiUsageCollector: collector,
        secretStore: secretStore
    )

    await viewModel.prepareUsage()

    let apiRow = try XCTUnwrap(viewModel.providerRows.first { $0.id == .claudeAPI })
    guard case let .apiCost(.available(snapshot)) = apiRow.usageState else { return XCTFail("Expected API cost") }
    XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "1.25"))
}
```

- [ ] **Step 2: disable/reload/oldest-success tests 작성**

```swift
func testDisablingUsageClearsOAuthCacheButStopsAndPreservesAPILedger() async throws {
    let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "user@example.com", accountID: nil, expired: nil, disabled: false)
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let snapshot = SubscriptionUsageSnapshot(profileID: profile.id, provider: .claude, windows: [UsageWindow(id: "5h", label: "5h", usedPercent: 10, resetAt: nil)], fetchedAt: Date(timeIntervalSince1970: 200))
    let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
    let collector = APIUsageCollectorDouble()
    let viewModel = subscriptionUsageViewModel(config: config, configStore: StubConfigStore(config: config), keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true), proxyService: StubProxyServiceStarter(), profiles: [profile], subscriptionUsageSnapshotCache: cache, apiUsageCollector: collector, secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"]))

    try viewModel.saveSubscriptionUsageMenuBarVisible(false)
    await collector.waitForStop()

    XCTAssertTrue(cache.isEmpty)
    XCTAssertEqual(await collector.stopCount(), 1)
    XCTAssertEqual(await collector.deleteLedgerCount(), 0)
}

func testReloadUsageRefreshesQuotaAndImmediatelyDrainsAPIQueue() async {
    let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "user@example.com", accountID: nil, expired: nil, disabled: false)
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let quota = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
    let collector = APIUsageCollectorDouble(reloadReport: reportWithClaudeCost(cost: "0.42", updatedAt: Date()))
    let viewModel = subscriptionUsageViewModel(config: config, configStore: StubConfigStore(config: config), keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true), proxyService: StubProxyServiceStarter(), profiles: [profile], quotaClient: quota, apiUsageCollector: collector, secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"]))
    await viewModel.refresh()

    await viewModel.reloadUsage()

    XCTAssertEqual(await quota.fetchCallCount(), 1)
    XCTAssertEqual(await collector.reloadCount(), 1)
    XCTAssertFalse(viewModel.isUsageReloadActionInProgress)
}

func testLastSuccessfulUsageRefreshUsesOldestVisibleSnapshot() async {
    let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "user@example.com", accountID: nil, expired: nil, disabled: false)
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let subscription = SubscriptionUsageSnapshot(profileID: profile.id, provider: .claude, windows: [UsageWindow(id: "5h", label: "5h", usedPercent: 10, resetAt: nil)], fetchedAt: Date(timeIntervalSince1970: 200))
    let collector = APIUsageCollectorDouble(restoredReport: reportWithClaudeCost(cost: "1.00", updatedAt: Date(timeIntervalSince1970: 100)))
    let viewModel = subscriptionUsageViewModel(config: config, configStore: StubConfigStore(config: config), keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true), proxyService: StubProxyServiceStarter(), profiles: [profile], subscriptionUsageSnapshotCache: SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: subscription]), apiUsageCollector: collector, secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"]))

    await viewModel.prepareUsage()

    XCTAssertEqual(viewModel.lastSuccessfulUsageRefreshAt, Date(timeIntervalSince1970: 100))
}

private actor APIUsageCollectorDouble: APIUsageCollecting {
    private let restoredReport: APIUsageCollectionReport
    private let reloadReport: APIUsageCollectionReport
    private var reloadCalls = 0
    private var stopCalls = 0

    init(
        restoredReport: APIUsageCollectionReport = .init(statesByProfileID: [:], collectedAt: Date(timeIntervalSince1970: 0)),
        reloadReport: APIUsageCollectionReport = .init(statesByProfileID: [:], collectedAt: Date(timeIntervalSince1970: 0))
    ) {
        self.restoredReport = restoredReport
        self.reloadReport = reloadReport
    }

    func reports() async -> AsyncStream<APIUsageCollectionReport> {
        AsyncStream { $0.finish() }
    }
    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport { restoredReport }
    func start(configuration: APIUsageCollectorConfiguration) async {}
    func update(configuration: APIUsageCollectorConfiguration) async {}
    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        reloadCalls += 1
        return reloadReport
    }
    func stop(reason: APIUsageCollectorStopReason, at: Date) async { stopCalls += 1 }

    func reloadCount() -> Int { reloadCalls }
    func stopCount() -> Int { stopCalls }
    func deleteLedgerCount() -> Int { 0 }
    func waitForStop() async {
        while stopCalls == 0 { await Task.yield() }
    }
}

private func reportWithClaudeCost(cost: String, updatedAt: Date) -> APIUsageCollectionReport {
    let period = APICostPeriodSnapshot(period: .day, estimatedUSD: Decimal(string: cost)!, totalTokens: 100, requestCount: 1, failedRequestCount: 0, pricedRequestCount: 1, unpricedRequestCount: 0, intervalStart: Date(timeIntervalSince1970: 0), intervalEnd: updatedAt, issues: [])
    let month = APICostPeriodSnapshot(period: .month, estimatedUSD: Decimal(string: cost)!, totalTokens: 100, requestCount: 1, failedRequestCount: 0, pricedRequestCount: 1, unpricedRequestCount: 0, intervalStart: Date(timeIntervalSince1970: 0), intervalEnd: updatedAt, issues: [])
    let snapshot = APICostSnapshot(profileID: "claude-api", provider: .claude, day: period, month: month, reportingTimeZoneID: "UTC", updatedAt: updatedAt)
    return .init(statesByProfileID: ["claude-api": .available(snapshot)], collectedAt: updatedAt)
}
```

- [ ] **Step 3: 실패 확인**

Run: `swift test --filter DashboardViewModelTests`
Expected: FAIL — collector DI와 mixed properties/methods 없음.

- [ ] **Step 4: DI와 published state 추가**

Initializer에 다음 default를 추가한다:

```swift
apiUsageCollector: any APIUsageCollecting = APIUsageCollector()
```

State/property:

```swift
@Published private(set) var apiCostUsageStates: [String: APICostUsageState] = [:]
@Published private(set) var isAPIUsageReloadInProgress = false
private var apiUsageReportTask: Task<Void, Never>?

var canReloadUsage: Bool { config.isUsageEnabled && subscriptionUsageKeyStore.isConfigured() }
var isUsageReloadActionInProgress: Bool {
    isSubscriptionUsageReloadInProgress || isSubscriptionUsageRefreshInProgress || isAPIUsageReloadInProgress
}
var lastSuccessfulUsageRefreshAt: Date? {
    let subscriptionDates = providerRows.compactMap { row -> Date? in
        guard row.showsUsage, case let .subscription(state) = row.usageState else { return nil }
        return state.snapshot?.fetchedAt
    }
    let apiDates = providerRows.compactMap { row -> Date? in
        guard row.showsUsage, case let .apiCost(state) = row.usageState else { return nil }
        return state.snapshot?.updatedAt
    }
    return (subscriptionDates + apiDates).min()
}
```

기존 `canReloadSubscriptionUsage`/`isSubscriptionUsageReloadActionInProgress`는 내부 subscription refresh에만 남기고 views는 새 mixed property를 사용한다.

- [ ] **Step 5: collector configuration/lifecycle 구현**

```swift
private var apiUsageCollectorConfiguration: APIUsageCollectorConfiguration {
    var providers: Set<APIUsageProvider> = []
    if isAPIKeyConfigured(.claudeAPIKey) { providers.insert(.claude) }
    if isAPIKeyConfigured(.codexAPIKey) { providers.insert(.openAI) }
    return .init(
        usageEnabled: config.isUsageEnabled,
        proxyReady: serverStatus.severity == .ready,
        port: config.port,
        enabledProviders: providers,
        reportingTimeZoneID: TimeZone.current.identifier
    )
}
```

`prepareSubscriptionUsage()`를 `prepareUsage()`로 바꾸되 management key repair 로직은 유지한다. 이후 report stream observer를 한 번 시작하고 collector `restore`→`start/update`를 호출한다. stream callback은 `Task { @MainActor [weak self] in self?.applyAPIUsageReport(report) }`로 main actor state를 갱신한다.

Usage off에서는 `cancelSubscriptionUsageWork`, key deletion, OAuth state/cache clear 후 다음 Task를 생성한다. ledger delete API는 호출하지 않는다.

```swift
let proxyCouldServeRequests = serverControlState.isRunning
let collector = apiUsageCollector
Task {
    await collector.stop(reason: .trackingDisabled(proxyCouldServeRequests: proxyCouldServeRequests), at: Date())
}
```

- [ ] **Step 6: reload와 server/API-key transition wiring**

`reloadUsage()`는 duplicate guard 후 `await refresh()`, ready 확인, forced subscription refresh, collector reload를 수행한다. `saveUsageDisplayConfig`의 `wasEnabled`/`willBeEnabled`는 `isUsageEnabled`를 사용하고 기존 `requestServerRestartAfterConfigChange()`를 유지해 실행 중 proxy config의 queue 설정을 즉시 반영한다. server가 멈춘 상태에서 Usage를 켠 경로는 `refreshSubscriptionUsage()` 대신 `prepareUsage()`를 시작한다. API Key add/delete도 기존 proxy configuration restart 경로를 유지하고 restart 결과 또는 server ready 전환 후 `collector.update(configuration:)`; server action success 후 기존 `refreshSubscriptionUsage()` 대신 mixed helper `refreshUsageAfterServerChange()`를 호출한다.

`rebuildProviderRows`:

```swift
// OAuth rows
usageState: .subscription(subscriptionUsageStates[authProfile.id] ?? defaultSubscriptionUsageState)

// Claude API row
usageState: .apiCost(apiCostUsageStates[ProviderRowState.ID.claudeAPI.rawValue] ?? defaultAPICostUsageState),
showsUsage: true

// Codex API row
usageState: .apiCost(apiCostUsageStates[ProviderRowState.ID.codexAPI.rawValue] ?? defaultAPICostUsageState),
showsUsage: true
```

`defaultAPICostUsageState`는 `config.isUsageEnabled ? .loading : .disabled`다.

- [ ] **Step 7: 앱 종료 전에 pending ledger flush**

`DashboardViewModel`에 다음 method를 추가한다.

```swift
func prepareForTermination() async {
    apiUsageReportTask?.cancel()
    apiUsageReportTask = nil
    await apiUsageCollector.stop(reason: .applicationTermination, at: Date())
}
```

`QuitCoordinator` initializer에 `beforeTerminate: @escaping @MainActor @Sendable () async -> Void = {}`를 추가한다. server를 멈추지 않는 quit path도 direct `terminate()` 대신 Task에서 closure를 await하고 종료한다. `confirmQuit()`은 proxy stop 성공 후 closure를 await한 다음 종료한다.

```swift
private func finishTermination() async {
    await beforeTerminate()
    appTerminator.terminate()
}
```

`CLIProxyManagerApp.init`은 `beforeTerminate: { await viewModel.prepareForTermination() }`를 전달한다. 기존 `testRequestQuitTerminatesImmediatelyWhenServerIsStopped`는 `async`로 바꾸고 terminate count가 1이 될 때까지 최대 100회 `Task.yield()`한다. `QuitCoordinatorTests`에 closure가 완료된 뒤 terminate가 호출되는 test를 추가한다.

```swift
func testQuitFlushesUsageBeforeTerminatingWhenServerIsAlreadyStopped() async {
    let events = QuitEventLog()
    let terminator = StubAppTerminator(events: events)
    let coordinator = QuitCoordinator(appTerminator: terminator, shouldStopServerBeforeQuit: { false }, beforeTerminate: {
        events.append("flush")
    })

    coordinator.requestQuit()
    for _ in 0..<100 {
        if terminator.terminateCount > 0 { break }
        await Task.yield()
    }

    XCTAssertEqual(events.values, ["flush", "terminate"])
}
```

- [ ] **Step 8: test double 구현과 전체 Dashboard/Quit tests 통과 확인**

위 `APIUsageCollectorDouble`을 test file의 다른 doubles와 함께 둔다. `subscriptionUsageViewModel` helper parameter 목록에 다음을 추가하고 `DashboardViewModel` initializer에 그대로 전달한다.

```swift
apiUsageCollector: any APIUsageCollecting = APIUsageCollectorDouble(),
secretStore: any SecretStore = InMemorySecretStore()
```

기존 helper 안의 `DashboardViewModel` 생성자 호출에 `apiUsageCollector: apiUsageCollector`, `secretStore: secretStore`를 추가한다. `DashboardViewModelTests.swift`의 기존 `prepareSubscriptionUsage()` call site는 모두 `prepareUsage()`로 바꾼다. `ProviderRowState.subscriptionUsageState` assertion은 `usageState`를 switch해 OAuth는 `.subscription(expected)`, API Key는 `.apiCost(expected)`를 검증하고, `showsSubscriptionUsage` assertion은 `showsUsage`로 바꾼다. subscription quota 자체를 검증하는 기존 `reloadSubscriptionUsage()`, `canReloadSubscriptionUsage`, `isSubscriptionUsageReloadActionInProgress`, `lastSuccessfulSubscriptionUsageRefreshAt` test API는 내부 호환 경로로 유지한다.

Run: `swift test --filter 'DashboardViewModelTests|QuitCoordinatorTests'`
Expected: PASS.

- [ ] **Step 9: 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Sources/CLIProxyManagerApp/Services/QuitCoordinator.swift Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift Tests/CLIProxyManagerAppTests/QuitCoordinatorTests.swift
git commit -m "feat: integrate API cost collection with usage lifecycle"
```

---

## Task 11: 메뉴바와 compact HUD에 API 비용 두 행 표시

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift:14-51,176-293`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:95-183`
- Modify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift:63-136`
- Test: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift`

**Interfaces:**
- Consumes: `ProviderUsageDisplayState`, compact presentation.
- Produces: generic warning icon/aligned row using a prebuilt message.

- [ ] **Step 1: warning/message alignment tests 확장**

```swift
func testUsageWarningIconAcceptsAPIMessageWithoutSubscriptionIssue() {
    let message = "Estimated API cost is partial. Time zone: Asia/Seoul."
    let icon = UsageWarningIcon(message: message)
    XCTAssertEqual(icon.message, message)
    XCTAssertEqual(UsageWarningLayout.iconFrameSize, CGSize(width: 12, height: 12))
}
```

기존 subscription warning tests는 `UsageWarningAlignedRow(message: message, reservesWarningSpace: true) { Text("Usage") }` API로 전환해 layout regression을 유지한다.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter 'MenuBarStatusSnapshotTests|CompactUsagePresentationTests|SubscriptionUsageWarningIconTests'`
Expected: FAIL — views/source가 old property 이름과 subscription-only warning을 사용함.

- [ ] **Step 3: warning view 일반화**

`SubscriptionUsageWarningLayout`을 `UsageWarningLayout`, icon을 `UsageWarningIcon(message:)`, aligned row를 `UsageWarningAlignedRow(message:reservesWarningSpace:content:)`로 바꾼다. subscription call sites는 `SubscriptionUsageWarningPresentation.message(issue:lastUpdatedAt:now:)`를 미리 만들어 전달한다. symbol/font/color/frame은 기존 값 그대로 유지한다.

- [ ] **Step 4: MenuBarStatusView mixed rendering**

- refresh age는 `viewModel.lastSuccessfulUsageRefreshAt`.
- action은 `canReloadUsage`, `isUsageReloadActionInProgress`, `reloadUsage()`.
- snapshot initializer는 `showsUsage:`.
- account row는 `providerUsageDisplayState(for: provider.usageState)`를 switch한다.
- `.subscription`은 기존 progress UI와 `.unavailable(.proxyUnavailable)` hidden 동작을 그대로 유지한다.
- API cost snapshot이 없고 proxy unavailable이면 `—`와 warning message를 표시하며 숨기지 않는다.
- `.apiCost`는 `apiCostRows`의 Day/Mon을 다음 구조로 렌더링한다:

```swift
HStack(spacing: 7) {
    Text(row.label).frame(width: 28, alignment: .leading).foregroundStyle(.secondary)
    Spacer(minLength: 72)
    Text(row.cost).frame(width: 56, alignment: .trailing)
}
.font(.system(size: 10.5, design: .monospaced))
.help(row.tooltip)
.accessibilityLabel(row.accessibilityLabel)
```

첫 행에만 generic warning icon을 두고 둘째 행도 같은 trailing warning 공간을 예약한다. progress bar는 만들지 않는다.

- [ ] **Step 5: compact HUD dispatcher 사용**

`CompactUsageAccountView`는 `compactUsagePresentation(for: provider.usageState)`를 호출한다. warning layout constant 이름만 일반화하고 기존 avatar trailing placement와 row dimensions를 유지한다.

- [ ] **Step 6: 테스트 통과 확인**

Run: `swift test --filter 'MenuBarStatusSnapshotTests|CompactUsagePresentationTests|SubscriptionUsageWarningIconTests|UsageOverlaySurfaceLayoutTests'`
Expected: PASS.

- [ ] **Step 7: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift
git commit -m "feat: show API cost in menu bar and compact HUD"
```

---

## Task 12: Expanded HUD mixed rows와 Usage settings copy

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderUsageState.swift` (temporary compatibility helpers 제거)
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift` (temporary compatibility projection 제거)
- Modify: `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift` (temporary forwarding initializer/projection 제거)
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:27-55,144-181,215-377`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlaySurfaceView.swift:44-82`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift:4-10`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlaySurfaceLayoutTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`
- Modify test: `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift:27-34`

**Interfaces:**
- Consumes: `apiCostRows`, mixed reload state.
- Produces: expanded `Usage` header and API cost `TOK · REQ` rows.

- [ ] **Step 1: expanded presentation tests 작성**

앞의 두 test와 `makeCostSnapshot`은 `UsageOverlayPresentationStateTests.swift`에 추가한다. `testUsageSettingsCopyCoversSubscriptionAndEstimatedCost`는 `SettingsNavigationTests.swift`의 기존 `testUsageSettingsCopyExplainsAutomaticSharedBackend`를 교체한다.

```swift
func testExpandedContentUsesAPIUsageForConfiguredAPIKeyProvider() {
    let presentation = expandedUsageContentPresentation(
        showsUsage: true,
        usageState: .apiCost(.available(makeCostSnapshot()))
    )
    XCTAssertEqual(presentation, .usage)
}

func testExpandedAPIRowHasNoProgressDecoration() {
    let row = apiCostRows(snapshot: makeCostSnapshot(dayTokens: 84_000, dayRequests: 14)).first!
    XCTAssertEqual(row.detail, "84K TOK · 14 REQ")
    XCTAssertEqual(row.cost, "$0.42")
}

func testUsageSettingsCopyCoversSubscriptionAndEstimatedCost() {
    XCTAssertEqual(UsageSettingsCopy.menuBarLabel, "Show usage")
    XCTAssertTrue(UsageSettingsCopy.menuBarDescription.contains("estimated API cost"))
    XCTAssertTrue(UsageSettingsCopy.footer.contains("requests observed through CLIProxyAPI"))
}

private func makeCostSnapshot(dayTokens: Int64 = 84_000, dayRequests: Int64 = 14) -> APICostSnapshot {
    let start = Date(timeIntervalSince1970: 100)
    let end = Date(timeIntervalSince1970: 200)
    let day = APICostPeriodSnapshot(period: .day, estimatedUSD: Decimal(string: "0.42")!, totalTokens: dayTokens, requestCount: dayRequests, failedRequestCount: 0, pricedRequestCount: dayRequests, unpricedRequestCount: 0, intervalStart: start, intervalEnd: end, issues: [])
    let month = APICostPeriodSnapshot(period: .month, estimatedUSD: Decimal(string: "8.73")!, totalTokens: 1_800_000, requestCount: 218, failedRequestCount: 0, pricedRequestCount: 218, unpricedRequestCount: 0, intervalStart: start, intervalEnd: end, issues: [])
    return APICostSnapshot(profileID: "claude-api", provider: .claude, day: day, month: month, reportingTimeZoneID: "UTC", updatedAt: end)
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter 'UsageOverlayPresentationStateTests|UsageOverlaySurfaceLayoutTests|UsageOverlayWindowControllerTests|SettingsNavigationTests'`
Expected: FAIL — old labels/signatures/rendering.

- [ ] **Step 3: HUD chrome/header/reload 전환**

- provider snapshot initializer: `showsUsage: true`.
- refresh state: `isUsageReloadActionInProgress`, `lastSuccessfulUsageRefreshAt`.
- chrome accessibility: `Reload usage`.
- `UsageOverlayView`와 `UsageOverlaySurfaceView`의 action caller는 `reloadUsage()`.
- title: `Usage`.

- [ ] **Step 4: expanded account dispatcher와 API row 구현**

`expandedUsageContentPresentation(showsUsage:usageState:)`로 바꾸고 proxy unavailable subscription/API state 모두 `Start the server to check usage` message를 사용한다. 이 Task로 마지막 view call site가 `usageState`/`showsUsage`를 사용하게 되므로 Task 9의 `subscriptionUsageState`/`showsSubscriptionUsage` compatibility projection과 `MenuBarStatusSnapshot(showsSubscriptionUsage:)` forwarding initializer를 제거한다. usage content switch에서 subscription은 기존 progress rows, API는 아래 layout을 사용한다:

```swift
HStack(spacing: 8) {
    Text(row.label)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .leading)
    Text(row.detail)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    Text(row.cost)
        .font(.system(size: 10.5, design: .monospaced))
        .frame(width: 58, alignment: .trailing)
}
.help(row.tooltip)
.accessibilityElement(children: .ignore)
.accessibilityLabel(row.accessibilityLabel)
```

warning은 첫 Day row에만 표시하고 두 행은 warning slot을 동일하게 예약한다. `ProgressView`나 percentage background를 API path에서 사용하지 않는다.

- [ ] **Step 5: settings copy 구현**

```swift
static let menuBarLabel = "Show usage"
static let menuBarDescription = "Show subscription usage or estimated API cost beneath connected accounts in the menu bar."
static let hudLabel = "Show usage HUD"
static let hudDescription = "Keep subscription usage and estimated API cost visible in a separate window."
static let footer = "Usage data is collected while either usage display is enabled. API cost estimates include only requests observed through CLIProxyAPI. CLIProxyManager manages the local management key automatically."
```

Persisted binding은 계속 `config.subscriptionUsage.showInMenuBar`를 사용한다.

- [ ] **Step 6: 테스트 통과 확인**

Run: `swift test --filter 'UsageOverlayPresentationStateTests|UsageOverlaySurfaceLayoutTests|UsageOverlayWindowControllerTests|SettingsNavigationTests'`
Expected: PASS.

- [ ] **Step 7: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/ProviderUsageState.swift Sources/CLIProxyManagerApp/Models/ProviderRowState.swift Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Sources/CLIProxyManagerApp/Views/UsageOverlaySurfaceView.swift Sources/CLIProxyManagerApp/Views/UsageSettingsView.swift Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift Tests/CLIProxyManagerAppTests/UsageOverlaySurfaceLayoutTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift
git commit -m "feat: show mixed usage in expanded HUD"
```

---

## Task 13: Security regression, full test, development bundle verification

**Files:**
- None (verification-only task; failures return to the owning Task before continuing).

**Interfaces:**
- Consumes: Tasks 1-12.
- Produces: verified no-secret persistence/error surface, complete test suite, signed development app bundle.

- [ ] **Step 1: focused security tests run**

Run:

```bash
swift test --filter 'CLIProxyAPIUsageQueueClientTests|APIUsageLedgerStoreTests|APIUsageCollectorTests'
```

Expected: PASS — raw body never appears in errors; ledger JSON contains no API key/request/auth/failure/header fields; file permissions are 0700/0600.

- [ ] **Step 2: focused price/time tests run**

Run:

```bash
swift test --filter 'APIUsageAccountingTests|APIUsageLedgerModelsTests|APIPriceCatalogTests|APICostEstimatorTests'
```

Expected: PASS — v2 invariant, DST, Sonnet epoch, 272K boundary, GPT-5.6 cache write, Claude TTL/geo/speed assumptions.

- [ ] **Step 3: focused app tests run**

Run:

```bash
swift test --filter 'DashboardViewModelTests|QuitCoordinatorTests|APICostUsagePresentationTests|MenuBarStatusSnapshotTests|CompactUsagePresentationTests|UsageOverlayPresentationStateTests|UsageOverlaySurfaceLayoutTests|UsageOverlayWindowControllerTests|SubscriptionUsageWarningIconTests|SettingsNavigationTests|ProviderSettingsViewModelTests'
```

Expected: PASS — OAuth/API Key mixed rows, last-success preservation, oldest UPDATED, 비용-only compact UI, expanded TOK/REQ.

- [ ] **Step 4: full suite**

Run: `swift test`
Expected: 모든 테스트 PASS. 실패 시 `superpowers:systematic-debugging`을 사용하고 해당 Task로 돌아가 수정한다.

- [ ] **Step 5: development app bundle build**

Run: `make bundle`
Expected: `Bundled build/CLIProxyManager.app` 출력, 에러 없음.

- [ ] **Step 6: code signing verification**

Run: `make verify`
Expected: `codesign verification passed` 출력.

- [ ] **Step 7: git 상태 확인**

Run: `git status --short`
Expected: 구현 계획과 설계 문서를 제외하고 의도하지 않은 untracked/generated file 없음. 계획 실행 중 각 task commit이 만들어졌다면 production/test 변경은 clean 상태다.

- [ ] **Step 8: 사용자 수동 검증 안내**

자동으로 앱을 실행하지 않는다. 사용자에게 다음을 확인하도록 안내한다.

1. `open build/CLIProxyManager.app`로 development 앱 실행.
2. Usage menu bar 또는 HUD를 켜고 Claude/OpenAI API Key를 등록한 뒤 proxy 재시작 config에 queue 두 설정이 있는지 확인.
3. API request를 발생시키고 30초 이내 API Key 계정에 Day/Mon 비용이 나타나는지 확인.
4. 메뉴바와 compact HUD에는 비용만, expanded HUD에는 `TOK · REQ`가 나타나며 API row에 progress bar가 없는지 확인.
5. Usage를 끄고 다시 켰을 때 기존 금액이 남고 partial warning이 표시되는지 확인.
6. warning tooltip에 estimated limitation, time zone, period, Claude cache TTL/global geo/standard speed assumption이 나타나는지 확인.
7. `~/.cliproxy-manager/dev/api-usage/` 파일에 API key, request ID, auth index, failure body, response headers가 없는지 확인.

설계 문서와 구현 계획 문서는 이 세션에서 커밋하지 않는다.
