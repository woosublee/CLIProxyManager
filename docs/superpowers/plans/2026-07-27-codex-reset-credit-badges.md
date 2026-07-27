# Codex Reset Credit Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex OAuth 계정별 reset credit 수량과 정확한 로컬 만료 시각을 메뉴바 팝업 및 Expanded/Compact HUD의 account avatar에 표시한다.

**Architecture:** 기존 `SubscriptionQuotaFetching` refresh task와 CLIProxyAPI credential 선택을 재사용하되 reset-credit 요청 대상은 계정별 3시간 throttle로 제한한다. 일반 subscription usage와 reset-credit 결과, cache, 오류를 독립적으로 병합하고, 공통 순수 presentation 및 avatar badge 컴포넌트로 세 화면을 렌더링한다.

**Tech Stack:** Swift 5.10, Swift Concurrency, SwiftUI/AppKit, Foundation `URLRequest`/`Codable`, XCTest, Swift Package Manager, Makefile app bundling

## Global Constraints

- macOS 최소 지원 버전은 15.0이며 새 외부 dependency를 추가하지 않는다.
- reset-credit upstream은 undocumented `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`다.
- token은 앱이 직접 읽지 않고 CLIProxyAPI Management API의 `Bearer $TOKEN$` 치환만 사용한다.
- `ChatGPT-Account-ID`는 요청 header에만 사용하며 cache, UI, 오류 문구 또는 로그에 저장하지 않는다.
- token, account ID, user ID, credit ID, raw credential 및 raw response body를 출력하지 않는다.
- 자동 reset-credit 조회는 계정별 최대 3시간에 한 번이며 수동 `Reload usage`는 throttle을 무시한다.
- reset-credit 성공과 실패는 일반 subscription usage 결과를 변경하지 않는다.
- 마지막 성공 reset-credit snapshot은 성공 결과로만 교체한다.
- 메뉴바 상단 앱 아이콘은 변경하지 않는다.
- badge는 메뉴바 팝업, Expanded HUD, Compact HUD의 Codex OAuth account avatar에만 표시한다.
- 메뉴바 팝업에서는 `subscriptionUsage.showInMenuBar == false`일 때 badge도 숨긴다.
- UI copy는 기존 앱과 같이 영어를 사용한다.
- 공개 코드와 테스트의 email fixture는 `example.com`을 사용한다.
- 자동 검증은 전체 `swift test`, `git diff --check`, development app bundle 생성까지 수행한다. 실제 앱 실행과 수동 시각 확인은 사용자가 담당한다.
- 승인된 설계는 `docs/superpowers/specs/2026-07-27-codex-reset-credit-badges-design.md`다.

## File Structure

### 새 파일

- `Sources/CLIProxyManagerCore/SubscriptionUsage/CodexResetCreditsModels.swift` — redacted reset-credit model, typed issue, refresh outcome
- `Sources/CLIProxyManagerApp/Services/CodexResetCreditsSnapshotCacheFileStore.swift` — 마지막 성공 snapshot의 atomic file cache
- `Sources/CLIProxyManagerApp/Models/CodexResetCreditsPresentation.swift` — 현재 시각 기준 count, tooltip, accessibility 계산
- `Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift` — red glass badge와 decorated provider avatar
- `Tests/CLIProxyManagerCoreTests/CodexResetCreditsModelsTests.swift` — model/report contract와 민감 필드 부재 검증
- `Tests/CLIProxyManagerAppTests/CodexResetCreditsSnapshotCacheTests.swift` — cache round trip, malformed fallback, clear
- `Tests/CLIProxyManagerAppTests/CodexResetCreditsPresentationTests.swift` — filtering, count, tooltip, time zone, fallback
- `Tests/CLIProxyManagerAppTests/CodexResetCreditBadgeLayoutTests.swift` — badge metrics와 세 화면 decoration wiring

### 수정 파일

- `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift` — report에 reset-credit outcome 추가, protocol overload 추가
- `Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift` — 선택적 reset-credit API call과 독립 decode
- `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift` — reset-credit cache path
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` — 3시간 대상 선택, forced refresh, cache/lifecycle/migration
- `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift` — account row에 reset-credit snapshot 전달
- `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift` — menu/HUD presentation model로 snapshot 전달
- `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift` — Compact HUD warning의 우하단 offset metric
- `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift` — menu popup avatar badge와 분 단위 `now`
- `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — Expanded HUD badge와 공통 `now` 전달
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift` — Compact HUD badge 및 warning 위치 분리
- `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift` — endpoint/header/decode/부분 성공
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` — throttle, force, cache, cleanup, migration
- `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift` — Codex-only snapshot propagation과 menu preference
- `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift` — compact warning metric 변경

---

### Task 1: Core reset-credit model과 fetch contract 추가

**Files:**
- Create: `Sources/CLIProxyManagerCore/SubscriptionUsage/CodexResetCreditsModels.swift`
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift:127-139`
- Create: `Tests/CLIProxyManagerCoreTests/CodexResetCreditsModelsTests.swift`

**Interfaces:**
- Produces: `CodexResetCredit`, `CodexResetCreditsSnapshot`, `CodexResetCreditsIssue`, `CodexResetCreditsRefreshOutcome`
- Produces: `SubscriptionUsageReport.resetCreditsOutcomesByProfileID`
- Produces: `SubscriptionQuotaFetching.fetchUsage(port:profiles:resetCreditsProfileIDs:)`
- Compatibility: 기존 `fetchUsage(port:profiles:)` requirement와 모든 기존 call site를 유지한다.

- [ ] **Step 1: Redacted model과 report default를 검증하는 실패 테스트 작성**

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CodexResetCreditsModelsTests: XCTestCase {
    func testSnapshotRoundTripsOnlyRedactedFields() throws {
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex-work.json",
            reportedAvailableCount: 2,
            reportedTotalEarnedCount: 4,
            credits: [
                CodexResetCredit(
                    title: "Full reset",
                    status: "available",
                    resetType: "full",
                    expiresAt: Date(timeIntervalSince1970: 1_785_174_400),
                    grantedAt: Date(timeIntervalSince1970: 1_784_000_000)
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_784_100_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(CodexResetCreditsSnapshot.self, from: data), snapshot)
        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("account_id"))
        XCTAssertFalse(encoded.contains("credit_id"))
    }

    func testSubscriptionUsageReportDefaultsResetCreditOutcomesToEmpty() {
        let report = SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: .distantPast)
        XCTAssertEqual(report.resetCreditsOutcomesByProfileID, [:])
    }
}
```

- [ ] **Step 2: 새 테스트가 compile failure로 실패하는지 확인**

Run: `swift test --filter CodexResetCreditsModelsTests`

Expected: FAIL because `CodexResetCreditsSnapshot` and `resetCreditsOutcomesByProfileID` do not exist.

- [ ] **Step 3: Core model을 최소 구현**

`Sources/CLIProxyManagerCore/SubscriptionUsage/CodexResetCreditsModels.swift`:

```swift
import Foundation

public struct CodexResetCredit: Codable, Equatable, Sendable {
    public let title: String?
    public let status: String?
    public let resetType: String?
    public let expiresAt: Date?
    public let grantedAt: Date?

    public init(
        title: String?,
        status: String?,
        resetType: String?,
        expiresAt: Date?,
        grantedAt: Date?
    ) {
        self.title = title
        self.status = status
        self.resetType = resetType
        self.expiresAt = expiresAt
        self.grantedAt = grantedAt
    }
}

public struct CodexResetCreditsSnapshot: Codable, Equatable, Sendable {
    public let profileID: String
    public let reportedAvailableCount: Int?
    public let reportedTotalEarnedCount: Int?
    public let credits: [CodexResetCredit]
    public let fetchedAt: Date

    public init(
        profileID: String,
        reportedAvailableCount: Int?,
        reportedTotalEarnedCount: Int?,
        credits: [CodexResetCredit],
        fetchedAt: Date
    ) {
        self.profileID = profileID
        self.reportedAvailableCount = reportedAvailableCount
        self.reportedTotalEarnedCount = reportedTotalEarnedCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }
}

public enum CodexResetCreditsIssue: String, Codable, Equatable, Sendable {
    case accountIDUnavailable
    case credentialRejected
    case endpointUnsupported
    case schemaMismatch
    case transientFailure
}

public enum CodexResetCreditsRefreshOutcome: Equatable, Sendable {
    case available(CodexResetCreditsSnapshot)
    case unavailable(CodexResetCreditsIssue)
}
```

- [ ] **Step 4: Report와 protocol에 호환 가능한 새 contract 추가**

`SubscriptionUsageReport`를 다음 signature로 확장한다.

```swift
public struct SubscriptionUsageReport: Equatable, Sendable {
    public let statesByProfileID: [String: AccountSubscriptionUsageState]
    public let resetCreditsOutcomesByProfileID: [String: CodexResetCreditsRefreshOutcome]
    public let fetchedAt: Date

    public init(
        statesByProfileID: [String: AccountSubscriptionUsageState],
        resetCreditsOutcomesByProfileID: [String: CodexResetCreditsRefreshOutcome] = [:],
        fetchedAt: Date
    ) {
        self.statesByProfileID = statesByProfileID
        self.resetCreditsOutcomesByProfileID = resetCreditsOutcomesByProfileID
        self.fetchedAt = fetchedAt
    }
}
```

