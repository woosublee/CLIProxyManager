# Codex Role-Based Fast Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex의 Opus·Sonnet·Haiku 역할마다 Fast mode를 독립적으로 설정하고, CLIProxyAPI가 관리하는 alias와 `service_tier: priority` payload rule로 모든 Codex 경로에 적용한다.

**Architecture:** Core에 앱 소유 Fast alias 규칙과 `CodexFastConfiguration` snapshot을 둔다. 모델 metadata는 Fast capability를 typed option으로 전달하고, 공통 SwiftUI role editor가 지원 모델에서만 토글을 허용한다. `ProxyServiceManager`는 저장된 `AppConfig`로 OAuth/API Key alias와 payload override를 결정적으로 생성하며, `DashboardViewModel`은 snapshot 변경 시 실행 중 proxy를 한 번만 재시작한다.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Package Manager, XCTest, macOS 15+, CLIProxyAPI v7.2.66 compatible YAML

## Global Constraints

- Fast 설정 단위는 Opus·Sonnet·Haiku 역할별 `Bool`이다.
- 내부 alias suffix는 정확히 `-cpm-fast`를 사용한다.
- upstream 요청에는 `service_tier: priority`를 주입한다.
- Fast 지원 fallback allowlist는 `gpt-5.4`, `gpt-5.5`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`로 제한한다.
- `gpt-5.4-mini`와 custom·legacy 모델은 metadata가 Fast를 명시하지 않으면 미지원이다.
- OAuth, OpenAI API Key, Codex round-robin, legacy Codex 경로에 동일한 의미론을 적용한다.
- Fast를 사용하지 않을 때 기존 모델 ID와 기존 CLIProxyAPI YAML이 바뀌지 않아야 한다.
- 기존 JSON에서 `fastModeEnabled`가 누락되면 `false`로 decode한다.
- 실행 중 Fast YAML snapshot이 바뀌면 자동 restart하고, 중지 상태에서는 다음 start까지 기다린다.
- restart 실패 시 저장된 JSON을 rollback하지 않고 사용자에게 명확한 실패 메시지를 표시한다.
- 실제 upstream 과금 요청은 자동 검증 범위에서 제외한다.
- 앱 실행 검증은 development build를 기준으로 한다.
- 새 외부 dependency를 추가하지 않는다.

## File Structure

### 새 파일

- `Sources/CLIProxyManagerCore/Routing/CodexFastMode.swift`
  - 관리 alias 생성·판별·복원과 Fast 요청 모델 ID 조합만 담당한다.
- `Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift`
  - `AppConfig`에서 OAuth/API Key Fast canonical model 집합을 추출하고 alias collision을 검증한다.
- `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
  - alias helper와 configuration snapshot의 순수 동작을 검증한다.

### 수정 파일

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - `CodexRole.fastModeEnabled` 저장과 하위 호환 decode를 제공한다.
- `Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift`
  - `supportsFastMode` capability를 전달한다.
- `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`
  - service tier metadata를 decode하고 fallback allowlist를 적용하며 관리 alias를 모델 목록에서 제거한다.
- `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
  - 저장 config를 읽어 Fast alias와 payload YAML을 생성한다.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - 직접 변경은 최소화한다. 새 `CodexRole.modelIdentifier`가 모든 기존 경로에 전파되는지를 테스트로 고정한다.
- `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
  - 직접 변경은 최소화한다. Fast alias가 account prefix와 결합되는지를 테스트로 고정한다.
- `Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`
  - Fast toggle 활성화와 model 변경 정규화를 제공한다.
- `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`
  - Fast 열과 안내 문구를 공통 role editor에 추가한다.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
  - Codex sheet 폭·높이와 API Key model canonicalization을 Fast alias에 맞게 조정한다.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - config snapshot 변경 감지와 restart coalescing, 실패 메시지를 구현한다.
- `README.md`, `README.en.md`
  - 역할별 Fast mode와 사용량 증가 가능성을 간단히 문서화한다.

### 테스트 파일

- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`
- `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift`
- `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

---

### Task 1: Fast alias와 역할 저장 모델 추가

**Files:**
- Create: `Sources/CLIProxyManagerCore/Routing/CodexFastMode.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:101-120`
- Create: `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:39-63`

**Interfaces:**
- Produces: `CodexFastMode.alias(for:) -> String`
- Produces: `CodexFastMode.isManagedAlias(_:) -> Bool`
- Produces: `CodexFastMode.canonicalModel(from:) -> String`
- Produces: `CodexFastMode.modelIdentifier(model:reasoning:fastModeEnabled:) -> String`
- Produces: `AppConfig.CodexRole.fastModeEnabled: Bool`
- Consumes: 기존 `AppConfig.CodexReasoning`

- [ ] **Step 1: alias helper의 실패 테스트 작성**

`Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`를 생성한다.

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CodexFastModeTests: XCTestCase {
    func testManagedAliasRoundTripsCanonicalModel() {
        XCTAssertEqual(CodexFastMode.alias(for: "gpt-5.6-sol"), "gpt-5.6-sol-cpm-fast")
        XCTAssertTrue(CodexFastMode.isManagedAlias("gpt-5.6-sol-cpm-fast"))
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-cpm-fast"), "gpt-5.6-sol")
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-cpm-fast(xhigh)"), "gpt-5.6-sol")
    }

    func testModelIdentifierAppliesFastAliasBeforeReasoningSuffix() {
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .xhigh, fastModeEnabled: true),
            "gpt-5.6-sol-cpm-fast(xhigh)"
        )
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .auto, fastModeEnabled: true),
            "gpt-5.6-sol-cpm-fast"
        )
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .medium, fastModeEnabled: false),
            "gpt-5.6-sol(medium)"
        )
    }
}
```

- [ ] **Step 2: helper 테스트가 compile failure로 실패하는지 확인**

Run:

```bash
swift test --filter CodexFastModeTests
```

Expected: FAIL with `cannot find 'CodexFastMode' in scope`.

- [ ] **Step 3: 최소 alias helper 구현**

`Sources/CLIProxyManagerCore/Routing/CodexFastMode.swift`를 생성한다.

```swift
import Foundation

public enum CodexFastMode {
    public static let managedAliasSuffix = "-cpm-fast"

    public static func alias(for canonicalModel: String) -> String {
        canonicalModel(from: canonicalModel) + managedAliasSuffix
    }

    public static func isManagedAlias(_ model: String) -> Bool {
        baseModel(from: model).hasSuffix(managedAliasSuffix)
    }

    public static func canonicalModel(from model: String) -> String {
        let base = baseModel(from: model)
        guard base.hasSuffix(managedAliasSuffix) else { return base }
        return String(base.dropLast(managedAliasSuffix.count))
    }

    public static func modelIdentifier(
        model: String,
        reasoning: AppConfig.CodexReasoning,
        fastModeEnabled: Bool
    ) -> String {
        let canonical = canonicalModel(from: model)
        let requestedModel = fastModeEnabled ? alias(for: canonical) : canonical
        return reasoning == .auto ? requestedModel : "\(requestedModel)(\(reasoning.rawValue))"
    }

    private static func baseModel(from model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let opening = trimmed.lastIndex(of: "(") else {
            return trimmed
        }
        let valueStart = trimmed.index(after: opening)
        let valueEnd = trimmed.index(before: trimmed.endIndex)
        let rawValue = String(trimmed[valueStart..<valueEnd])
        guard AppConfig.CodexReasoning(rawValue: rawValue) != nil else {
            return trimmed
        }
        return String(trimmed[..<opening])
    }
}
```

- [ ] **Step 4: alias helper 테스트 통과 확인**

Run:

```bash
swift test --filter CodexFastModeTests
```

Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 5: 역할 persistence 실패 테스트 추가**

`Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`에 추가한다.

```swift
func testCodexRoleDefaultsMissingFastModeToFalse() throws {
    let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"}"#.utf8)

    let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

    XCTAssertFalse(role.fastModeEnabled)
}

func testCodexRoleFastModeRoundTripsAndRendersManagedAlias() throws {
    let role = AppConfig.CodexRole(
        model: "gpt-5.6-sol",
        reasoning: .max,
        contextWindow: .auto,
        fastModeEnabled: true
    )

    XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol-cpm-fast(max)")
    XCTAssertEqual(
        try JSONDecoder().decode(AppConfig.CodexRole.self, from: JSONEncoder().encode(role)),
        role
    )
}
```

- [ ] **Step 6: persistence 테스트 실패 확인**

Run:

```bash
swift test --filter AppConfigTests/testCodexRole
```

Expected: FAIL because `fastModeEnabled` and the four-argument initializer do not exist.

- [ ] **Step 7: `CodexRole` custom Codable과 model identifier 연결 구현**

`Sources/CLIProxyManagerCore/Config/AppConfig.swift`의 `CodexRole`을 다음 형태로 변경한다.

```swift
public struct CodexRole: Codable, Equatable, Sendable {
    public var model: String
    public var reasoning: CodexReasoning
    public var contextWindow: CodexContextWindow
    public var fastModeEnabled: Bool

    public init(
        model: String,
        reasoning: CodexReasoning,
        contextWindow: CodexContextWindow,
        fastModeEnabled: Bool = false
    ) {
        self.model = model
        self.reasoning = reasoning
        self.contextWindow = contextWindow
        self.fastModeEnabled = fastModeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case model, reasoning, contextWindow, fastModeEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        reasoning = try container.decode(CodexReasoning.self, forKey: .reasoning)
        contextWindow = try container.decode(CodexContextWindow.self, forKey: .contextWindow)
        fastModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .fastModeEnabled) ?? false
    }

    public var modelIdentifier: String {
        CodexFastMode.modelIdentifier(
            model: model,
            reasoning: reasoning,
            fastModeEnabled: fastModeEnabled
        )
    }
}
```

Synthesized `encode(to:)`는 `CodingKeys`의 네 필드를 모두 저장하므로 별도 구현하지 않는다.

- [ ] **Step 8: Task 1 관련 테스트 통과 확인**

Run:

```bash
swift test --filter 'CodexFastModeTests|AppConfigTests'
```

Expected: PASS, 기존 AppConfig tests 포함 0 failures.

- [ ] **Step 9: Task 1 커밋**

```bash
git add Sources/CLIProxyManagerCore/Routing/CodexFastMode.swift \
  Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "feat: add role-based Codex fast mode state

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Codex 모델 Fast capability 조회와 관리 alias 필터링

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift:3-17`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift:62-91,118-182,222-252`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift:178-217`

**Interfaces:**
- Consumes: `CodexFastMode.canonicalModel(from:)`, `CodexFastMode.isManagedAlias(_:)`
- Produces: `CodexModelOption.supportsFastMode: Bool`
- Produces: `CodexModelOption.fastModeFallbackModels: Set<String>`
- Preserves: 기존 reasoning metadata와 created 정렬

- [ ] **Step 1: metadata·fallback·alias filtering 실패 테스트 작성**

`Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`에 다음 테스트를 추가한다.

```swift
func testCodexModelOptionsDecodeFastServiceTierMetadata() async throws {
    let regular = Data(#"{"data":[{"id":"codex-work/custom-fast-model","owned_by":"openai","created":300}]}"#.utf8)
    let metadata = Data(#"{"models":[{"slug":"codex-work/custom-fast-model","service_tiers":[{"id":"priority","name":"Fast"}],"additional_speed_tiers":["fast"]}]}"#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

    XCTAssertEqual(models, [CodexModelOption(id: "custom-fast-model", supportsFastMode: true)])
}

func testCodexModelOptionsUseConservativeFastFallbackForKnownModels() async throws {
    let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300},{"id":"codex-work/gpt-5.4-mini","owned_by":"openai","created":200},{"id":"codex-work/custom-model","owned_by":"openai","created":100}]}"#.utf8)
    let metadata = Data(#"{"models":[]}"#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

    XCTAssertEqual(models.map(\.id), ["gpt-5.6-sol", "gpt-5.4-mini", "custom-model"])
    XCTAssertEqual(models.map(\.supportsFastMode), [true, false, false])
}

func testCodexModelOptionsHideManagedFastAliases() async throws {
    let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol-cpm-fast","owned_by":"openai","created":400},{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300}]}"#.utf8)
    let metadata = Data(#"{"models":[]}"#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

    XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.6-sol", supportsFastMode: true)])
}
```

- [ ] **Step 2: capability 테스트 실패 확인**

Run:

```bash
swift test --filter ProxyModelClientTests/testCodexModelOptions
```

Expected: FAIL because `supportsFastMode` is not defined and aliases are not filtered.

- [ ] **Step 3: `CodexModelOption`에 capability와 fallback 정책 추가**

`Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift`를 다음처럼 확장한다.

```swift
public struct CodexModelOption: Equatable, Sendable {
    public static let fastModeFallbackModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna"
    ]

    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?
    public var supportsFastMode: Bool

    public init(
        id: String,
        supportedReasoning: [AppConfig.CodexReasoning] = [],
        defaultReasoning: AppConfig.CodexReasoning? = nil,
        supportsFastMode: Bool? = nil
    ) {
        let canonicalID = CodexFastMode.canonicalModel(from: id)
        self.id = canonicalID
        self.supportedReasoning = supportedReasoning
        self.defaultReasoning = defaultReasoning
        self.supportsFastMode = supportsFastMode
            ?? Self.fastModeFallbackModels.contains(canonicalID.lowercased())
    }
}
```

Optional initializer parameter를 사용해 기존 test fixture가 fallback 정책을 자동으로 따르게 한다. metadata가 명시적으로 false인 custom model은 `supportsFastMode: false`를 전달한다.

- [ ] **Step 4: Codex metadata decoder에 service tier 필드 추가**

`ProxyModelClient.swift`의 `CodexClientModelsResponse.Model`에 다음 필드를 추가한다.

```swift
var serviceTiers: [ServiceTier]
var additionalSpeedTiers: [String]

case serviceTiers = "service_tiers"
case additionalSpeedTiers = "additional_speed_tiers"
```

custom decoder에서 누락 시 빈 배열로 decode한다.

```swift
serviceTiers = try container.decodeIfPresent([ServiceTier].self, forKey: .serviceTiers) ?? []
additionalSpeedTiers = try container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
```

같은 response 내부에 다음 type을 추가한다.

```swift
struct ServiceTier: Decodable {
    var id: String?
    var name: String?
}
```

- [ ] **Step 5: metadata와 fallback을 결합하고 관리 alias를 제외**

`codexModelOptions(port:modelPrefix:)`의 mapping에서 metadata capability를 계산한다.

```swift
let metadataSupportsFast = metadata.serviceTiers.contains { tier in
    tier.id?.caseInsensitiveCompare("priority") == .orderedSame
        || tier.name?.caseInsensitiveCompare("Fast") == .orderedSame
} || metadata.additionalSpeedTiers.contains { tier in
    tier.caseInsensitiveCompare("fast") == .orderedSame
}