Protocol은 기존 method를 requirement로 유지하고 새 requirement에 default 구현을 제공한다.

```swift
public protocol SubscriptionQuotaFetching: Sendable {
    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport
    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport
}

public extension SubscriptionQuotaFetching {
    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles)
    }
}
```

이 default 덕분에 기존 test double과 CLI call site는 Task 2 전까지 수정 없이 compile된다.

- [ ] **Step 5: Core model 테스트와 기존 quota 테스트 실행**

Run: `swift test --filter CodexResetCreditsModelsTests`

Expected: PASS.

Run: `swift test --filter CLIProxyAPISubscriptionQuotaClientTests`

Expected: 기존 테스트 PASS.

- [ ] **Step 6: Task 1 커밋**

```bash
git add Sources/CLIProxyManagerCore/SubscriptionUsage/CodexResetCreditsModels.swift \
  Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift \
  Tests/CLIProxyManagerCoreTests/CodexResetCreditsModelsTests.swift
git commit -m "feat: add codex reset credit models" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: CLIProxyAPI reset-credit endpoint와 부분 성공 구현

**Files:**
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift:29-330`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift:98-258`

**Interfaces:**
- Consumes: Task 1의 `CodexResetCreditsSnapshot`, `CodexResetCreditsRefreshOutcome`
- Implements: `fetchUsage(port:profiles:resetCreditsProfileIDs:)`
- Produces: `SubscriptionUsageReport.resetCreditsOutcomesByProfileID`의 profile별 부분 결과

- [ ] **Step 1: endpoint 요청과 decode를 검증하는 실패 테스트 작성**

기존 test class에 다음 테스트를 추가한다.

```swift
func testRequestedCodexResetCreditsUseAccountHeaderAndParseRedactedSnapshot() async throws {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{"files":[{"name":"codex-work.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"reset_at\":1783645200}}}"}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{"status_code":200,"body":"{\"available_count\":2,\"total_earned_count\":4,\"credits\":[{\"title\":\"Full reset (earned)\",\"status\":\"available\",\"reset_type\":\"full\",\"expires_at\":\"2026-07-31T12:40:00.123Z\",\"granted_at\":\"2026-07-25T00:00:00Z\"}]}"}"#.utf8), statusCode: 200))
    ])
    let now = Date(timeIntervalSince1970: 1_784_100_000)
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport,
        now: { now }
    )
    let profile = AuthProfile(
        fileName: "codex-work.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )

    let report = await client.fetchUsage(
        port: 18_317,
        profiles: [profile],
        resetCreditsProfileIDs: [profile.id]
    )

    guard case let .available(snapshot)? = report.resetCreditsOutcomesByProfileID[profile.id] else {
        return XCTFail("Expected reset-credit snapshot")
    }
    XCTAssertEqual(snapshot.profileID, profile.id)
    XCTAssertEqual(snapshot.reportedAvailableCount, 2)
    XCTAssertEqual(snapshot.reportedTotalEarnedCount, 4)
    XCTAssertEqual(snapshot.credits.first?.title, "Full reset (earned)")
    XCTAssertEqual(snapshot.credits.first?.expiresAt, Date(timeIntervalSince1970: 1_785_501_600.123))
    XCTAssertEqual(snapshot.fetchedAt, now)

    let resetRequest = try XCTUnwrap(transport.requests.last?.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: resetRequest) as? [String: Any])
    XCTAssertEqual(body["auth_index"] as? String, "codex-index")
    XCTAssertEqual(body["method"] as? String, "GET")
    XCTAssertEqual(body["url"] as? String, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
    let headers = try XCTUnwrap(body["header"] as? [String: String])
    XCTAssertEqual(headers["Authorization"], "Bearer $TOKEN$")
    XCTAssertEqual(headers["ChatGPT-Account-ID"], "acct_example")
    XCTAssertEqual(headers["originator"], "Codex Desktop")
    XCTAssertEqual(headers["Accept"], "application/json")
    XCTAssertFalse(String(decoding: resetRequest, as: UTF8.self).contains("management-secret"))
}
```

- [ ] **Step 2: 선택·오류 격리 실패 테스트 추가**

```swift
func testUnselectedCodexProfileDoesNotCallResetCreditEndpoint() async {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
    ])
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport
    )
    let profile = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )

    let report = await client.fetchUsage(
        port: 18_317,
        profiles: [profile],
        resetCreditsProfileIDs: []
    )

    XCTAssertTrue(report.resetCreditsOutcomesByProfileID.isEmpty)
    XCTAssertEqual(transport.requests.count, 2)
}

func testMissingAccountIDFailsOnlyResetCredits() async {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
    ])
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport
    )
    let profile = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )

    let report = await client.fetchUsage(
        port: 18_317,
        profiles: [profile],
        resetCreditsProfileIDs: [profile.id]
    )

    guard case .available? = report.statesByProfileID[profile.id] else {
        return XCTFail("Usage should remain available")
    }
    XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.accountIDUnavailable))
    XCTAssertEqual(transport.requests.count, 2)
}
```

부분 성공과 Claude 제외를 다음 코드로 추가한다.

```swift
func testUsageFailureDoesNotDiscardResetCreditSuccess() async {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{\"files\":[{\"name\":\"codex.json\",\"provider\":\"codex\",\"auth_index\":\"codex-index\",\"status\":\"ready\",\"disabled\":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{\"status_code\":500,\"body\":\"{}\"}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{\"status_code\":200,\"body\":\"{\\\"available_count\\\":1,\\\"credits\\\":[{\\\"title\\\":\\\"Full reset\\\",\\\"status\\\":\\\"available\\\",\\\"expires_at\\\":\\\"2026-07-31T12:40:00Z\\\"}]}\"}"#.utf8), statusCode: 200))
    ])
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport
    )
    let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_example", expired: nil, disabled: false)

    let report = await client.fetchUsage(port: 18_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

    XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.transientFailure))
    guard case .available? = report.resetCreditsOutcomesByProfileID[profile.id] else {
        return XCTFail("Reset credits should succeed independently")
    }
}

func testMalformedResetCreditsDoNotDiscardUsageSuccess() async {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{\"files\":[{\"name\":\"codex.json\",\"provider\":\"codex\",\"auth_index\":\"codex-index\",\"status\":\"ready\",\"disabled\":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{\"status_code\":200,\"body\":\"{\\\"rate_limit\\\":{\\\"primary_window\\\":{\\\"used_percent\\\":20}}}\"}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{\"status_code\":200,\"body\":\"{\\\"available_count\\\":1,\\\"credits\\\":[{\\\"status\\\":\\\"available\\\",\\\"expires_at\\\":\\\"not-a-date\\\"}]}\"}"#.utf8), statusCode: 200))
    ])
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport
    )
    let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_example", expired: nil, disabled: false)

    let report = await client.fetchUsage(port: 18_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

    guard case .available? = report.statesByProfileID[profile.id] else {
        return XCTFail("Usage should remain available")
    }
    XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.schemaMismatch))
}

func testClaudeProfileNeverRequestsResetCredits() async {
    let transport = StubSubscriptionUsageTransport(responses: [
        .success(.init(data: Data(#"{\"files\":[{\"name\":\"claude.json\",\"provider\":\"claude\",\"auth_index\":\"claude-index\",\"status\":\"ready\",\"disabled\":false}]}"#.utf8), statusCode: 200)),
        .success(.init(data: Data(#"{\"status_code\":200,\"body\":\"{\\\"five_hour\\\":{\\\"utilization\\\":10}}\"}"#.utf8), statusCode: 200))
    ])
    let client = CLIProxyAPISubscriptionQuotaClient(
        keyStore: StubManagementKeyStore(key: "management-secret"),
        transport: transport
    )
    let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)

    let report = await client.fetchUsage(port: 18_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

    XCTAssertTrue(report.resetCreditsOutcomesByProfileID.isEmpty)
    XCTAssertEqual(transport.requests.count, 2)
}
```

- [ ] **Step 3: 새 client 테스트가 실패하는지 확인**

Run: `swift test --filter CLIProxyAPISubscriptionQuotaClientTests`

Expected: FAIL because the concrete client does not override the reset-credit overload and returns an empty outcome dictionary.

- [ ] **Step 4: 기존 method를 빈 reset-credit set으로 위임**

```swift
public func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
    await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
}
```

기존 method body를 새 overload로 이동하고 local variable을 추가한다.

```swift
var states: [String: AccountSubscriptionUsageState] = [:]
var resetCreditOutcomes: [String: CodexResetCreditsRefreshOutcome] = [:]
```

Credential match가 완료된 각 profile에서 usage와 reset-credit을 서로 독립적으로 실행한다.

```swift
states[profile.id] = await fetchUsage(
    for: profile,
    credential: credential,
    managementBaseURL: baseURL,
    managementKey: managementKey,
    fetchedAt: fetchedAt
)

if profile.type == .codex, resetCreditsProfileIDs.contains(profile.id) {
    resetCreditOutcomes[profile.id] = await fetchResetCredits(
        for: profile,
        credential: credential,
        managementBaseURL: baseURL,
        managementKey: managementKey,
        fetchedAt: fetchedAt
    )
}
```

최종 report:

```swift
return SubscriptionUsageReport(
    statesByProfileID: states,
    resetCreditsOutcomesByProfileID: resetCreditOutcomes,
    fetchedAt: fetchedAt
)
```

- [ ] **Step 5: reset-credit request와 status mapping 구현**

```swift
private func fetchResetCredits(
    for profile: AuthProfile,
    credential: ManagedCredential,
    managementBaseURL: URL,
    managementKey: String,
    fetchedAt: Date
) async -> CodexResetCreditsRefreshOutcome {
    guard let accountID = profile.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !accountID.isEmpty else {
        return .unavailable(.accountIDUnavailable)
    }

    let requestBody: Data
    do {
        requestBody = try JSONSerialization.data(withJSONObject: [
            "auth_index": credential.authIndex,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "ChatGPT-Account-ID": accountID,
                "originator": "Codex Desktop",
                "Accept": "application/json"
            ]
        ], options: [.sortedKeys])
    } catch {
        return .unavailable(.schemaMismatch)
    }

    let response: (data: Data, statusCode: Int)
    do {
        response = try await sendManagementRequest(
            url: managementBaseURL.appendingPathComponent("api-call"),
            method: "POST",
            managementKey: managementKey,
            body: requestBody
        )
    } catch {
        return .unavailable(.transientFailure)
    }
    guard (200..<300).contains(response.statusCode) else {
        return .unavailable(resetCreditsIssue(for: response.statusCode))
    }

    let apiResponse: APICallResponse
    do {
        apiResponse = try decodeAPICallResponse(response.data)
    } catch {
        return .unavailable(.schemaMismatch)
    }
    guard (200..<300).contains(apiResponse.statusCode) else {
        return .unavailable(resetCreditsIssue(for: apiResponse.statusCode))
    }

    do {
        return .available(try decodeResetCredits(
            apiResponse.body,
            profileID: profile.id,
            fetchedAt: fetchedAt
        ))
    } catch {
        return .unavailable(.schemaMismatch)
    }
}

private func resetCreditsIssue(for statusCode: Int) -> CodexResetCreditsIssue {
    switch statusCode {
    case 401, 403: .credentialRejected
    case 404, 405, 501: .endpointUnsupported
    case 429, 500...599: .transientFailure
    default: .transientFailure
    }
}
```

Decode error와 transport error를 구분하기 위해 `decodeAPICallResponse`와 `decodeResetCredits`를 별도 `do/catch`로 감싸고 decode error는 `.schemaMismatch`, network error만 `.transientFailure`로 반환한다.

- [ ] **Step 6: wire payload와 timestamp decode 구현**

```swift
private struct CodexResetCreditsPayload: Decodable {
    let availableCount: Int?
    let totalEarnedCount: Int?
    let credits: [CodexResetCreditPayload]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case totalEarnedCount = "total_earned_count"
        case credits
    }
}

private struct CodexResetCreditPayload: Decodable {
    let title: String?
    let status: String?
    let resetType: String?
    let expiresAt: String?
    let grantedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, status
        case resetType = "reset_type"
        case expiresAt = "expires_at"
        case grantedAt = "granted_at"
    }
}
```

```swift
private func decodeResetCredits(
    _ data: Data,
    profileID: String,
    fetchedAt: Date
) throws -> CodexResetCreditsSnapshot {
    let payload = try JSONDecoder().decode(CodexResetCreditsPayload.self, from: data)
    guard payload.availableCount != nil || payload.totalEarnedCount != nil || payload.credits != nil else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: [],
            debugDescription: "Missing reset-credit fields"
        ))
    }
    let credits = try (payload.credits ?? []).map { credit in
        CodexResetCredit(
            title: credit.title,
            status: credit.status,
            resetType: credit.resetType,
            expiresAt: try resetDate(credit.expiresAt),
            grantedAt: try resetDate(credit.grantedAt)
        )
    }
    return CodexResetCreditsSnapshot(
        profileID: profileID,
        reportedAvailableCount: payload.availableCount,
        reportedTotalEarnedCount: payload.totalEarnedCount,
        credits: credits,
        fetchedAt: fetchedAt
    )
}
```

기존 `resetDate(_:)`가 ISO-8601 및 fractional seconds를 처리하므로 재사용한다.

- [ ] **Step 7: client tests와 전체 Core compile 확인**

Run: `swift test --filter CLIProxyAPISubscriptionQuotaClientTests`

Expected: PASS.

Run: `swift test --filter CLIProxyManagerCommandTests`

Expected: PASS and CLI quota still uses the old two-argument method, so it does not request reset credits.

- [ ] **Step 8: Task 2 커밋**

```bash
git add Sources/CLIProxyManagerCore/SubscriptionUsage/CLIProxyAPISubscriptionQuotaClient.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift
git commit -m "feat: fetch codex reset credits" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Reset-credit snapshot cache 추가

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:42-52`
- Create: `Sources/CLIProxyManagerApp/Services/CodexResetCreditsSnapshotCacheFileStore.swift`
- Create: `Tests/CLIProxyManagerAppTests/CodexResetCreditsSnapshotCacheTests.swift`

**Interfaces:**
- Produces: `ManagedPaths.codexResetCreditsSnapshotCacheFile`
- Produces: `CodexResetCreditsSnapshotCaching`
- Produces: `CodexResetCreditsSnapshotCacheFileStore`

- [ ] **Step 1: cache round trip, malformed file, clear 실패 테스트 작성**

```swift
import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditsSnapshotCacheTests: XCTestCase {
    func testCachePersistsAndRestoresRedactedSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)
        let store = CodexResetCreditsSnapshotCacheFileStore(paths: paths)
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex-work.json",
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: 2,
            credits: [.init(
                title: "Full reset",
                status: "available",
                resetType: "full",
                expiresAt: Date(timeIntervalSince1970: 200),
                grantedAt: Date(timeIntervalSince1970: 100)
            )],
            fetchedAt: Date(timeIntervalSince1970: 150)
        )

        try store.save([snapshot.profileID: snapshot])

        XCTAssertEqual(store.load(), [snapshot.profileID: snapshot])
        XCTAssertEqual(paths.codexResetCreditsSnapshotCacheFile.lastPathComponent, "codex-reset-credits.json")
    }

    func testMalformedCacheLoadsAsEmptyAndClearRemovesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: paths.codexResetCreditsSnapshotCacheFile)
        let store = CodexResetCreditsSnapshotCacheFileStore(paths: paths)

        XCTAssertEqual(store.load(), [:])
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexResetCreditsSnapshotCacheFile.path))
    }
}
```

- [ ] **Step 2: 새 테스트가 compile failure로 실패하는지 확인**

Run: `swift test --filter CodexResetCreditsSnapshotCacheTests`

Expected: FAIL because the path and store do not exist.

- [ ] **Step 3: ManagedPaths와 cache store 구현**

`ManagedPaths`:

```swift
public var codexResetCreditsSnapshotCacheFile: URL {
    rootDirectory.appendingPathComponent("codex-reset-credits.json")
}
```

새 store는 기존 `SubscriptionUsageSnapshotCacheFileStore`의 atomic file pattern을 그대로 따른다.

```swift
import CLIProxyManagerCore
import Foundation

protocol CodexResetCreditsSnapshotCaching: Sendable {
    func load() -> [String: CodexResetCreditsSnapshot]
    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws
    func clear() throws
}