return CodexModelOption(
    id: id,
    supportedReasoning: supported,
    defaultReasoning: defaultReasoning.flatMap { supported.contains($0) ? $0 : nil },
    supportsFastMode: metadataSupportsFast
        || CodexModelOption.fastModeFallbackModels.contains(id.lowercased())
)
```

metadata가 없는 branch도 명시적으로 fallback을 사용한다.

```swift
guard let metadata = metadataByID[id] else {
    return CodexModelOption(id: id)
}
```

`uniqueCodexModelIDs`에서 base ID를 만든 직후 관리 alias면 건너뛴다.

```swift
let canonical = CodexFastMode.canonicalModel(from: identifier)
guard !CodexFastMode.isManagedAlias(identifier) else { continue }
if seen.insert(canonical).inserted {
    result.append(canonical)
}
```

`baseModelName`도 `CodexFastMode.canonicalModel(from:)`를 거쳐 API Key 초기 model canonicalization과 일관되게 한다.

- [ ] **Step 6: ProxyModelClient 테스트 통과 확인**

Run:

```bash
swift test --filter ProxyModelClientTests
```

Expected: PASS, 기존 17 tests와 새 tests 모두 0 failures.

- [ ] **Step 7: Task 2 커밋**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift \
  Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
git commit -m "feat: discover Codex fast mode capability

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 역할 정규화와 공통 Fast toggle UI 추가

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift:4-37`
- Modify: `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift:4-110`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift:6-12,24-63,811-816,900-907,1209,1286-1294`
- Modify: `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift:178-183,218-239`
- Modify: `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift:5-107`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift:6-15`
- Modify: `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift:42-44`

**Interfaces:**
- Consumes: `CodexModelOption.supportsFastMode`
- Produces: `CodexRoleRoutingOptions.supportsFastMode(model:options:) -> Bool`
- Produces: `CodexRoleRoutingOptions.normalizedRole(_:model:options:) -> AppConfig.CodexRole`
- Produces: `CodexRoleRoutingOptions.normalizedCodex(_:options:) -> AppConfig.Codex`
- Produces: `CodexRoleRoutingOptions.fastModeHelpText: String`
- Preserves: 기존 reasoning picker와 context picker

- [ ] **Step 1: 역할 Fast 정규화 실패 테스트 추가**

`CodexRoleRoutingOptionsTests.swift` fixture에서 지원 여부를 명시하고 테스트를 추가한다.

```swift
private let options = [
    CodexModelOption(
        id: "gpt-5.5",
        supportedReasoning: [.low, .medium, .high, .xhigh],
        defaultReasoning: .medium,
        supportsFastMode: true
    ),
    CodexModelOption(
        id: "custom-model",
        supportedReasoning: [.low, .medium],
        defaultReasoning: .medium,
        supportsFastMode: false
    )
]

func testFastModeIsEnabledOnlyForSupportedModel() {
    XCTAssertTrue(CodexRoleRoutingOptions.supportsFastMode(model: "gpt-5.5", options: options))
    XCTAssertFalse(CodexRoleRoutingOptions.supportsFastMode(model: "custom-model", options: options))
    XCTAssertFalse(CodexRoleRoutingOptions.supportsFastMode(model: "missing-model", options: options))
}

func testModelChangeNormalizesReasoningAndDisablesUnsupportedFastMode() {
    let role = AppConfig.CodexRole(
        model: "gpt-5.5",
        reasoning: .xhigh,
        contextWindow: .context1m,
        fastModeEnabled: true
    )

    XCTAssertEqual(
        CodexRoleRoutingOptions.normalizedRole(role, model: "custom-model", options: options),
        AppConfig.CodexRole(
            model: "custom-model",
            reasoning: .medium,
            contextWindow: .context1m,
            fastModeEnabled: false
        )
    )
}

func testNormalizedCodexTurnsOffFastForUnsupportedAndUnknownModels() {
    let codex = AppConfig.Codex(
        opus: .init(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true),
        sonnet: .init(model: "custom-model", reasoning: .medium, contextWindow: .auto, fastModeEnabled: true),
        haiku: .init(model: "missing-model", reasoning: .low, contextWindow: .auto, fastModeEnabled: true)
    )

    let normalized = CodexRoleRoutingOptions.normalizedCodex(codex, options: options)

    XCTAssertTrue(normalized.opus.fastModeEnabled)
    XCTAssertFalse(normalized.sonnet.fastModeEnabled)
    XCTAssertFalse(normalized.haiku.fastModeEnabled)
}

func testFastModeHelpTextMentionsSpeedAndUsage() {
    XCTAssertEqual(
        CodexRoleRoutingOptions.fastModeHelpText,
        "Fast mode can be about 1.5× faster and may consume more usage or credits."
    )
}
```

- [ ] **Step 2: 정규화 테스트 실패 확인**

Run:

```bash
swift test --filter CodexRoleRoutingOptionsTests
```

Expected: FAIL because the new functions and copy constant do not exist.

- [ ] **Step 3: role-level Fast helper 구현**

`CodexRoleRoutingOptions.swift`에 다음을 추가한다.

```swift
static let fastModeHelpText = "Fast mode can be about 1.5× faster and may consume more usage or credits."

static func supportsFastMode(model: String, options: [CodexModelOption]) -> Bool {
    options.first { $0.id == CodexFastMode.canonicalModel(from: model) }?.supportsFastMode == true
}

static func normalizedCodex(
    _ codex: AppConfig.Codex,
    options: [CodexModelOption]
) -> AppConfig.Codex {
    AppConfig.Codex(
        opus: normalizedRole(codex.opus, model: codex.opus.model, options: options),
        sonnet: normalizedRole(codex.sonnet, model: codex.sonnet.model, options: options),
        haiku: normalizedRole(codex.haiku, model: codex.haiku.model, options: options)
    )
}

static func normalizedRole(
    _ role: AppConfig.CodexRole,
    model: String,
    options: [CodexModelOption]
) -> AppConfig.CodexRole {
    var updated = role
    updated.model = CodexFastMode.canonicalModel(from: model)
    updated.reasoning = normalizedReasoning(
        currentReasoning: role.reasoning,
        model: updated.model,
        options: options
    )
    if !supportsFastMode(model: updated.model, options: options) {
        updated.fastModeEnabled = false
    }
    return updated
}
```

`modelIDs`도 current model을 canonicalize한 뒤 `ModelSelectionOptions`에 전달한다.

- [ ] **Step 4: 정규화 테스트 통과 확인**

Run:

```bash
swift test --filter CodexRoleRoutingOptionsTests
```

Expected: PASS, 0 failures.

- [ ] **Step 5: 공통 role editor에 Fast 열과 안내 추가**

`CodexRoleRoutingFields.swift`에서 전체 `VStack` 아래에 안내를 넣고 header/row에 Fast 열을 추가한다.

```swift
private let fastColumnWidth: CGFloat = 52

var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        VStack(spacing: 0) {
            header
            Divider().padding(.leading, 14)
            row(label: "Opus", role: $opus, last: false)
            row(label: "Sonnet", role: $sonnet, last: false)
            row(label: "Haiku", role: $haiku, last: true)
        }

        Text(CodexRoleRoutingOptions.fastModeHelpText)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
    }
}
```

header 끝에 추가한다.

```swift
Text("Fast")
    .frame(width: fastColumnWidth, alignment: .center)
```

row의 Context picker 뒤에 추가한다.

```swift
Toggle("", isOn: fastModeBinding(for: role))
    .labelsHidden()
    .toggleStyle(.switch)
    .tint(BrandPalette.accent)
    .controlSize(.small)
    .frame(width: fastColumnWidth, alignment: .center)
    .disabled(!CodexRoleRoutingOptions.supportsFastMode(
        model: role.wrappedValue.model,
        options: availableModels
    ))
```

`modelBinding` setter는 reasoning만 수정하지 말고 전체 role 정규화를 사용한다.

```swift
set: { model in
    role.wrappedValue = CodexRoleRoutingOptions.normalizedRole(
        role.wrappedValue,
        model: model,
        options: availableModels
    )
}
```

Fast binding은 capability가 없으면 effective value를 false로 보이고 true 저장을 허용하지 않는다.

```swift
private func fastModeBinding(for role: Binding<AppConfig.CodexRole>) -> Binding<Bool> {
    Binding(
        get: {
            CodexRoleRoutingOptions.supportsFastMode(
                model: role.wrappedValue.model,
                options: availableModels
            ) && role.wrappedValue.fastModeEnabled
        },
        set: { enabled in
            var updated = role.wrappedValue
            updated.fastModeEnabled = enabled && CodexRoleRoutingOptions.supportsFastMode(
                model: updated.model,
                options: availableModels
            )
            role.wrappedValue = updated
        }
    )
}
```

`CodexRoleRoutingFields.body`에 capability load 후 세 role을 정규화하는 change handler를 붙인다.

```swift
.onChange(of: availableModels) { _, models in
    guard !models.isEmpty else { return }
    let normalized = CodexRoleRoutingOptions.normalizedCodex(
        AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
        options: models
    )
    opus = normalized.opus
    sonnet = normalized.sonnet
    haiku = normalized.haiku
}
```

metadata 조회가 실패해 options가 계속 비어 있으면 switch는 off로 표시한다. 각 save closure에는 현재 scoped options를 사용한 정규화를 명시적으로 적용한다.

Codex OAuth save:

```swift
let codex = CodexRoleRoutingOptions.normalizedCodex(
    AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku),
    options: scopedAvailableModels
)
try save(functionName, nickname, codex, dangerousPermissionsEnabled)
```

OpenAI API Key save:

```swift
let codex = CodexRoleRoutingOptions.normalizedCodex(
    CodexAPIModelOptions.normalized(AppConfig.Codex(opus: opus, sonnet: sonnet, haiku: haiku)),
    options: scopedAvailableModels
)
try save(functionName, nickname, codex, dangerousPermissionsEnabled, apiKey.isEmpty ? nil : apiKey)
```

Round-robin `saveCurrentSettings()` 직전에는 `CodexRoundRobinRoleFields`가 제공하는 helper로 `state.profile.codex`를 정규화한다.

```swift
if provider == .codex, let codex = state.profile.codex {
    state.profile.codex = CodexRoleRoutingOptions.normalizedCodex(codex, options: codexModels)
}
```

- [ ] **Step 6: API Key canonicalization이 관리 alias를 제거하도록 테스트 추가**

`ProviderSettingsSheetMetricsTests.swift`에 추가한다.

```swift
func testCodexAPIModelsCanonicalizeManagedFastAliases() {
    XCTAssertEqual(
        CodexAPIModelOptions.baseModels(from: [
            "cpm-codex-api/gpt-5.6-sol-cpm-fast(xhigh)",
            "gpt-5.6-sol"
        ]),
        ["gpt-5.6-sol"]
    )
}
```

- [ ] **Step 7: sheet metrics 실패 테스트를 새 레이아웃 값으로 변경**

`ProviderSettingsSheetMetricsTests.swift`와 `SettingsNavigationTests.swift`의 expected 값을 다음으로 변경한다.

```swift
XCTAssertEqual(ProviderSettingsSheetMetrics.codexWidth, 680)
XCTAssertEqual(ProviderSettingsSheetMetrics.codexHeight, 720)
```

Run:

```bash
swift test --filter 'ProviderSettingsSheetMetricsTests|SettingsNavigationTests'
```

Expected: FAIL because `codexWidth` does not exist and height is still 700.

- [ ] **Step 8: provider sheet metrics와 canonicalization 구현**

`ProviderSettingsSheetMetrics`에 다음을 적용한다.

```swift
static let codexWidth: CGFloat = 680
static let codexHeight: CGFloat = 720
```

Codex OAuth와 OpenAI API Key `AccountSheetChrome`의 hard-coded `width: 600`을 `ProviderSettingsSheetMetrics.codexWidth`로 교체한다.

`CodexAPIModelOptions.baseModels`의 reasoning suffix 제거 뒤 다음 canonicalization을 적용한다.

```swift
let canonicalModel = CodexFastMode.canonicalModel(from: baseModel)
guard !canonicalModel.isEmpty, seen.insert(canonicalModel).inserted else { return nil }
return canonicalModel
```

- [ ] **Step 9: UI helper와 compile 테스트 통과 확인**

Run:

```bash
swift test --filter 'CodexRoleRoutingOptionsTests|ProviderSettingsSheetMetricsTests|SettingsNavigationTests'
```

Expected: PASS, 0 failures.

- [ ] **Step 10: Task 3 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift \
  Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift \
  Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift \
  Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift \
  Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift \
  Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift
git commit -m "feat: add Codex fast mode controls

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Fast configuration snapshot과 CLIProxyAPI YAML 생성

**Files:**
- Create: `Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:228-304,331-368,517-565`
- Modify: `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift:24-124,443-503`

**Interfaces:**
- Consumes: `AppConfig`, `CodexFastMode.alias(for:)`
- Produces: `CodexFastConfiguration.init(config:includeAPIKeyModels:) throws`
- Produces: `oauthCanonicalModels: [String]`
- Produces: `apiKeyCanonicalModels: [String]`
- Produces: `allAliases: [String]`
- Produces: `ProxyServiceManager.appConfigProvider: @Sendable () throws -> AppConfig`

- [ ] **Step 1: configuration snapshot 실패 테스트 작성**

`CodexFastModeTests.swift`에 helper와 테스트를 추가한다.

```swift
func testFastConfigurationSeparatesOAuthAndAPIKeyModelsAndSortsThem() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "codex-work",
            provider: .codex,
            authProfileID: "codex-work.json",
            commandName: "ccwork",
            codex: codex(
                opus: "gpt-5.6-sol",
                sonnet: "gpt-5.5",
                haiku: "gpt-5.5",
                fastOpus: true,
                fastSonnet: true
            ),
            modelPrefix: "codex-work"
        )
    ]
    config.roundRobinProfiles = [
        .init(
            id: "codex-default",
            provider: .codex,
            isEnabled: true,
            commandName: "ccodex",
            includedAuthProfileIDs: ["codex-work.json", "codex-personal.json"],
            codex: codex(
                opus: "gpt-5.4",
                sonnet: "gpt-5.5",
                haiku: "gpt-5.5",
                fastOpus: true
            )
        )
    ]
    config.codexAPI.codex = codex(
        opus: "gpt-5.6-terra",
        sonnet: "gpt-5.6-sol",
        haiku: "gpt-5.5",
        fastOpus: true
    )

    let snapshot = try CodexFastConfiguration(config: config)

    XCTAssertEqual(snapshot.oauthCanonicalModels, ["gpt-5.4", "gpt-5.5", "gpt-5.6-sol"])
    XCTAssertEqual(snapshot.apiKeyCanonicalModels, ["gpt-5.6-terra"])
    XCTAssertEqual(snapshot.allAliases, [
        "gpt-5.4-cpm-fast",
        "gpt-5.5-cpm-fast",
        "gpt-5.6-sol-cpm-fast",
        "gpt-5.6-terra-cpm-fast"
    ])
}

func testAPIKeyModelsCanBeExcludedWhenNoAPIKeyIsConfigured() throws {
    var config = AppConfig.default
    config.codexAPI.codex.opus.fastModeEnabled = true

    XCTAssertEqual(
        try CodexFastConfiguration(config: config, includeAPIKeyModels: false).apiKeyCanonicalModels,
        []
    )
}

func testLegacyCodexModelsAreUsedOnlyWithoutOAuthCommandProfiles() throws {
    var config = AppConfig.default
    config.ccodex.opus.fastModeEnabled = true

    XCTAssertEqual(try CodexFastConfiguration(config: config).oauthCanonicalModels, ["gpt-5.6-terra"])

    config.oauthCommandProfiles = [
        .init(id: "codex-work", provider: .codex, authProfileID: "codex.json", commandName: "ccwork", modelPrefix: "codex-work")
    ]
    XCTAssertEqual(try CodexFastConfiguration(config: config).oauthCanonicalModels, [])
}

func testFastConfigurationRejectsManagedAliasCollision() {
    var config = AppConfig.default
    config.ccodex.opus = .init(
        model: "gpt-5.6-sol-cpm-fast",
        reasoning: .xhigh,
        contextWindow: .auto,
        fastModeEnabled: true
    )

    XCTAssertThrowsError(try CodexFastConfiguration(config: config)) { error in
        XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-cpm-fast"))
    }
}
```