struct CodexResetCreditsSnapshotCacheFileStore: CodexResetCreditsSnapshotCaching, @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager

    init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() -> [String: CodexResetCreditsSnapshot] {
        guard let data = try? Data(contentsOf: paths.codexResetCreditsSnapshotCacheFile) else { return [:] }
        return (try? JSONDecoder().decode([String: CodexResetCreditsSnapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: paths.codexResetCreditsSnapshotCacheFile, options: .atomic)
    }

    func clear() throws {
        let url = paths.codexResetCreditsSnapshotCacheFile
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
```

- [ ] **Step 4: cache 테스트 실행**

Run: `swift test --filter CodexResetCreditsSnapshotCacheTests`

Expected: PASS.

- [ ] **Step 5: Task 3 커밋**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Sources/CLIProxyManagerApp/Services/CodexResetCreditsSnapshotCacheFileStore.swift \
  Tests/CLIProxyManagerAppTests/CodexResetCreditsSnapshotCacheTests.swift
git commit -m "feat: cache codex reset credits" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: ViewModel 3시간 throttle과 forced refresh 구현

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:208-370, 974-1278`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:4700-5492, 6480-6551, 7476-7557`

**Interfaces:**
- Consumes: `CodexResetCreditsSnapshotCaching`
- Consumes: `SubscriptionQuotaFetching.fetchUsage(port:profiles:resetCreditsProfileIDs:)`
- Produces: `DashboardViewModel.codexResetCreditsSnapshots`
- Produces: 계정별 10,800초 자동 throttle과 `force == true` 우회

- [ ] **Step 1: test double이 reset-credit 요청 ID를 기록하도록 확장**

두 actor에 `resetCreditProfileIDSets`를 추가하고 기존 method를 새 overload로 위임한다.

`RecordingSubscriptionQuotaClient`:

```swift
private var resetCreditProfileIDSets: [Set<String>] = []

func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
    await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
}

func fetchUsage(
    port: Int,
    profiles: [AuthProfile],
    resetCreditsProfileIDs: Set<String>
) async -> SubscriptionUsageReport {
    callCount += 1
    profileIDs.append(profiles.map(\.id))
    resetCreditProfileIDSets.append(resetCreditsProfileIDs)
    return reports.removeFirst()
}

func requestedResetCreditProfileIDSets() -> [Set<String>] {
    resetCreditProfileIDSets
}
```

`SuspendedSubscriptionQuotaClient`:

```swift
private var resetCreditProfileIDSets: [Set<String>] = []

func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
    await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
}

func fetchUsage(
    port: Int,
    profiles: [AuthProfile],
    resetCreditsProfileIDs: Set<String>
) async -> SubscriptionUsageReport {
    callCount += 1
    profileIDs.append(profiles.map(\.id))
    resetCreditProfileIDSets.append(resetCreditsProfileIDs)
    if !reportsBeforeSuspension.isEmpty {
        return reportsBeforeSuspension.removeFirst()
    }
    return await withCheckedContinuation { continuation in
        continuations.append(continuation)
    }
}

func requestedResetCreditProfileIDSets() -> [Set<String>] {
    resetCreditProfileIDSets
}
```

테스트용 mutable clock을 추가한다.

```swift
private final class MutableDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}
```

- [ ] **Step 2: 3시간 경계와 Codex-only 대상 실패 테스트 작성**

```swift
func testResetCreditsAutomaticRefreshUsesThreeHourPerAccountThrottle() async {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let codex = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )
    let claude = AuthProfile(
        fileName: "claude.json",
        type: .claude,
        email: "claude@example.com",
        accountID: nil,
        expired: nil,
        disabled: false
    )
    let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
    let quota = RecordingSubscriptionQuotaClient(reports: [
        availableUsageReport(for: codex),
        availableUsageReport(for: codex),
        availableUsageReport(for: codex)
    ])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [codex, claude],
        quotaClient: quota,
        codexResetCreditsNow: clock.now
    )
    viewModel.serverStatus = readyStatus()

    await viewModel.refreshSubscriptionUsage()
    clock.set(Date(timeIntervalSince1970: 100 + 10_799))
    await viewModel.refreshSubscriptionUsage()
    clock.set(Date(timeIntervalSince1970: 100 + 10_800))
    await viewModel.refreshSubscriptionUsage()

    let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
    XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [], [codex.id]])
}
```

- [ ] **Step 3: forced refresh와 실패 보존 실패 테스트 작성**

```swift
func testReloadUsageAlwaysRequestsActiveCodexResetCredits() async {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let codex = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )
    let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
    let quota = RecordingSubscriptionQuotaClient(reports: [
        availableUsageReport(for: codex),
        availableUsageReport(for: codex)
    ])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [codex],
        quotaClient: quota,
        codexResetCreditsNow: clock.now
    )
    viewModel.serverStatus = readyStatus()

    await viewModel.refreshSubscriptionUsage()
    clock.set(Date(timeIntervalSince1970: 200))
    await viewModel.reloadUsage()

    let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
    XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [codex.id]])
}

func testFreshRestoredResetCreditCacheSkipsFirstAutomaticRequest() async {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let codex = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )
    let snapshot = resetCreditSnapshot(profileID: codex.id, fetchedAt: Date(timeIntervalSince1970: 100))
    let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [codex.id: snapshot])
    let quota = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: codex)])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [codex],
        quotaClient: quota,
        codexResetCreditsSnapshotCache: cache,
        codexResetCreditsNow: { Date(timeIntervalSince1970: 100 + 10_799) }
    )
    viewModel.serverStatus = readyStatus()

    await viewModel.refreshSubscriptionUsage()

    let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
    XCTAssertEqual(requestedResetCreditProfileIDSets, [[]])
    XCTAssertEqual(viewModel.codexResetCreditsSnapshots[codex.id], snapshot)
}

func testResetCreditFailureKeepsLastSuccessfulSnapshotAndCache() async {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    let codex = AuthProfile(
        fileName: "codex.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )
    let snapshot = resetCreditSnapshot(profileID: codex.id, fetchedAt: Date(timeIntervalSince1970: 100))
    let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [codex.id: snapshot])
    let clock = MutableDateProvider(Date(timeIntervalSince1970: 11_000))
    let quota = RecordingSubscriptionQuotaClient(reports: [
        SubscriptionUsageReport(
            statesByProfileID: [codex.id: availableUsageState(for: codex)],
            resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
            fetchedAt: Date(timeIntervalSince1970: 11_000)
        ),
        availableUsageReport(for: codex)
    ])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [codex],
        quotaClient: quota,
        codexResetCreditsSnapshotCache: cache,
        codexResetCreditsNow: clock.now
    )
    viewModel.serverStatus = readyStatus()

    await viewModel.refreshSubscriptionUsage()
    clock.set(Date(timeIntervalSince1970: 11_001))
    await viewModel.refreshSubscriptionUsage()

    let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
    XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], []])
    XCTAssertEqual(viewModel.codexResetCreditsSnapshots[codex.id], snapshot)
    XCTAssertEqual(cache.load()[codex.id], snapshot)
}
```

테스트 helper와 cache double은 다음처럼 구현한다.

```swift
private func resetCreditSnapshot(
    profileID: String,
    fetchedAt: Date
) -> CodexResetCreditsSnapshot {
    CodexResetCreditsSnapshot(
        profileID: profileID,
        reportedAvailableCount: 1,
        reportedTotalEarnedCount: 1,
        credits: [.init(
            title: "Full reset",
            status: "available",
            resetType: "full",
            expiresAt: fetchedAt.addingTimeInterval(86_400),
            grantedAt: fetchedAt
        )],
        fetchedAt: fetchedAt
    )
}

private final class CodexResetCreditsSnapshotCacheDouble: CodexResetCreditsSnapshotCaching, @unchecked Sendable {
    private var snapshots: [String: CodexResetCreditsSnapshot]