테스트 파일 내부에 역할 enum 대신 `Set<ClaudeModelRole>`를 쓰지 않는다. Core의 existing role enum과 충돌할 수 있으므로 local helper는 명시적인 boolean parameter를 사용한다.

```swift
private func codex(
    opus: String,
    sonnet: String,
    haiku: String,
    fastOpus: Bool = false,
    fastSonnet: Bool = false,
    fastHaiku: Bool = false
) -> AppConfig.Codex {
    .init(
        opus: .init(model: opus, reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: fastOpus),
        sonnet: .init(model: sonnet, reasoning: .medium, contextWindow: .auto, fastModeEnabled: fastSonnet),
        haiku: .init(model: haiku, reasoning: .low, contextWindow: .auto, fastModeEnabled: fastHaiku)
    )
}
```

- [ ] **Step 2: snapshot 테스트 실패 확인**

Run:

```bash
swift test --filter CodexFastModeTests
```

Expected: FAIL because `CodexFastConfiguration` is not defined.

- [ ] **Step 3: configuration snapshot 구현**

`Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift`를 생성한다.

```swift
import Foundation

public enum CodexFastConfigurationError: LocalizedError, Equatable {
    case managedAliasCollision(String)

    public var errorDescription: String? {
        switch self {
        case .managedAliasCollision(let model):
            return "Codex model `\(model)` conflicts with CLIProxyManager's managed Fast alias."
        }
    }
}

public struct CodexFastConfiguration: Equatable, Sendable {
    public let oauthCanonicalModels: [String]
    public let apiKeyCanonicalModels: [String]
    public let allAliases: [String]

    public init(config: AppConfig, includeAPIKeyModels: Bool = true) throws {
        let oauthCodexConfigs: [AppConfig.Codex]
        if config.oauthCommandProfiles.isEmpty {
            oauthCodexConfigs = [config.ccodex]
        } else {
            oauthCodexConfigs = config.oauthCommandProfiles.compactMap { profile in
                guard profile.provider == .codex, profile.isEnabled else { return nil }
                return profile.codex ?? config.ccodex
            }
        }

        let roundRobinCodexConfigs = config.roundRobinProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return profile.codex ?? config.ccodex
        }

        oauthCanonicalModels = try Self.fastModels(in: oauthCodexConfigs + roundRobinCodexConfigs)
        apiKeyCanonicalModels = includeAPIKeyModels
            ? try Self.fastModels(in: [config.codexAPI.codex])
            : []
        allAliases = Set((oauthCanonicalModels + apiKeyCanonicalModels).map(CodexFastMode.alias(for:))).sorted()
    }

    private static func fastModels(in configs: [AppConfig.Codex]) throws -> [String] {
        var models = Set<String>()
        for role in configs.flatMap({ [$0.opus, $0.sonnet, $0.haiku] }) where role.fastModeEnabled {
            guard !CodexFastMode.isManagedAlias(role.model) else {
                throw CodexFastConfigurationError.managedAliasCollision(role.model)
            }
            models.insert(CodexFastMode.canonicalModel(from: role.model))
        }
        return models.sorted()
    }
}
```

- [ ] **Step 4: snapshot 테스트 통과 확인**

Run:

```bash
swift test --filter CodexFastModeTests
```

Expected: PASS, 0 failures.

- [ ] **Step 5: YAML 생성 실패 테스트 추가**

`ProxyServiceManagerTests.swift`에 다음 테스트를 추가한다.

```swift
func testStartWritesOAuthAndAPIKeyFastAliasesWithPriorityPayload() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    var config = AppConfig.default
    config.ccodex.opus = .init(model: "gpt-5.6-sol", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true)
    config.codexAPI.codex.sonnet = .init(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto, fastModeEnabled: true)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        codexAPIKeyProvider: { "codex-key" },
        appConfigProvider: { config }
    )

    try await manager.start(port: 8317)

    let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertTrue(yaml.contains("oauth-model-alias:"))
    XCTAssertTrue(yaml.contains("name: \"gpt-5.6-sol\""))
    XCTAssertTrue(yaml.contains("alias: \"gpt-5.6-sol-cpm-fast\""))
    XCTAssertTrue(yaml.contains("fork: true"))
    XCTAssertTrue(yaml.contains("models:"))
    XCTAssertTrue(yaml.contains("name: \"gpt-5.5\""))
    XCTAssertTrue(yaml.contains("alias: \"gpt-5.5-cpm-fast\""))
    XCTAssertTrue(yaml.contains("payload:"))
    XCTAssertTrue(yaml.contains("service_tier: priority"))
    XCTAssertEqual(yaml.components(separatedBy: "alias: \"gpt-5.6-sol-cpm-fast\"").count - 1, 1)
}

func testStartOmitsFastSectionsWhenNoRolesUseFastMode() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        codexAPIKeyProvider: { "codex-key" },
        appConfigProvider: { .default }
    )

    try await manager.start(port: 8317)

    let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertFalse(yaml.contains("oauth-model-alias:"))
    XCTAssertFalse(yaml.contains("-cpm-fast"))
    XCTAssertFalse(yaml.contains("payload:"))
}

func testStartPropagatesAppConfigLoadFailureWithoutWritingYAML() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let loadError = CocoaError(.fileReadCorruptFile)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        appConfigProvider: { throw loadError }
    )

    do {
        try await manager.start(port: 8317)
        XCTFail("Expected config load failure")
    } catch let error as ProxyServiceError {
        XCTAssertEqual(error, .writeFailed(loadError.localizedDescription))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyConfigFile.path))
}
```

- [ ] **Step 6: YAML 테스트 실패 확인**

Run:

```bash
swift test --filter ProxyServiceManagerTests/testStartWritesOAuthAndAPIKeyFastAliases
```

Expected: FAIL because `appConfigProvider` initializer parameter and Fast YAML do not exist.

- [ ] **Step 7: `ProxyServiceManager`가 저장 config를 주입받도록 변경**

두 initializer에 다음 parameter와 property를 추가한다.

```swift
private let appConfigProvider: @Sendable () throws -> AppConfig

appConfigProvider: (@Sendable () throws -> AppConfig)? = nil
```

기본값은 다음과 같이 설정한다.

```swift
self.appConfigProvider = appConfigProvider ?? { try AppConfigStore(paths: paths).load() }
```

public initializer가 internal initializer로 forwarding할 때도 parameter를 전달한다.

`config(for:)`를 throwing으로 바꾸고 `prepareLocked`에서 `try`한다.

```swift
let configData = Data(try config(for: port).utf8)
```

`config(for:)`는 API key를 한 번만 읽고, Fast snapshot이 실제 credential 존재 여부를 반영하도록 다음 구조로 구현한다.

```swift
private func config(for port: Int) throws -> String {
    let appConfig = try appConfigProvider()
    let codexAPIKey = nonEmpty(codexAPIKeyProvider())
    let fastConfiguration = try CodexFastConfiguration(
        config: appConfig,
        includeAPIKeyModels: codexAPIKey != nil
    )

    let managementConfiguration: String
    if subscriptionUsageEnabledProvider(),
       let key = managementKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
       !key.isEmpty {
        managementConfiguration = """
        remote-management:
          secret-key: \(yamlDoubleQuoted(key))
        """
    } else {
        managementConfiguration = ""
    }

    let claudeAPIConfiguration: String
    if let key = nonEmpty(claudeAPIKeyProvider()) {
        claudeAPIConfiguration = """
        claude-api-key:
          - api-key: \(yamlDoubleQuoted(key))
            base-url: \(yamlDoubleQuoted("https://api.anthropic.com"))
            prefix: \(yamlDoubleQuoted("cpm-claude-api"))
        """
    } else {
        claudeAPIConfiguration = ""
    }

    let codexAPIConfiguration: String
    if let codexAPIKey {
        let entries = codexAPIModelsConfiguration(models: fastConfiguration.apiKeyCanonicalModels)
        let models = entries.isEmpty ? "" : "\n    models:\n\(entries)"
        codexAPIConfiguration = [
            "codex-api-key:",
            "  - api-key: \(yamlDoubleQuoted(codexAPIKey))",
            "    base-url: \(yamlDoubleQuoted("https://api.openai.com/v1"))",
            "    prefix: \(yamlDoubleQuoted("cpm-codex-api"))\(models)"
        ].joined(separator: "\n")
    } else {
        codexAPIConfiguration = ""
    }

    let oauthFastConfiguration = oauthFastAliasConfiguration(
        models: fastConfiguration.oauthCanonicalModels
    )
    let payloadConfiguration = fastPayloadConfiguration(
        aliases: fastConfiguration.allAliases
    )

    return """
    port: \(port)
    auth-dir: \(yamlDoubleQuoted(paths.authDirectory.path))
    logging-to-file: true
    debug: false
    api-keys:
      - sk-dummy
    \(managementConfiguration)
    \(claudeAPIConfiguration)
    \(codexAPIConfiguration)
    \(oauthFastConfiguration)
    \(payloadConfiguration)
    """
}
```

- [ ] **Step 8: Fast YAML section renderer 구현**

`ProxyServiceManager`에 indentation이 명시적인 focused private helpers를 추가한다.

```swift
private func oauthFastAliasConfiguration(models: [String]) -> String {
    guard !models.isEmpty else { return "" }
    var lines = ["oauth-model-alias:", "  codex:"]
    for model in models {
        lines.append("    - name: \(yamlDoubleQuoted(model))")
        lines.append("      alias: \(yamlDoubleQuoted(CodexFastMode.alias(for: model)))")
        lines.append("      fork: true")
    }
    return lines.joined(separator: "\n")
}

private func codexAPIModelsConfiguration(models: [String]) -> String {
    var lines: [String] = []
    for model in models {
        lines.append("      - name: \(yamlDoubleQuoted(model))")
        lines.append("        alias: \(yamlDoubleQuoted(CodexFastMode.alias(for: model)))")
    }
    return lines.joined(separator: "\n")
}

private func fastPayloadConfiguration(aliases: [String]) -> String {
    guard !aliases.isEmpty else { return "" }
    var lines = ["payload:", "  override:", "    - models:"]
    for alias in aliases {
        lines.append("        - name: \(yamlDoubleQuoted(alias))")
        lines.append("          protocol: \(yamlDoubleQuoted("codex"))")
    }
    lines.append("      params:")
    lines.append("        service_tier: priority")
    return lines.joined(separator: "\n")
}
```

위 helper 출력은 정확히 다음 shape를 만든다.

```yaml
oauth-model-alias:
  codex:
    - name: "gpt-5.6-sol"
      alias: "gpt-5.6-sol-cpm-fast"
      fork: true
```

`CodexFastConfiguration`을 `includeAPIKeyModels: codexAPIKey != nil`로 만들었으므로 `allAliases`에는 실제로 사용할 OAuth alias와 등록된 API Key alias만 포함된다. 별도의 post-filter나 `codexAPIKeyProvider()` 재호출을 추가하지 않는다.

- [ ] **Step 9: YAML tests와 기존 manager tests 통과 확인**

Run:

```bash
swift test --filter ProxyServiceManagerTests
```

Expected: PASS, 기존 32 tests와 새 tests 모두 0 failures. 기존 no-Fast YAML assertions도 그대로 통과해야 한다.

- [ ] **Step 10: Task 4 커밋**

```bash
git add Sources/CLIProxyManagerCore/Config/CodexFastConfiguration.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: generate Codex fast routing configuration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: 모든 shell·round-robin 경로에서 Fast alias 전파 검증

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift:128-315,459-485`
- Modify: `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift:5-38`
- Modify only if tests expose duplication: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Modify only if tests expose duplication: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`

**Interfaces:**
- Consumes: `AppConfig.CodexRole.modelIdentifier`
- Verifies: legacy, OAuth, OpenAI API Key, round-robin prefixes all preserve `-cpm-fast(reasoning)` ordering

- [ ] **Step 1: legacy와 API Key shell Fast tests 작성**

`ShellFunctionRendererTests.swift`에 추가한다.

```swift
func testLegacyCodexCommandRendersRoleSpecificFastAlias() throws {
    var config = configuredCommands()
    config.ccodex = .init(
        opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true),
        sonnet: .init(model: "gpt-5.6-sol", reasoning: .medium, contextWindow: .auto),
        haiku: .init(model: "gpt-5.5", reasoning: .auto, contextWindow: .auto, fastModeEnabled: true)
    )

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.6-sol-cpm-fast(xhigh)'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='gpt-5.6-sol(medium)'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='gpt-5.5-cpm-fast'"))
}

func testCodexAPICommandPrefixesFastAliasBeforeReasoning() throws {
    var config = configuredCommands()
    config.commands.ccodexapi = "ccodexapi"
    config.codexAPI.codex.opus = .init(
        model: "gpt-5.6-terra",
        reasoning: .max,
        contextWindow: .auto,
        fastModeEnabled: true
    )

    let script = try ShellFunctionRenderer(
        config: config,
        helperCommand: "/usr/local/bin/cpm",
        enabledFunctions: .init(claudeOAuth: false, codex: false, claudeAPI: false, codexAPI: true)
    ).render()

    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='cpm-codex-api/gpt-5.6-terra-cpm-fast(max)'"))
}
```

- [ ] **Step 2: OAuth profile Fast test 작성**

```swift
func testCodexOAuthCommandPrefixesRoleSpecificFastAlias() throws {
    var config = configuredCommands()
    config.oauthCommandProfiles = [
        .init(
            id: "codex-work",
            provider: .codex,
            authProfileID: "codex-work.json",
            commandName: "ccwork",
            codex: .init(
                opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true),
                sonnet: .init(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
                haiku: .init(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
            ),
            modelPrefix: "codex-work"
        )
    ]

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-work/gpt-5.6-sol-cpm-fast(xhigh)'"))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='codex-work/gpt-5.5(medium)'"))
}
```

- [ ] **Step 3: round-robin Fast test 작성**

`RoundRobinSelectionServiceTests.swift`에 추가한다.

```swift
func testCodexRoundRobinPrefixesFastAliasForOnlyEnabledRoles() async throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(id: "codex-a", provider: .codex, authProfileID: "a.json", commandName: "cca", modelPrefix: "codex-a"),
        .init(id: "codex-b", provider: .codex, authProfileID: "b.json", commandName: "ccb", modelPrefix: "codex-b")
    ]
    config.roundRobinProfiles = [
        .init(
            id: "codex-default",
            provider: .codex,
            isEnabled: true,
            commandName: "ccodex",
            includedAuthProfileIDs: ["a.json", "b.json"],
            codex: .init(
                opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true),
                sonnet: .init(model: "gpt-5.6-sol", reasoning: .medium, contextWindow: .auto),
                haiku: .init(model: "gpt-5.5", reasoning: .low, contextWindow: .auto, fastModeEnabled: true)
            )
        )
    ]
    let service = RoundRobinSelectionService(
        stateSelector: StubRoundRobinStateSelector(selections: ["b.json"])
    )

    let output = try await service.shellEnvironmentAssignments(
        profileID: "codex-default",
        config: config,
        authProfiles: [
            .init(fileName: "a.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-a"),
            .init(fileName: "b.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-b")
        ]
    )

    XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-b/gpt-5.6-sol-cpm-fast(xhigh)'"))
    XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='codex-b/gpt-5.6-sol(medium)'"))
    XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-b/gpt-5.5-cpm-fast(low)'"))
}
```

- [ ] **Step 4: 경로 테스트 실행**

Run:

```bash
swift test --filter 'ShellFunctionRendererTests|RoundRobinSelectionServiceTests'
```

Expected: PASS without production changes because every path already consumes `modelIdentifier`. 실패하면 model string을 각 renderer에서 재조합하는 해당 지점만 `role.modelIdentifier`로 교체하고 중복 helper는 추가하지 않는다.

- [ ] **Step 5: zsh syntax test 포함 재확인**

Run:

```bash
swift test --filter ShellFunctionRendererTests/testDefaultGeneratedScriptPassesZshSyntaxCheck
```

Expected: PASS, zsh exit status 0.

- [ ] **Step 6: Task 5 커밋**

```bash
git add Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift \
  Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift \
  Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift \
  Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift
git commit -m "test: cover Codex fast routing paths

Co-Authored-By: Claude <noreply@anthropic.com>"
```

변경되지 않은 production file은 `git add`가 무시하므로 commit에는 실제 diff만 포함된다.

---

### Task 6: Fast configuration 변경 시 proxy restart를 한 번만 수행

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:177-184,1112-1145,1247-1274,1311-1318,1362-1380,1947-2000,2306-2350`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:1304-1330,2004-2060,4104-4156`

**Interfaces:**
- Consumes: `CodexFastConfiguration.init(config:includeAPIKeyModels:)`
- Produces: generic `ProxyConfigurationRestartReason`
- Produces: coalesced pending restart state replacing `pendingAPIKeyRestart`
- Produces: Fast-specific failure copy

- [ ] **Step 1: Fast snapshot 변경 restart 실패 테스트 작성**

`DashboardViewModelTests.swift`에 다음 테스트를 추가한다.

```swift
func testSavingCodexFastModeRestartsReadyProxy() async throws {
    var config = AppConfig.default
    config.commands.ccodex = "ccodex"
    let proxyService = StubProxyServiceStarter()
    let viewModel = DashboardViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector(),
        serverStatusRetryDelayNanoseconds: 0
    )
    await viewModel.refresh()
    var codex = config.ccodex
    codex.opus.fastModeEnabled = true

    try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
    await waitForRestart(proxyService)

    XCTAssertEqual(proxyService.restartPorts, [config.port])
}

func testStoppedProxyDoesNotRestartAfterFastModeSave() throws {
    var config = AppConfig.default
    config.commands.ccodex = "ccodex"
    let proxyService = StubProxyServiceStarter()
    let viewModel = DashboardViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector()
    )
    var codex = config.ccodex
    codex.opus.fastModeEnabled = true

    try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)

    XCTAssertEqual(proxyService.restartPorts, [])
}

func testSavingReasoningWithoutChangingFastSnapshotDoesNotRestartProxy() async throws {
    var config = AppConfig.default
    config.commands.ccodex = "ccodex"
    let proxyService = StubProxyServiceStarter()
    let viewModel = DashboardViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector()
    )
    viewModel.serverControlState = .running
    var codex = config.ccodex
    codex.opus.reasoning = .high

    try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
    await Task.yield()

    XCTAssertEqual(proxyService.restartPorts, [])
}
```

- [ ] **Step 2: restart coalescing과 실패 메시지 테스트 작성**

```swift
func testFastAndAPIKeyChangesDuringStartCoalesceIntoOneRestart() async throws {
    var config = AppConfig.default
    config.commands.ccodex = "ccodex"
    config.commands.ccodexapi = "ccodexapi"
    let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
    let viewModel = DashboardViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore(),
        serverStatusRetryDelayNanoseconds: 0
    )

    let startTask = Task { await viewModel.startServer() }
    try await Task.sleep(nanoseconds: 10_000_000)
    var codex = config.ccodex
    codex.opus.fastModeEnabled = true
    try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
    try viewModel.saveCodexAPISettings(
        functionName: "ccodexapi",
        codex: config.codexAPI.codex,
        dangerousPermissionsEnabled: false,
        key: "new-key"
    )
    await startTask.value

    XCTAssertEqual(proxyService.restartPorts, [config.port])
}

func testFastRestartFailureKeepsSavedConfigAndShowsSettingsMessage() async throws {
    var config = AppConfig.default
    config.commands.ccodex = "ccodex"
    let store = StubConfigStore(config: config)
    let proxyService = StubProxyServiceStarter(
        restartError: NSError(domain: "FastMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Restart failed"])
    )
    let viewModel = DashboardViewModel(
        config: config,
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: proxyService,
        claudeConnector: connectedClaudeConnector(),
        settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
    )
    viewModel.serverControlState = .running
    var codex = config.ccodex
    codex.opus.fastModeEnabled = true

    try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
    await waitForRestart(proxyService)
    for _ in 0..<20 where viewModel.settingsMessage == nil { await Task.yield() }

    XCTAssertTrue(store.savedConfigs.last?.ccodex.opus.fastModeEnabled == true)
    XCTAssertEqual(
        viewModel.settingsMessage,
        "Fast mode settings were saved, but CLIProxyAPI could not restart: Restart failed"
    )
}
```

`StubProxyServiceStarter`에 `restartError`를 별도 주입해 start/stop은 성공하고 restart만 실패하도록 한다.

- [ ] **Step 3: ViewModel tests 실패 확인**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testSavingCodexFastMode|DashboardViewModelTests/testFast'
```

Expected: FAIL because Fast config save does not request restart and the stub lacks `restartError`.

- [ ] **Step 4: generic restart reason과 pending state 구현**

`DashboardViewModel` 내부에 추가한다.

```swift
private enum ProxyConfigurationRestartReason: Hashable {
    case apiKey
    case fastMode
}

private var pendingProxyConfigurationRestartReasons: Set<ProxyConfigurationRestartReason> = []
```

기존 `pendingAPIKeyRestart`는 제거한다.

`saveConfig` 시작 시 old/new logical Fast snapshot을 검증한다. 여기서는 API Key credential 유무와 무관하게 역할 설정 자체의 변경을 감지한다. API Key add/remove transaction도 `.apiKey` reason을 별도로 추가하므로 restart 누락 없이 같은 pending set에서 coalesce된다.

```swift
let hasCodexAPIKey = isAPIKeyConfigured(.codexAPIKey)
let oldFastConfiguration = try CodexFastConfiguration(config: config)
let newFastConfiguration = try CodexFastConfiguration(config: updatedConfig)
let fastConfigurationChanged = oldFastConfiguration != newFastConfiguration
```

config save가 완전히 성공한 뒤에만 restart를 요청한다.

```swift
if fastConfigurationChanged {
    requestProxyConfigurationRestart(reason: .fastMode)
}
```

API key 변경의 기존 `requestServerRestartAfterAPIKeyChange()` 호출은 다음 generic 함수로 교체한다.

```swift
requestProxyConfigurationRestart(reason: .apiKey)
```

OpenAI API Key가 새로 추가되거나 제거되면 `saveConfig` snapshot 시점의 secret 존재 여부가 transaction 전후로 달라질 수 있으므로, API Key transaction은 `.apiKey` reason을 항상 추가한다. Fast snapshot reason과 동일 pending set에 들어가므로 실제 restart는 한 번만 수행된다.

- [ ] **Step 5: restart request와 coalescing 구현**

기존 `requestServerRestartAfterAPIKeyChange`를 다음 의미로 교체한다.