    init(snapshots: [String: CodexResetCreditsSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    var isEmpty: Bool { snapshots.isEmpty }
    func load() -> [String: CodexResetCreditsSnapshot] { snapshots }
    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws { self.snapshots = snapshots }
    func clear() throws { snapshots = [:] }
}
```

- [ ] **Step 4: 새 테스트가 compile failure로 실패하는지 확인**

Run: `swift test --filter DashboardViewModelTests/testResetCreditsAutomaticRefreshUsesThreeHourPerAccountThrottle`

Run: `swift test --filter DashboardViewModelTests/testReloadUsageAlwaysRequestsActiveCodexResetCredits`

Run: `swift test --filter DashboardViewModelTests/testFreshRestoredResetCreditCacheSkipsFirstAutomaticRequest`

Run: `swift test --filter DashboardViewModelTests/testResetCreditFailureKeepsLastSuccessfulSnapshotAndCache`

Expected: FAIL because ViewModel has no reset-credit state, cache injection, clock injection or throttle.

- [ ] **Step 5: ViewModel dependency와 상태 추가**

```swift
@Published private(set) var codexResetCreditsSnapshots: [String: CodexResetCreditsSnapshot] = [:]

private let codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching
private let codexResetCreditsNow: @Sendable () -> Date
private var codexResetCreditsLastAttemptAt: [String: Date] = [:]
private static let codexResetCreditsRefreshInterval: TimeInterval = 3 * 60 * 60
```

Initializer parameter:

```swift
codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching = CodexResetCreditsSnapshotCacheFileStore(),
codexResetCreditsNow: @escaping @Sendable () -> Date = { Date() },
```

Initializer body에서 두 dependency를 저장한다.

```swift
self.codexResetCreditsSnapshotCache = codexResetCreditsSnapshotCache
self.codexResetCreditsNow = codexResetCreditsNow
```

`subscriptionUsageViewModel` test helper에도 다음 parameter를 추가하고 `DashboardViewModel` initializer로 전달한다.

```swift
codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching = CodexResetCreditsSnapshotCacheDouble(),
codexResetCreditsNow: @escaping @Sendable () -> Date = { Date() },
```

- [ ] **Step 6: cache 복원과 요청 대상 계산 구현**

```swift
private func restoreCodexResetCreditsSnapshots() {
    guard config.isSubscriptionUsageEnabled else { return }
    let enabledCodexIDs = Set(authProfiles.filter {
        $0.type == .codex && isSubscriptionUsageEnabled(for: $0)
    }.map(\.id))
    codexResetCreditsSnapshots = codexResetCreditsSnapshotCache.load().filter {
        enabledCodexIDs.contains($0.key)
    }
}

private func resetCreditsProfileIDs(
    for profiles: [AuthProfile],
    force: Bool,
    now: Date
) -> Set<String> {
    Set(profiles.compactMap { profile in
        guard profile.type == .codex else { return nil }
        if force { return profile.id }
        let reference = codexResetCreditsLastAttemptAt[profile.id]
            ?? codexResetCreditsSnapshots[profile.id]?.fetchedAt
        guard let reference else { return profile.id }
        return now.timeIntervalSince(reference) >= Self.codexResetCreditsRefreshInterval
            ? profile.id
            : nil
    })
}
```

`restoreSubscriptionUsageSnapshots()` 직후 `restoreCodexResetCreditsSnapshots()`를 호출한다.

- [ ] **Step 7: refresh request와 outcome merge 구현**

`refreshSubscriptionUsage(force:)`에서 profile 확정 후 다음을 계산한다.

```swift
let resetCreditsNow = codexResetCreditsNow()
let resetCreditsProfileIDs = resetCreditsProfileIDs(
    for: profiles,
    force: force,
    now: resetCreditsNow
)
for profileID in resetCreditsProfileIDs {
    codexResetCreditsLastAttemptAt[profileID] = resetCreditsNow
}
```

Task 안의 fetch를 새 overload로 바꾼다.

```swift
let report = await quotaClient.fetchUsage(
    port: port,
    profiles: profiles,
    resetCreditsProfileIDs: resetCreditsProfileIDs
)
```

`applySubscriptionUsageReport` 마지막에 성공 outcome만 병합한다.

```swift
private func applyCodexResetCreditOutcomes(
    _ outcomes: [String: CodexResetCreditsRefreshOutcome],
    enabledProfileIDs: Set<String>
) {
    var changed = false
    for (profileID, outcome) in outcomes where enabledProfileIDs.contains(profileID) {
        guard case let .available(snapshot) = outcome else { continue }
        codexResetCreditsSnapshots[profileID] = snapshot
        changed = true
    }
    if changed {
        try? codexResetCreditsSnapshotCache.save(codexResetCreditsSnapshots)
    }
}
```

`applySubscriptionUsageReport`의 `enabledProfileIDs`를 재사용해 호출한다. `.unavailable`은 기존 snapshot을 절대 제거하지 않는다.

- [ ] **Step 8: throttle/force/cache 테스트 실행**

Run: `swift test --filter DashboardViewModelTests/testResetCreditsAutomaticRefreshUsesThreeHourPerAccountThrottle`

Run: `swift test --filter DashboardViewModelTests/testReloadUsageAlwaysRequestsActiveCodexResetCredits`

Run: `swift test --filter DashboardViewModelTests/testFreshRestoredResetCreditCacheSkipsFirstAutomaticRequest`

Run: `swift test --filter DashboardViewModelTests/testResetCreditFailureKeepsLastSuccessfulSnapshotAndCache`

Expected: PASS.

Run: `swift test --filter DashboardViewModelTests/testForcedSubscriptionUsageRefreshRunsAfterInFlightRefresh`

Expected: PASS; 기존 forced coalescing이 유지된다.

- [ ] **Step 9: Task 4 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: schedule codex reset credit refreshes" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Account lifecycle과 Codex credential migration에 reset-credit cache 연결

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:489-530, 579-624, 1338-1351, 1611-1684, 2428-2604`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:937-1067, 3973-4340, 4881-4972`

**Interfaces:**
- Consumes: `CodexResetCreditsSnapshotCaching`
- Produces: account 제거·비활성화·usage 전체 비활성화 시 state/cache cleanup
- Produces: canonical Codex credential filename migration 시 reset-credit snapshot remap과 rollback

- [ ] **Step 1: usage 비활성화와 account 비활성화 cleanup 실패 테스트 작성**

기존 `testTurningOffLastConsumerDeletesKeyClearsCacheAndRestarts`와 `testResetAllSettingsTurnsOffBothUsageDisplaysAndDeletesKey`에 reset-credit cache를 주입하고 다음 assertion을 추가한다.

```swift
XCTAssertTrue(resetCreditCache.isEmpty)
XCTAssertTrue(viewModel.codexResetCreditsSnapshots.isEmpty)
```

새 test를 추가한다.

```swift
func testDisablingCodexAccountRemovesItsResetCreditSnapshot() {
    var config = AppConfig.default
    config.subscriptionUsage.showInMenuBar = true
    config.oauthCommandProfiles = [
        .init(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "codexwork")
    ]
    let profile = AuthProfile(
        fileName: "codex-work.json",
        type: .codex,
        email: "codex@example.com",
        accountID: "acct_example",
        expired: nil,
        disabled: false
    )
    let snapshot = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 100))
    let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [profile.id: snapshot])
    let authStore = StubAuthProfileStore(profiles: [profile])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [profile],
        authProfileStore: authStore,
        codexResetCreditsSnapshotCache: cache
    )

    viewModel.setProviderEnabled(.init(rawValue: "codex-work"), enabled: false)

    XCTAssertNil(viewModel.codexResetCreditsSnapshots[profile.id])
    XCTAssertNil(cache.load()[profile.id])
}
```

기존 `testRemovingExplicitAccountDuringUsageRefreshCannotRestoreStateOrCache`에는 reset-credit cache를 함께 주입한다.

```swift
let initialReset = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 10))
let refreshedReset = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 60))
let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [profile.id: initialReset])
```

초기 suspended report와 removal 후 resolve report에 각각 outcome을 넣는다.

```swift
resetCreditsOutcomesByProfileID: [profile.id: .available(initialReset)]
```

```swift
resetCreditsOutcomesByProfileID: [profile.id: .available(refreshedReset)]
```

Removal 완료 후 다음을 검증한다.

```swift
XCTAssertNil(viewModel.codexResetCreditsSnapshots[profile.id])
XCTAssertNil(resetCache.load()[profile.id])
```

- [ ] **Step 2: credential migration과 rollback 실패 테스트 확장**

`testInitialCodexCredentialMigrationPreservesSettingsRoundRobinAndUsageCache`에 old/new reset-credit snapshots를 추가한다. New ID의 더 최신 snapshot이 남아야 한다.

```swift
let oldReset = resetCreditSnapshot(profileID: oldID, fetchedAt: Date(timeIntervalSince1970: 10))
let newReset = resetCreditSnapshot(profileID: newID, fetchedAt: Date(timeIntervalSince1970: 20))
let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
    oldID: oldReset,
    newID: newReset
])
```

ViewModel initializer에 cache를 전달하고 다음을 검증한다.

```swift
XCTAssertEqual(resetCache.load(), [newID: newReset])
XCTAssertEqual(viewModel.codexResetCreditsSnapshots, [newID: newReset])
```

`testInitialCodexCredentialMigrationRestoresConfigWhenFinalizationFails`에도 reset cache를 넣고 original old-ID snapshot이 rollback되는지 검증한다.

- [ ] **Step 3: 새 lifecycle/migration assertion이 실패하는지 확인**

Run: `swift test --filter DashboardViewModelTests/testDisablingCodexAccountRemovesItsResetCreditSnapshot`

Run: `swift test --filter DashboardViewModelTests/testInitialCodexCredentialMigration`

Expected: FAIL because reset-credit state is not filtered, cleared, remapped or rolled back.

- [ ] **Step 4: 공통 persist/filter/clear helper 구현**

```swift
private func persistCodexResetCreditSnapshots() {
    let enabledCodexIDs = Set(authProfiles.filter {
        $0.type == .codex && isSubscriptionUsageEnabled(for: $0)
    }.map(\.id))
    let snapshots = codexResetCreditsSnapshots.filter { enabledCodexIDs.contains($0.key) }
    try? codexResetCreditsSnapshotCache.save(snapshots)
}