```swift
private func requestProxyConfigurationRestart(reason: ProxyConfigurationRestartReason) {
    guard serverControlState.isRunning || isServerActionInProgress || serverControlState.isTransitioning else {
        return
    }
    pendingProxyConfigurationRestartReasons.insert(reason)
    guard !isServerActionInProgress, !serverControlState.isTransitioning else { return }
    Task { await restartForPendingConfigurationChanges() }
}

private func restartForPendingConfigurationChanges() async {
    guard !pendingProxyConfigurationRestartReasons.isEmpty else { return }
    let reasons = pendingProxyConfigurationRestartReasons
    pendingProxyConfigurationRestartReasons.removeAll()

    await restartServer()

    if case .error(let message) = serverControlState, reasons.contains(.fastMode) {
        settingsMessage = "Fast mode settings were saved, but CLIProxyAPI could not restart: \(message)"
    }
}
```

`performServerAction` 완료 시 기존 `pendingAPIKeyRestart` branch를 다음으로 교체한다. 현재 action 도중 들어온 여러 이유를 한 번에 drain한다.

```swift
if !pendingProxyConfigurationRestartReasons.isEmpty, serverControlState.isRunning {
    let reasons = pendingProxyConfigurationRestartReasons
    pendingProxyConfigurationRestartReasons.removeAll()
    do {
        try await proxyService.restart(port: config.port)
        await refreshUntilServerIsReady()
        serverControlState = serverStatus.severity == .ready ? .running : .stopped
    } catch {
        let message = error.localizedDescription
        serverControlState = .error(message)
        if reasons.contains(.fastMode) {
            settingsMessage = "Fast mode settings were saved, but CLIProxyAPI could not restart: \(message)"
        }
    }
} else if !serverControlState.isRunning {
    pendingProxyConfigurationRestartReasons.removeAll()
}
```

일반 `restartServer()` 경로와 pending 경로가 같은 status update를 사용하도록 private `restartProxyAndRefresh()` throwing helper를 추가한다.

```swift
private func restartProxyAndRefresh() async throws {
    try await proxyService.restart(port: config.port)
    await refreshUntilServerIsReady()
    serverControlState = serverStatus.severity == .ready ? .running : .stopped
}
```

`restartServer()`의 action closure와 pending drain branch 모두 이 helper를 호출한다. helper는 `proxyService.restart`, readiness refresh, final `serverControlState` 갱신만 담당한다.

- [ ] **Step 6: test stub을 restart-only error를 지원하도록 변경**

`StubProxyServiceStarter`에 추가한다.

```swift
private let restartError: Error?

init(
    error: Error? = nil,
    restartError: Error? = nil,
    startDelayNanoseconds: UInt64 = 0,
    stopDelayNanoseconds: UInt64 = 0
) {
    self.error = error
    self.restartError = restartError
    self.startDelayNanoseconds = startDelayNanoseconds
    self.stopDelayNanoseconds = stopDelayNanoseconds
}

func restart(port: Int) async throws {
    lock.withLock { _restartPorts.append(port) }
    if let restartError { throw restartError }
    if let error { throw error }
}
```

- [ ] **Step 7: restart 관련 테스트 통과 확인**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: PASS, 기존 API key·subscription restart tests와 새 Fast tests 모두 0 failures.

- [ ] **Step 8: Task 6 커밋**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: restart proxy for Codex fast changes

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: 사용자 문서와 전체 검증

**Files:**
- Modify: `README.md:14-22,40-55`
- Modify: `README.en.md:14-22,40-55`
- Verify: all changed production and test files

**Interfaces:**
- Documents: 역할별 Fast mode, 지원 모델 제한, 사용량 증가 가능성
- Verifies: development build, full XCTest suite, generated YAML, git diff

- [ ] **Step 1: 한국어 README에 Fast mode 설명 추가**

`README.md` 주요 기능에 다음 bullet을 추가한다.

```markdown
- 지원되는 Codex 모델에서 Opus·Sonnet·Haiku 역할별 Fast mode 설정
```

시작하기의 계정 설정 단계 아래에 다음 설명을 추가한다.

```markdown
Codex 계정과 OpenAI API Key에서는 각 Claude 역할에 매핑할 GPT 모델, reasoning, context window, Fast mode를 설정할 수 있습니다. Fast mode는 지원 모델에서만 활성화되며 약 1.5배 빠를 수 있지만 사용량이나 크레딧 소비가 늘어날 수 있습니다.
```

- [ ] **Step 2: 영어 README에 동일 내용 추가**

`README.en.md`에 다음 bullet과 설명을 추가한다.

```markdown
- Configure Fast mode per Opus, Sonnet, and Haiku role on supported Codex models.
```

```markdown
For Codex accounts and OpenAI API keys, each Claude role can select a GPT model, reasoning effort, context window, and Fast mode. Fast mode is available only on supported models and can be about 1.5× faster while consuming more usage or credits.
```

- [ ] **Step 3: targeted Core tests 실행**

Run:

```bash
swift test --filter 'CodexFastModeTests|AppConfigTests|ProxyModelClientTests|ProxyServiceManagerTests|ShellFunctionRendererTests|RoundRobinSelectionServiceTests'
```

Expected: PASS, 0 failures.

- [ ] **Step 4: targeted App tests 실행**

Run:

```bash
swift test --filter 'CodexRoleRoutingOptionsTests|ProviderSettingsSheetMetricsTests|SettingsNavigationTests|DashboardViewModelTests'
```

Expected: PASS, 0 failures.

- [ ] **Step 5: 전체 test suite 실행**

Run:

```bash
swift test
```

Expected: PASS. Baseline은 714 tests, 0 failures였으며 새 tests가 추가된 더 큰 test count에서 0 failures여야 한다.

- [ ] **Step 6: development build 생성**

Run:

```bash
swift build -c debug --product CLIProxyManager
```

Expected: `Build complete!` and exit status 0.

- [ ] **Step 7: 실제 앱과 생성 YAML 검증**

프로젝트의 `run` skill을 사용해 development app을 실행한다. 다음을 직접 확인한다.

1. Codex OAuth 설정에서 Opus만 Fast를 켤 수 있다.
2. 지원 모델은 toggle enabled, `gpt-5.4-mini` 또는 custom model은 disabled다.
3. Fast toggle 아래에 정확한 안내 문구가 보인다.
4. 저장 후 실행 중 proxy가 한 번 restart되고 ready로 복귀한다.
5. 관리 config 경로의 `config.yaml`에 다음 형태가 생긴다.

```yaml
oauth-model-alias:
  codex:
    - name: "gpt-5.6-sol"
      alias: "gpt-5.6-sol-cpm-fast"
      fork: true
payload:
  override:
    - models:
        - name: "gpt-5.6-sol-cpm-fast"
          protocol: "codex"
      params:
        service_tier: priority
```

6. OpenAI API Key Fast 설정에서는 `codex-api-key[].models` mapping이 추가된다.
7. Fast를 모두 끄고 저장하면 관리 alias와 payload section이 제거된다.
8. 생성 shell function의 Fast role은 `-cpm-fast(reasoning)`이고 일반 role은 canonical model을 유지한다.

- [ ] **Step 8: diff와 whitespace 검증**

Run:

```bash
git diff --check
git status --short
git diff --stat main...HEAD
git diff main...HEAD -- README.md README.en.md Sources Tests
```

Expected:

- `git diff --check`: no output, exit status 0
- 의도하지 않은 binary, `.build`, 사용자 config, secret file 없음
- Fast를 사용하지 않는 fixture의 expected output이 불필요하게 바뀌지 않음

- [ ] **Step 9: 최종 문서·검증 커밋**

```bash
git add README.md README.en.md
git commit -m "docs: document Codex fast mode

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 10: 완료 전 verification skill 실행**

`superpowers:verification-before-completion`을 호출해 full tests, development build, 실제 앱 검증 결과를 다시 확인한다. 검증 결과에 실패가 있으면 완료를 선언하지 않고 해당 task를 `in_progress` 상태로 유지한다.