private func clearCodexResetCreditSnapshots() {
    codexResetCreditsSnapshots.removeAll()
    codexResetCreditsLastAttemptAt.removeAll()
    try? codexResetCreditsSnapshotCache.clear()
}
```

`refreshProfiles()`에서 enabled Codex ID로 snapshots와 last-attempt dictionary를 filter한 뒤 persist한다.

Usage의 마지막 consumer를 끄는 branch와 `resetAllSettings()`에서 `clearCodexResetCreditSnapshots()`를 호출한다.

- [ ] **Step 5: migration transaction에 두 번째 cache 추가**

`applyPreparedCodexCredentialMigrations` parameter에 다음을 추가한다.

```swift
resetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching
```

Transaction 시작 시 두 cache 원본을 모두 읽고, config save 후 두 cache를 모두 remap한 뒤 credential migration을 finalize한다. 어느 단계든 실패하면 config와 두 cache를 원본으로 복원한다.

```swift
let originalResetSnapshots = resetCreditsSnapshotCache.load()
```

```swift
try remapCodexResetCreditSnapshots(
    originalResetSnapshots,
    using: mapping,
    cache: resetCreditsSnapshotCache
)
```

Catch branch:

```swift
try? resetCreditsSnapshotCache.save(originalResetSnapshots)
```

Remap helper는 `fetchedAt`이 최신인 snapshot을 유지하고 model의 `profileID`도 canonical ID로 교체한다.

```swift
private static func remapCodexResetCreditSnapshots(
    _ snapshots: [String: CodexResetCreditsSnapshot],
    using mapping: [String: String],
    cache: any CodexResetCreditsSnapshotCaching
) throws {
    guard !mapping.isEmpty else { return }
    var remapped: [String: CodexResetCreditsSnapshot] = [:]
    for (key, snapshot) in snapshots {
        let profileID = mapping[key] ?? mapping[snapshot.profileID] ?? snapshot.profileID
        let updated = CodexResetCreditsSnapshot(
            profileID: profileID,
            reportedAvailableCount: snapshot.reportedAvailableCount,
            reportedTotalEarnedCount: snapshot.reportedTotalEarnedCount,
            credits: snapshot.credits,
            fetchedAt: snapshot.fetchedAt
        )
        if let existing = remapped[profileID], existing.fetchedAt >= updated.fetchedAt { continue }
        remapped[profileID] = updated
    }
    if remapped != snapshots { try cache.save(remapped) }
}
```

- [ ] **Step 6: runtime state와 attempt timestamp remap 구현**

Runtime state helper를 추가한다.

```swift
private static func remappingCodexResetCreditSnapshots(
    _ snapshots: [String: CodexResetCreditsSnapshot],
    using mapping: [String: String]
) -> [String: CodexResetCreditsSnapshot] {
    guard !mapping.isEmpty else { return snapshots }
    var remapped: [String: CodexResetCreditsSnapshot] = [:]
    for (key, snapshot) in snapshots {
        let profileID = mapping[key] ?? mapping[snapshot.profileID] ?? snapshot.profileID
        let updated = CodexResetCreditsSnapshot(
            profileID: profileID,
            reportedAvailableCount: snapshot.reportedAvailableCount,
            reportedTotalEarnedCount: snapshot.reportedTotalEarnedCount,
            credits: snapshot.credits,
            fetchedAt: snapshot.fetchedAt
        )
        if let existing = remapped[profileID], existing.fetchedAt >= updated.fetchedAt { continue }
        remapped[profileID] = updated
    }
    return remapped
}

private static func remappingAttemptDates(
    _ dates: [String: Date],
    using mapping: [String: String]
) -> [String: Date] {
    dates.reduce(into: [:]) { result, entry in
        let profileID = mapping[entry.key] ?? entry.key
        result[profileID] = max(result[profileID] ?? .distantPast, entry.value)
    }
}
```

`applyCodexCredentialMigrationsIfNeeded()`에서 두 helper 결과를 각각 `codexResetCreditsSnapshots`와 `codexResetCreditsLastAttemptAt`에 대입한다.

- [ ] **Step 7: lifecycle/migration 테스트 실행**

Run: `swift test --filter DashboardViewModelTests/testDisablingCodexAccountRemovesItsResetCreditSnapshot`

Run: `swift test --filter DashboardViewModelTests/testInitialCodexCredentialMigration`

Run: `swift test --filter DashboardViewModelTests/testRemovingExplicitAccountDuringUsageRefreshCannotRestoreStateOrCache`

Run: `swift test --filter DashboardViewModelTests/testTurningOffLastConsumerDeletesKeyClearsCacheAndRestarts`

Expected: PASS.

- [ ] **Step 8: Task 5 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: manage reset credit cache lifecycle" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Reset-credit presentation과 provider snapshot propagation 구현

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/CodexResetCreditsPresentation.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift:31-85`
- Modify: `Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift:3-74`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:3052-3097`
- Create: `Tests/CLIProxyManagerAppTests/CodexResetCreditsPresentationTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift:46-215`

**Interfaces:**
- Produces: `codexResetCreditsPresentation(snapshot:now:timeZone:locale:)`
- Produces: `ProviderRowState.resetCreditsSnapshot`
- Produces: `MenuBarConnectedProvider.providerType`와 `MenuBarConnectedProvider.resetCreditsSnapshot`
- UI task는 이 presentation만 소비하고 filtering/date formatting을 중복 구현하지 않는다.

- [ ] **Step 1: filtering, badge count와 tooltip 실패 테스트 작성**

```swift
import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditsPresentationTests: XCTestCase {
    func testPresentationFiltersUnavailableAndExpiredCredits() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 3,
            reportedTotalEarnedCount: 4,
            credits: [
                .init(title: "Full reset (earned)", status: "available", resetType: "full", expiresAt: Date(timeIntervalSince1970: 2_000), grantedAt: nil),
                .init(title: "Expired", status: "available", resetType: "weekly", expiresAt: now, grantedAt: nil),
                .init(title: "Used", status: "used", resetType: "weekly", expiresAt: Date(timeIntervalSince1970: 3_000), grantedAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 900)
        )

        let presentation = codexResetCreditsPresentation(
            snapshot: snapshot,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.availableCount, 1)
        XCTAssertEqual(presentation.badgeText, "1")
        XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("1 reset credit available"))
        XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("Full reset"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("(earned)"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("Expired"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("Used"))
    }

    func testPresentationUsesUnknownExpirationAndReportedCountFallback() throws {
        let unknown = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: nil,
            credits: [.init(title: nil, status: "AVAILABLE", resetType: nil, expiresAt: nil, grantedAt: nil)],
            fetchedAt: .distantPast
        )
        let fallback = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 4,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )

        let unknownPresentation = codexResetCreditsPresentation(snapshot: unknown, now: .now)
        let fallbackPresentation = codexResetCreditsPresentation(snapshot: fallback, now: .now)

        XCTAssertEqual(unknownPresentation.badgeText, "1")
        XCTAssertTrue(try XCTUnwrap(unknownPresentation.tooltip).contains("Reset credit · Expiration unavailable"))
        XCTAssertEqual(fallbackPresentation.badgeText, "4")
        XCTAssertTrue(try XCTUnwrap(fallbackPresentation.tooltip).contains("Expiration details unavailable"))
    }

    func testPresentationHidesZeroAndCapsLargeBadgeAtNinetyNinePlus() {
        let zero = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 0,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )
        let large = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 100,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )

        XCTAssertNil(codexResetCreditsPresentation(snapshot: zero, now: .now).badgeText)
        XCTAssertEqual(codexResetCreditsPresentation(snapshot: large, now: .now).badgeText, "99+")
    }
}
```

로컬 time zone과 accessibility 문구는 다음 테스트로 고정한다.

```swift
func testPresentationFormatsLocalExpirationAndAccessibilityText() throws {
    let expiration = Date(timeIntervalSince1970: 1_785_501_600)
    let snapshot = CodexResetCreditsSnapshot(
        profileID: "codex.json",
        reportedAvailableCount: 1,
        reportedTotalEarnedCount: 1,
        credits: [.init(
            title: "Full reset",
            status: "available",
            resetType: "full",
            expiresAt: expiration,
            grantedAt: nil
        )],
        fetchedAt: .distantPast
    )
    let timeZone = TimeZone(identifier: "Asia/Seoul")!
    let locale = Locale(identifier: "en_US_POSIX")
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    let expectedExpiration = formatter.string(from: expiration)

    let presentation = codexResetCreditsPresentation(
        snapshot: snapshot,
        now: Date(timeIntervalSince1970: 1_785_000_000),
        timeZone: timeZone,
        locale: locale
    )

    XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("Full reset · \(expectedExpiration)"))
    XCTAssertTrue(try XCTUnwrap(presentation.accessibilityLabel).contains("1 reset credit available"))
    XCTAssertTrue(try XCTUnwrap(presentation.accessibilityLabel).contains(expectedExpiration))
}
```

- [ ] **Step 2: presentation 테스트가 compile failure로 실패하는지 확인**

Run: `swift test --filter CodexResetCreditsPresentationTests`

Expected: FAIL because the presentation type and function do not exist.

- [ ] **Step 3: 순수 presentation 구현**

```swift
import CLIProxyManagerCore
import Foundation

struct CodexResetCreditsPresentation: Equatable {
    let badgeText: String?
    let tooltip: String?
    let accessibilityLabel: String?
    let availableCount: Int
}

func codexResetCreditsPresentation(
    snapshot: CodexResetCreditsSnapshot?,
    now: Date,
    timeZone: TimeZone = .current,
    locale: Locale = .current
) -> CodexResetCreditsPresentation {
    guard let snapshot else {
        return .init(badgeText: nil, tooltip: nil, accessibilityLabel: nil, availableCount: 0)
    }

    let available = snapshot.credits.filter { credit in
        guard credit.status?.caseInsensitiveCompare("available") == .orderedSame else { return false }
        guard let expiresAt = credit.expiresAt else { return true }
        return expiresAt > now
    }

    let count = snapshot.credits.isEmpty
        ? max(0, snapshot.reportedAvailableCount ?? 0)
        : available.count
    guard count > 0 else {
        return .init(badgeText: nil, tooltip: nil, accessibilityLabel: nil, availableCount: 0)
    }

    let countLine = "\(count) reset credit\(count == 1 ? "" : "s") available"
    let detailLines: [String]
    if available.isEmpty {
        detailLines = ["Expiration details unavailable"]
    } else {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        detailLines = available.map { credit in
            let title = normalizedResetCreditTitle(credit.title)
            let expiration = credit.expiresAt.map(formatter.string) ?? "Expiration unavailable"
            return "\(title) · \(expiration)"
        }
    }
    let tooltip = ([countLine] + detailLines).joined(separator: "\n")
    return CodexResetCreditsPresentation(
        badgeText: count > 99 ? "99+" : String(count),
        tooltip: tooltip,
        accessibilityLabel: tooltip.replacingOccurrences(of: "\n", with: ". "),
        availableCount: count
    )
}

private func normalizedResetCreditTitle(_ title: String?) -> String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "Reset credit" }
    guard let suffix = trimmed.range(of: " (") else { return trimmed }
    return String(trimmed[..<suffix.lowerBound])
}
```

- [ ] **Step 4: ProviderRowState와 MenuBarConnectedProvider에 optional snapshot 추가**

`ProviderRowState` initializer에 다음 parameter를 default `nil`로 추가한다.

```swift
resetCreditsSnapshot: CodexResetCreditsSnapshot? = nil
```

`MenuBarConnectedProvider`에는 explicit initializer를 만들고 provider type과 snapshot을 모두 보존한다. 기존 test initializer가 깨지지 않도록 `providerType`은 ID inference, snapshot은 `nil`을 default로 사용한다.

```swift
let providerType: AuthProfileType
let resetCreditsSnapshot: CodexResetCreditsSnapshot?

init(
    id: ProviderRowState.ID,
    providerType: AuthProfileType? = nil,
    name: String,
    displayName: String,
    functionName: String,
    connectionDetail: String,
    accountDetailHidden: Bool,
    usageState: ProviderUsageState,
    showsUsage: Bool,
    resetCreditsSnapshot: CodexResetCreditsSnapshot? = nil
) {
    self.id = id
    self.providerType = providerType ?? id.inferredProviderType
    self.name = name
    self.displayName = displayName
    self.functionName = functionName
    self.connectionDetail = connectionDetail
    self.accountDetailHidden = accountDetailHidden
    self.usageState = usageState
    self.showsUsage = showsUsage
    self.resetCreditsSnapshot = resetCreditsSnapshot
}
```

`MenuBarStatusSnapshot` mapping에서 `provider.providerType`과 `provider.resetCreditsSnapshot`을 전달한다.

- [ ] **Step 5: Dashboard provider row에 Codex snapshot 연결**

OAuth row 생성 시 provider가 Codex일 때만 snapshot을 전달한다.

```swift
resetCreditsSnapshot: commandProfile.provider == .codex
    ? codexResetCreditsSnapshots[authProfile.id]
    : nil,
```

API Key row에는 parameter를 전달하지 않아 default `nil`을 유지한다.

- [ ] **Step 6: propagation 테스트 추가**

`MenuBarStatusSnapshotTests`에 다음을 추가한다.

```swift
func testSnapshotCarriesResetCreditsOnlyForCodexOAuthAccount() throws {
    let reset = CodexResetCreditsSnapshot(
        profileID: "codex.json",
        reportedAvailableCount: 1,
        reportedTotalEarnedCount: 1,
        credits: [],
        fetchedAt: .distantPast
    )
    let snapshot = MenuBarStatusSnapshot(
        serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
        providers: [
            ProviderRowState(
                id: .codex,
                providerType: .codex,
                name: "Codex OAuth",
                nickname: "Work",
                functionName: "codex",
                connectionTitle: "Connected",
                connectionDetail: "codex@example.com",
                isConnected: true,
                resetCreditsSnapshot: reset
            ),
            ProviderRowState(
                id: .claude,
                providerType: .claude,
                name: "Claude OAuth",
                nickname: "Claude",
                functionName: "claude",
                connectionTitle: "Connected",
                connectionDetail: "claude@example.com",
                isConnected: true
            )
        ]
    )

    XCTAssertEqual(snapshot.connectedProviders.first?.providerType, .codex)
    XCTAssertEqual(snapshot.connectedProviders.first?.resetCreditsSnapshot, reset)
    XCTAssertEqual(snapshot.connectedProviders.last?.providerType, .claude)
    XCTAssertNil(snapshot.connectedProviders.last?.resetCreditsSnapshot)
}
```

기존 `testSnapshotCanHideMenuBarUsageWithoutDiscardingFetchedState`에 reset snapshot을 넣고 `provider.showsUsage == false`여도 snapshot 자체는 보존된다는 assertion을 추가한다. 실제 menu view가 badge를 숨기는 책임을 가진다.

- [ ] **Step 7: presentation/propagation 테스트 실행**

Run: `swift test --filter CodexResetCreditsPresentationTests`

Run: `swift test --filter MenuBarStatusSnapshotTests`

Expected: PASS.

- [ ] **Step 8: Task 6 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/CodexResetCreditsPresentation.swift \
  Sources/CLIProxyManagerApp/Models/ProviderRowState.swift \
  Sources/CLIProxyManagerApp/Models/MenuBarStatusSnapshot.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/CodexResetCreditsPresentationTests.swift \
  Tests/CLIProxyManagerAppTests/MenuBarStatusSnapshotTests.swift
git commit -m "feat: present account reset credit data" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Red glass badge를 menu popup과 두 HUD에 배치

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift:83-87`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift:12-31, 148-215`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:36-59, 95-158, 219-312`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:4-10, 92-160`
- Modify: `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift:5-12`
- Create: `Tests/CLIProxyManagerAppTests/CodexResetCreditBadgeLayoutTests.swift`

**Interfaces:**
- Consumes: `CodexResetCreditsPresentation`
- Produces: `CodexResetCreditBadge`
- Produces: `CodexResetCreditAvatar`
- Placement: reset badge `.topTrailing`, compact warning `.bottomTrailing`

- [ ] **Step 1: badge metrics와 source wiring 실패 테스트 작성**

```swift
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditBadgeLayoutTests: XCTestCase {
    func testBadgeMetricsScaleForAllAccountAvatarSizes() {
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 20), 14)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 22), 14)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.minimumHeight(for: 26), 15)
        XCTAssertEqual(CodexResetCreditBadgeMetrics.topTrailingOffset(for: 22), CGSize(width: 4, height: -4))
    }

    func testViewsUseSharedDecoratedAvatarWithoutChangingMenuBarAppIcon() throws {
        let menu = try appSource(relativePath: "Views/MenuBarStatusView.swift")
        let expanded = try appSource(relativePath: "Views/UsageOverlayView.swift")
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
        let badge = try appSource(relativePath: "Views/CodexResetCreditBadge.swift")
        let app = try appSource(relativePath: "CLIProxyManagerApp.swift")

        XCTAssertTrue(menu.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(menu.contains("now: refreshAgeReferenceDate"))
        XCTAssertTrue(expanded.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(expanded.contains("now: refreshStatusReferenceDate"))
        XCTAssertTrue(compact.contains("CodexResetCreditAvatar("))
        XCTAssertTrue(compact.contains(".overlay(alignment: .bottomTrailing)"))
        XCTAssertTrue(badge.contains(".ultraThinMaterial"))
        XCTAssertTrue(badge.contains("BrandPalette.statusError.opacity"))
        XCTAssertTrue(badge.contains("strokeBorder"))
        XCTAssertTrue(badge.contains(".shadow("))
        XCTAssertTrue(badge.contains("accessibilityReduceMotion"))
        XCTAssertFalse(app.contains("CodexResetCreditBadge"))
        XCTAssertFalse(app.contains("CodexResetCreditAvatar"))
    }
}
```

`SubscriptionUsageWarningIconTests`의 metric assertion을 다음으로 확장한다.

```swift
XCTAssertEqual(UsageWarningLayout.compactAvatarBottomTrailingOffset, CGSize(width: 10, height: 10))
```

- [ ] **Step 2: 새 UI 테스트가 compile/source failure로 실패하는지 확인**

Run: `swift test --filter CodexResetCreditBadgeLayoutTests`

Run: `swift test --filter SubscriptionUsageWarningIconTests`

Expected: FAIL because badge types, wiring and bottom-trailing metric do not exist.

- [ ] **Step 3: badge metrics와 red glass badge 구현**

```swift
import CLIProxyManagerCore
import SwiftUI

enum CodexResetCreditBadgeMetrics {
    static func minimumHeight(for avatarSize: CGFloat) -> CGFloat {
        avatarSize >= 26 ? 15 : 14
    }

    static func topTrailingOffset(for avatarSize: CGFloat) -> CGSize {
        avatarSize >= 26
            ? CGSize(width: 5, height: -5)
            : CGSize(width: 4, height: -4)
    }
}

struct CodexResetCreditBadge: View {
    let text: String
    let avatarSize: CGFloat

    var body: some View {
        let height = CodexResetCreditBadgeMetrics.minimumHeight(for: avatarSize)
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, text.count == 1 ? 0 : 3)
            .frame(minWidth: height, minHeight: height)
            .background(.ultraThinMaterial, in: Capsule())
            .background(
                LinearGradient(
                    colors: [
                        BrandPalette.statusError.opacity(0.78),
                        BrandPalette.statusError.opacity(0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)
    }
}
```

- [ ] **Step 4: 공통 decorated avatar 구현**

```swift
struct CodexResetCreditAvatar: View {
    let providerID: ProviderRowState.ID
    let providerType: AuthProfileType
    let accountName: String
    let size: CGFloat
    let snapshot: CodexResetCreditsSnapshot?
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: CodexResetCreditsPresentation {
        codexResetCreditsPresentation(snapshot: snapshot, now: now)
    }

    var body: some View {
        Group {
            if let tooltip = presentation.tooltip,
               let accessibilityLabel = presentation.accessibilityLabel {
                decoratedAvatar
                    .help(tooltip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(accountName). \(accessibilityLabel)")
            } else {
                decoratedAvatar
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: presentation.badgeText
        )
    }

    private var decoratedAvatar: some View {
        ProviderAvatar(providerID: providerID, providerType: providerType, size: size)
            .overlay(alignment: .topTrailing) {
                if providerType == .codex, let badgeText = presentation.badgeText {
                    CodexResetCreditBadge(text: badgeText, avatarSize: size)
                        .offset(CodexResetCreditBadgeMetrics.topTrailingOffset(for: size))
                        .transition(.opacity)
                }
            }
    }
}
```

- [ ] **Step 5: MenuBarStatusView에 분 단위 now와 showsUsage gating 연결**

`accountsBlock`에서 row에 `refreshAgeReferenceDate`를 전달한다.

```swift
MenuBarAccountRow(provider: provider, now: refreshAgeReferenceDate)
```

Row의 avatar를 교체한다.

```swift
CodexResetCreditAvatar(
    providerID: provider.id,
    providerType: provider.providerType,
    accountName: provider.menuBarDisplayName,
    size: 22,
    snapshot: provider.showsUsage ? provider.resetCreditsSnapshot : nil,
    now: now
)
```

메뉴바 상단 `CLIProxyManagerApp.MenuBarExtra` label은 수정하지 않는다.

- [ ] **Step 6: Expanded HUD와 Compact HUD에 동일 now 전달**

`UsageOverlayView`가 `refreshStatusReferenceDate`를 두 content에 전달한다.

```swift
ExpandedUsageOverlayContent(
    providers: accountPresentation.providers,
    emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
    refreshStatus: refreshStatus,
    now: refreshStatusReferenceDate
)
```

```swift
CompactUsageOverlayView(
    providers: accountPresentation.providers,
    emptyMessage: accountPresentation.emptyMessage ?? "No connected accounts",
    maximumAccountHeight: presentationState.compactAccountMaximumHeight,
    now: refreshStatusReferenceDate,
    onMeasurementChange: recordCompactAccountHeight
)
```

Expanded account avatar를 `CodexResetCreditAvatar`로 바꾸고 `provider.resetCreditsSnapshot`을 전달한다.

Compact view의 새 stored property는 기본값을 제공해 기존 test construction을 유지한다.

```swift
var now: Date = .now
```

- [ ] **Step 7: Compact warning을 우하단으로 분리**

`UsageWarningLayout`:

```swift
static let compactAvatarBottomTrailingOffset = CGSize(width: 10, height: 10)
```

Compact avatar:

```swift
CodexResetCreditAvatar(
    providerID: provider.id,
    providerType: provider.providerType,
    accountName: provider.usageOverlayDisplayName,
    size: 26,
    snapshot: provider.resetCreditsSnapshot,
    now: now
)
.overlay(alignment: .bottomTrailing) {
    if let indicator = presentation.headerIndicator {
        CompactUsageIndicatorView(indicator: indicator)
            .frame(
                width: UsageWarningLayout.iconFrameSize.width,
                height: UsageWarningLayout.iconFrameSize.height
            )
            .offset(UsageWarningLayout.compactAvatarBottomTrailingOffset)
    }
}
```

기존 `.overlay(alignment: .trailing)`과 `compactAvatarTrailingOffset`을 제거한다. Placeholder indicator는 변경하지 않는다.

- [ ] **Step 8: UI와 layout 회귀 테스트 실행**

Run: `swift test --filter CodexResetCreditBadgeLayoutTests`

Run: `swift test --filter SubscriptionUsageWarningIconTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayAccountTransitionCoordinatorTests`

Run: `swift test --filter MenuBarStatusSnapshotTests`

Expected: PASS. Badge overlay는 account measurement나 transition identity를 변경하지 않는다.

- [ ] **Step 9: Task 7 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift \
  Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift \
  Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift \
  Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift \
  Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift \
  Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift \
  Tests/CLIProxyManagerAppTests/CodexResetCreditBadgeLayoutTests.swift
git commit -m "feat: show reset credit account badges" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: 전체 회귀 검증과 development app bundle 생성

**Files:**
- Verify: all changed source and test files
- Verify: `docs/superpowers/specs/2026-07-27-codex-reset-credit-badges-design.md`

**Interfaces:**
- Verifies: Core request contract, ViewModel scheduling/cache, presentation, three-screen layout, app bundle
- Produces: 사용자 수동 검증이 가능한 development app bundle

- [ ] **Step 1: Feature-focused test suite 실행**

```bash
swift test --filter CodexResetCreditsModelsTests
swift test --filter CLIProxyAPISubscriptionQuotaClientTests
swift test --filter CodexResetCreditsSnapshotCacheTests
swift test --filter CodexResetCreditsPresentationTests
swift test --filter DashboardViewModelTests/testResetCreditsAutomaticRefreshUsesThreeHourPerAccountThrottle
swift test --filter DashboardViewModelTests/testReloadUsageAlwaysRequestsActiveCodexResetCredits
swift test --filter DashboardViewModelTests/testFreshRestoredResetCreditCacheSkipsFirstAutomaticRequest
swift test --filter DashboardViewModelTests/testResetCreditFailureKeepsLastSuccessfulSnapshotAndCache
swift test --filter DashboardViewModelTests/testInitialCodexCredentialMigration
swift test --filter MenuBarStatusSnapshotTests
swift test --filter CodexResetCreditBadgeLayoutTests
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: 모든 command PASS.

- [ ] **Step 2: 전체 test suite 실행**

Run: `swift test`

Expected: baseline 1,254개와 새 테스트가 모두 PASS하고 failure 0개다.

- [ ] **Step 3: Diff와 민감정보 정적 검사**

```bash
git diff --check
rg -n "access_token|refresh_token|credit_id|user_id" \
  Sources/CLIProxyManagerCore/SubscriptionUsage \
  Sources/CLIProxyManagerApp/Models/CodexResetCreditsPresentation.swift \
  Sources/CLIProxyManagerApp/Services/CodexResetCreditsSnapshotCacheFileStore.swift \
  Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift
```

Expected:

- `git diff --check` output 없음
- `access_token`, `refresh_token`, `credit_id`, `user_id`가 새 model/cache/UI에 없음
- 기존 CLIProxyAPI token lookup 코드가 검색되더라도 새 reset-credit cache/UI에는 포함되지 않음

- [ ] **Step 4: Development configuration app bundle 생성**

```bash
make CONFIGURATION=debug BUILD_DIR=build/codex-reset-credit-dev bundle
```

Expected: `Bundled build/codex-reset-credit-dev/CLIProxyManager.app` 출력과 exit code 0.

- [ ] **Step 5: Bundle 필수 파일 검증**

```bash
test -x build/codex-reset-credit-dev/CLIProxyManager.app/Contents/MacOS/CLIProxyManager
test -x build/codex-reset-credit-dev/CLIProxyManager.app/Contents/Helpers/cpm
test -x build/codex-reset-credit-dev/CLIProxyManager.app/Contents/Helpers/cliproxy-manager
test -d build/codex-reset-credit-dev/CLIProxyManager.app/Contents/Frameworks/Sparkle.framework
test -d build/codex-reset-credit-dev/CLIProxyManager.app/Contents/Resources/CLIProxyManager_CLIProxyManagerApp.bundle
```

Expected: 모든 `test` command exit code 0.

- [ ] **Step 6: 사용자 수동 확인 항목 정리**

사용자에게 development app path와 다음 수동 확인 항목을 전달한다.

1. 메뉴바 상단 앱 아이콘에는 badge가 생기지 않는다.
2. 메뉴바 팝업의 각 Codex OAuth avatar에 해당 계정 수량만 표시된다.
3. Expanded HUD와 Compact HUD에서도 같은 계정 수량이 표시된다.
4. 여러 Codex 계정의 수량이 합산되지 않는다.
5. Avatar 전체 hover에서 각 credit의 로컬 만료 일시가 분 단위로 표시된다.
6. 0개 또는 만료 후에는 badge와 reset-credit tooltip이 사라진다.
7. Badge는 과도하게 밝지 않은 red glass 스타일이며 Light/Dark appearance에서 읽힌다.
8. Compact HUD에서 reset badge 우상단과 warning 우하단이 겹치지 않는다.
9. 수동 `Reload usage` 직후 endpoint가 다시 조회되어 count가 갱신된다.
10. 자동 refresh는 3시간 이내 일반 5분 polling에서 reset-credit endpoint를 반복 호출하지 않는다.

- [ ] **Step 7: 최종 working tree 확인**

Run: `git status --short --branch`

Expected: Task별 commit 이후 source/test 변경이 남아 있지 않고, development bundle만 ignored build directory에 존재한다.
