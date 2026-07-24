# Codex Context Window Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CLIProxyManager가 CLIProxyAPI의 Codex 모델 metadata에서 실제 context window를 자동 감지하고, Claude Code 실행 환경에 `[1m]`과 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`를 안전하게 반영하도록 구현한다.

**Architecture:** `/v1/models?client_version=0.144.0`의 `context_window` metadata를 `CodexModelOption`으로 전달하고, 설정 화면의 기존 수동 context picker를 읽기 전용 감지값으로 교체한다. 저장된 `AppConfig.CodexRole.detectedContextWindow`는 모델 식별자의 `[1m]` suffix와 셸 함수의 auto-compact 환경변수를 생성하며, 세 역할의 확장 context 값 중 최솟값을 사용한다. 번들 CLIProxyAPI는 같은 변경 묶음에서 7.2.97로 갱신되되 proxy 설정/YAML 파싱은 변경하지 않는다.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation `Codable`, XCTest, Swift Package Manager, Bash vendor script, macOS 15+

## Global Constraints

- `detectedContextWindow > 200_000`인 역할만 확장 context로 취급하고 `[1m]`을 붙인다. 정확히 `200_000`은 Claude Code 기본 context와 같으므로 override하지 않는다.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW`는 Opus/Sonnet/Haiku 중 `> 200_000`인 감지값의 최솟값으로 설정하며, 해당 값이 없으면 환경변수 줄 자체를 생성하지 않는다.
- 사용자가 context 크기를 입력하거나 제한하는 컨트롤을 제공하지 않는다. UI는 감지값만 읽기 전용으로 표시한다.
- metadata가 일시적으로 사라진 같은 모델은 직전 성공 값을 유지한다. 사용자가 다른 모델로 변경했는데 새 모델의 context metadata를 확인할 수 없으면 stale 값을 제거한다.
- 구버전 JSON의 `contextWindow` 문자열 키는 조용히 무시하고, 새 `detectedContextWindow`는 `Int?`로 round-trip한다.
- `CodexContextWindow` enum과 `CodexRole.contextWindow`는 최종 코드에서 완전히 삭제한다. 호환용 enum이나 수동 override shim을 남기지 않는다.
- `CodexFastMode`는 fast alias와 reasoning 조합만 계속 담당한다. Context suffix는 `AppConfig.CodexRole.modelIdentifier`에서 추가한다.
- Claude OAuth·Claude API Key 경로와 CLIProxyAPI 자체 요청 파싱/YAML 형식은 변경하지 않는다.
- 번들 CLIProxyAPI 버전은 정확히 `7.2.97`로 갱신한다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, 격리된 development app bundle build까지 수행한다. 앱 실행과 Claude Code 실제 동작 확인은 사용자가 수행한다.

---

## Task 1: `CodexModelOption`에 `contextWindow` 필드 추가

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift` (기존 파일에 `CodexModelOption(id:...)` 생성자 호출이 이미 다수 존재 — `contextWindow`를 옵셔널 파라미터로 추가하면 기존 호출부는 그대로 컴파일된다)

**Interfaces:**
- Produces: `public struct CodexModelOption { ...; public var contextWindow: Int? }`, 생성자에 `contextWindow: Int? = nil` 파라미터 추가.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift` 맨 아래(마지막 `}` 앞, `testClaudeModelOptionsRejectBlankPrefixBeforeNetworkRequest` 다음)에 추가:

```swift
    func testCodexModelOptionContextWindowDefaultsToNil() {
        let option = CodexModelOption(id: "gpt-5.6-sol")

        XCTAssertNil(option.contextWindow)
    }

    func testCodexModelOptionContextWindowCanBeSet() {
        let option = CodexModelOption(id: "gpt-5.6-sol", contextWindow: 372_000)

        XCTAssertEqual(option.contextWindow, 372_000)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ProxyModelClientTests/testCodexModelOptionContextWindowCanBeSet`
Expected: FAIL — `CodexModelOption` has no member `contextWindow` / extra argument `contextWindow` in call

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift` 전체를 다음으로 교체:

```swift
import Foundation

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
    public var contextWindow: Int?

    public init(
        id: String,
        supportedReasoning: [AppConfig.CodexReasoning] = [],
        defaultReasoning: AppConfig.CodexReasoning? = nil,
        supportsFastMode: Bool? = nil,
        contextWindow: Int? = nil
    ) {
        let canonicalID = CodexFastMode.canonicalModel(from: id)
        self.id = canonicalID
        self.supportedReasoning = supportedReasoning
        self.defaultReasoning = defaultReasoning
        self.supportsFastMode = supportsFastMode ?? Self.supportsFastModeFallback(for: canonicalID)
        self.contextWindow = contextWindow
    }

    static func supportsFastModeFallback(for id: String) -> Bool {
        let canonicalID = CodexFastMode.canonicalModel(from: id)
        let unprefixedID = canonicalID.split(separator: "/").last.map(String.init) ?? canonicalID
        return fastModeFallbackModels.contains(unprefixedID.lowercased())
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ProxyModelClientTests`
Expected: PASS (모든 `CodexModelOption` 관련 테스트, 기존 테스트 포함)

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
git commit -m "feat: add contextWindow field to CodexModelOption"
```

---

## Task 2: `ProxyModelClient`가 `context_window` metadata를 파싱

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`

**Interfaces:**
- Consumes: Task 1의 `CodexModelOption(id:supportedReasoning:defaultReasoning:supportsFastMode:contextWindow:)`
- Produces: `codexModelOptions(port:modelPrefix:)`가 반환하는 각 `CodexModelOption.contextWindow`에 CLIProxyAPI metadata의 `context_window` 값이 채워짐(없으면 `nil`).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`의 `testCodexModelOptionsCombineScopedModelsWithReasoningMetadata` 테스트 바로 다음에 추가:

```swift
    func testCodexModelOptionsParseContextWindowMetadata() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300}]}"#.utf8)
        let metadata = Data(#"{"models":[{"slug":"codex-work/gpt-5.6-sol","context_window":372000}]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.6-sol", supportsFastMode: true, contextWindow: 372_000)])
    }

    func testCodexModelOptionsMissingContextWindowFieldDecodesToNil() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/custom-model","owned_by":"openai","created":300}]}"#.utf8)
        let metadata = Data(#"{"models":[{"slug":"codex-work/custom-model"}]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

        XCTAssertNil(models.first?.contextWindow)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ProxyModelClientTests/testCodexModelOptionsParseContextWindowMetadata`
Expected: FAIL — `contextWindow` mismatch (nil vs 372000), `CodexModelOption` 값 불일치

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`에서 `CodexClientModelsResponse.Model`에 `context_window` 필드를 추가하고, `codexModelOptions(port:modelPrefix:)` 내부에서 이를 `CodexModelOption`에 전달한다.

먼저 `private struct CodexClientModelsResponse` 내부 `struct Model`을 다음으로 교체(파일 하단, `private struct CodexClientModelsResponse: Decodable { ... }` 블록):

```swift
    struct Model: Decodable {
        var slug: String
        var supportedReasoningLevels: [ReasoningLevel]
        var defaultReasoningLevel: String?
        var visibility: String?
        var serviceTiers: [ServiceTier]
        var additionalSpeedTiers: [String]
        var contextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case visibility
            case serviceTiers = "service_tiers"
            case additionalSpeedTiers = "additional_speed_tiers"
            case contextWindow = "context_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try container.decode(String.self, forKey: .slug)
            supportedReasoningLevels = try container.decodeIfPresent(
                [ReasoningLevel].self,
                forKey: .supportedReasoningLevels
            ) ?? []
            defaultReasoningLevel = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel)
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
            serviceTiers = try container.decodeIfPresent([ServiceTier].self, forKey: .serviceTiers) ?? []
            additionalSpeedTiers = try container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        }
    }
```

다음으로 `private func codexModelOptions(port:modelPrefix:)` 내부의 `return scopedIDs.map { id in ... }` 블록에서 `CodexModelOption(...)` 생성 호출에 `contextWindow: metadata.contextWindow`를 추가한다:

```swift
            return CodexModelOption(
                id: id,
                supportedReasoning: supported,
                defaultReasoning: defaultReasoning.flatMap { supported.contains($0) ? $0 : nil },
                supportsFastMode: metadataSupportsFast
                    || CodexModelOption.supportsFastModeFallback(for: id),
                contextWindow: metadata.contextWindow
            )
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ProxyModelClientTests`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
git commit -m "feat: parse context_window metadata into CodexModelOption"
```

---

## Task 3: `AppConfig.CodexRole.detectedContextWindow`로 `CodexContextWindow` enum 대체

이 태스크는 컴파일이 깨지는 광범위한 파급 효과가 있다(모든 `CodexRole(...)` 생성 호출과 `contextWindow: .auto` 등 사용처). Step 3에서 한 번에 모두 고친다.

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` (1곳: `CodexFastConfigurationInput.Role.codexRole`)
- Modify: `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift` (Task 6에서 별도 처리 — 이 태스크에서는 컴파일이 깨지지 않도록 Picker 부분만 임시로 제거)
- Modify: 아래 나열된 모든 테스트 파일에서 `contextWindow: .xxx` 인자를 제거
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

**Interfaces:**
- Consumes: 없음(신규 저장 모델)
- Produces: `public struct CodexRole { public var model: String; public var reasoning: CodexReasoning; public var detectedContextWindow: Int?; public var fastModeEnabled: Bool }`. `CodexContextWindow` enum 삭제. `CodexRole.init(model:reasoning:fastModeEnabled:)` — `detectedContextWindow` 파라미터는 기본값 `nil`을 가지는 별도 오버로드로 제공하지 않고, **명시적으로 매번 넘기게** 하지 않는다: `detectedContextWindow: Int? = nil`을 기본 파라미터로 추가해 기존 호출부(`contextWindow:` 인자 제거 후) `CodexRole(model:reasoning:fastModeEnabled:)` 형태로 컴파일되게 한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`의 `testCodexRoleFastModeRoundTripsAndRendersManagedAlias` 테스트 바로 다음에 추가:

```swift
    func testCodexRoleDetectedContextWindowRoundTrips() throws {
        let role = AppConfig.CodexRole(
            model: "gpt-5.6-sol",
            reasoning: .xhigh,
            detectedContextWindow: 372_000,
            fastModeEnabled: false
        )

        let encoded = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(AppConfig.CodexRole.self, from: encoded)

        XCTAssertEqual(decoded.detectedContextWindow, 372_000)
    }

    func testCodexRoleDefaultsDetectedContextWindowToNilWhenMissing() throws {
        let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh"}"#.utf8)

        let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

        XCTAssertNil(role.detectedContextWindow)
    }

    func testCodexRoleIgnoresLegacyContextWindowStringKey() throws {
        let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"}"#.utf8)

        let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

        XCTAssertNil(role.detectedContextWindow)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter AppConfigTests/testCodexRoleDetectedContextWindowRoundTrips`
Expected: FAIL — 컴파일 에러(`detectedContextWindow` 없음) 또는 extra argument

- [ ] **Step 3: 최소 구현 — 전체 코드베이스 갱신**

`Sources/CLIProxyManagerCore/Config/AppConfig.swift`에서 `CodexContextWindow` enum과 `CodexRole` 구조체를 다음으로 교체(기존 라인 94~137 대체):

```swift
    public struct CodexRole: Codable, Equatable, Sendable {
        public var model: String
        public var reasoning: CodexReasoning
        public var detectedContextWindow: Int?
        public var fastModeEnabled: Bool

        public init(
            model: String,
            reasoning: CodexReasoning,
            detectedContextWindow: Int? = nil,
            fastModeEnabled: Bool = false
        ) {
            self.model = model
            self.reasoning = reasoning
            self.detectedContextWindow = detectedContextWindow
            self.fastModeEnabled = fastModeEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case model, reasoning, detectedContextWindow, fastModeEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            reasoning = try container.decode(CodexReasoning.self, forKey: .reasoning)
            detectedContextWindow = try container.decodeIfPresent(Int.self, forKey: .detectedContextWindow)
            fastModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .fastModeEnabled) ?? false
        }

        public var modelIdentifier: String {
            let base = CodexFastMode.modelIdentifier(
                model: model,
                reasoning: reasoning,
                fastModeEnabled: fastModeEnabled
            )
            guard let detectedContextWindow, detectedContextWindow > 200_000 else { return base }
            return base + "[1m]"
        }
    }
```

주의: 이전 `CodexContextWindow` enum 선언 전체(`public enum CodexContextWindow: String, Codable, CaseIterable, Sendable { case auto; case context200k = "200k"; ... }`)를 삭제한다. `CodingKeys`에 `contextWindow`가 없으므로 구버전 JSON의 `"contextWindow": "auto"` 키는 디코드 시 자동으로 무시된다(명시적 처리 불필요 — `Decodable`은 알려지지 않은 키를 무시한다).

`AppConfig.default`의 다음 부분(라인 536~544 부근)을 갱신:

```swift
        ccodex: Codex(
            opus: CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh),
            sonnet: CodexRole(model: "gpt-5.6-terra", reasoning: .medium),
            haiku: CodexRole(model: "gpt-5.6-terra", reasoning: .low)
        ),
```

이제 `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`의 `CodexFastConfigurationInput.Role.codexRole` 계산 프로퍼티(라인 130~132 부근)를 갱신:

```swift
            var codexRole: AppConfig.CodexRole {
                .init(model: model, reasoning: .auto, fastModeEnabled: fastModeEnabled)
            }
```

다음으로 `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`의 Context Picker 블록(라인 90~97)을 **임시로** 삭제해 컴파일을 통과시킨다(Task 6에서 읽기 전용 라벨로 교체):

```swift
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

이제 아래 모든 파일에서 `CodexRole(...)` / `.init(...)` 호출의 `contextWindow: .xxx` 인자를 **제거**한다(`sed`류 일괄 치환 대신 각 파일을 열어 `contextWindow: .auto,`, `contextWindow: .context1m,`, `contextWindow: .context400k,`, `contextWindow: .context200k,` 패턴과 그 앞뒤 쉼표를 정리한다):

- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` (라인 131 부근, 이미 위에서 처리됨)
- `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/SettingsNavigationTests.swift`
- `Tests/CLIProxyManagerCoreTests/AppConfigStoreTests.swift`
- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` (기존 테스트들의 `contextWindow: .auto` 등 제거 — 이번 태스크에서 새로 추가한 3개 테스트는 그대로 둔다)
- `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
- `Tests/CLIProxyManagerCoreTests/DashboardViewModelTests.swift`
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
- `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

각 파일에서 예를 들어:

```swift
// Before
AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh, contextWindow: .auto)
// After
AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh)
```

```swift
// Before
.init(model: "gpt-5.6-sol", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true)
// After
.init(model: "gpt-5.6-sol", reasoning: .xhigh, fastModeEnabled: true)
```

`.context1m` / `.context400k` / `.context200k`을 쓰던 테스트(예: `ShellFunctionRendererTests.testRenderUsesConfiguredCodexRoleSettings`, `testCodexAPICommandUsesItsOwnRoutingAndSkipFlag`, `RoundRobinSelectionServiceTests`의 일부)는 이번 태스크에서는 단순히 해당 인자를 제거만 한다(주장했던 `[1m]` suffix 검증은 Task 5에서 별도로 다시 작성한다). `AppConfigTests.swift`의 JSON 문자열 리터럴에 남아있는 `"contextWindow": "auto"` 등의 키는 **그대로 둔다**(구버전 호환 검증 대상이며, `CodingKeys`에 없는 키이므로 디코드 시 무시된다) — 단, `testOAuthCommandProfilesDecodeAndEncodeRoundTrip`과 `testDecodedConfigPreservesSavedCommandNamesAndClaudeAPIModel` 등에서 `.codex?.sonnet.contextWindow` 같은 **프로퍼티 접근 어서션**은 `.codex?.sonnet.detectedContextWindow`로 바꾸고, 기대값을 `nil`로 변경한다(구버전 문자열 키는 새 필드에 매핑되지 않으므로).

- [ ] **Step 4: 전체 테스트 통과 확인**

Run: `swift build`
Expected: 컴파일 성공(에러 없음)

Run: `swift test --filter 'AppConfigTests|CodexFastModeTests|CodexRoleRoutingOptionsTests'`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources Tests
git commit -m "refactor: replace CodexContextWindow enum with detected context window"
```

---

## Task 4: `CodexRoleRoutingOptions.normalizedRole`가 `detectedContextWindow`를 정규화

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`
- Test: `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`

**Interfaces:**
- Consumes: Task 1의 `CodexModelOption.contextWindow: Int?`, Task 3의 `AppConfig.CodexRole.detectedContextWindow: Int?`
- Produces: `normalizedRole(_:model:options:)`가 반환하는 role의 `detectedContextWindow`가 옵션 목록에서 찾은 `contextWindow` 값으로 갱신됨(못 찾으면 기존 값 유지).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`의 `options` 배열 선언을 다음으로 교체(세 번째 옵션에 `contextWindow` 추가, 첫 옵션에도 추가):

```swift
    private let options = [
        CodexModelOption(
            id: "gpt-5.5",
            supportedReasoning: [.low, .medium, .high, .xhigh],
            defaultReasoning: .medium,
            supportsFastMode: true,
            contextWindow: 372_000
        ),
        CodexModelOption(
            id: "gpt-5.6-sol",
            supportedReasoning: [.low, .medium, .high, .xhigh, .max],
            defaultReasoning: .low,
            supportsFastMode: false
        ),
        CodexModelOption(
            id: "custom-model",
            supportedReasoning: [.low, .medium],
            defaultReasoning: .medium,
            supportsFastMode: false,
            contextWindow: 128_000
        )
    ]
```

같은 파일 끝(마지막 `}` 앞)에 추가:

```swift
    func testNormalizedRoleUpdatesDetectedContextWindowFromMatchingOption() {
        let role = AppConfig.CodexRole(model: "custom-model", reasoning: .auto, detectedContextWindow: nil)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "gpt-5.5", options: options)

        XCTAssertEqual(normalized.detectedContextWindow, 372_000)
    }

    func testNormalizedRolePreservesDetectedContextWindowWhenModelUnknown() {
        let role = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .auto, detectedContextWindow: 372_000)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "missing-model", options: options)

        XCTAssertEqual(normalized.detectedContextWindow, 372_000)
    }

    func testNormalizedRoleClearsDetectedContextWindowWhenOptionHasNoValue() {
        let role = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .auto, detectedContextWindow: 372_000)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "gpt-5.6-sol", options: options)

        XCTAssertNil(normalized.detectedContextWindow)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter CodexRoleRoutingOptionsTests/testNormalizedRoleUpdatesDetectedContextWindowFromMatchingOption`
Expected: FAIL — `normalized.detectedContextWindow` is `nil`, expected `372000`

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`의 `normalizedRole(_:model:options:)` 함수(라인 65~83)를 다음으로 교체:

```swift
    static func normalizedRole(
        _ role: AppConfig.CodexRole,
        model: String,
        options: [CodexModelOption]
    ) -> AppConfig.CodexRole {
        var updated = role
        let previousModel = CodexFastMode.canonicalModel(from: role.model)
        updated.model = CodexFastMode.canonicalModel(from: model)
        updated.reasoning = normalizedReasoning(
            currentReasoning: role.reasoning,
            model: updated.model,
            options: options
        )
        let capability = fastModeCapability(model: updated.model, options: options)
        if capability == .unsupported || (updated.model != previousModel && capability == .unknown) {
            updated.fastModeEnabled = false
        }
        if let matchedOption = options.first(where: { $0.id == updated.model }) {
            updated.detectedContextWindow = matchedOption.contextWindow
        }
        return updated
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter CodexRoleRoutingOptionsTests`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift
git commit -m "feat: normalize detectedContextWindow from live Codex model options"
```

---

## Task 5: `[1m]` suffix와 `CLAUDE_CODE_AUTO_COMPACT_WINDOW` 셸 export

**Files:**
- Create: `Sources/CLIProxyManagerCore/Routing/CodexContextWindowExport.swift`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Modify: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` (modelIdentifier `[1m]` 동작)
- Test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CodexContextWindowExportTests.swift` (신규)

**Interfaces:**
- Consumes: Task 3의 `AppConfig.CodexRole.detectedContextWindow`, `AppConfig.Codex { opus, sonnet, haiku }`
- Produces: `enum CodexContextWindowExport { static func autoCompactWindow(for codex: AppConfig.Codex) -> Int? }`. `ShellFunctionRenderer`가 생성하는 각 함수 본문에 조건부로 `CLAUDE_CODE_AUTO_COMPACT_WINDOW='<value>' \` 줄 추가. `RoundRobinSelectionService.shellEnvironmentAssignments`가 반환하는 개행 구분 문자열에 조건부로 `CLAUDE_CODE_AUTO_COMPACT_WINDOW='<value>'` 줄 추가.

### Part A — `modelIdentifier`의 `[1m]` suffix 테스트(Task 3에서 이미 구현됨, 여기서 테스트만 추가)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`의 `testCodexRoleFastModeRoundTripsAndRendersManagedAlias` 다음에 추가:

```swift
    func testCodexRoleModelIdentifierAppendsOneMillionSuffixForExtendedContext() {
        let role = AppConfig.CodexRole(
            model: "gpt-5.6-sol",
            reasoning: .xhigh,
            detectedContextWindow: 372_000,
            fastModeEnabled: true
        )

        XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol-fast(xhigh)[1m]")
    }

    func testCodexRoleModelIdentifierOmitsSuffixAtOrBelowStandardContext() {
        let atStandard = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: 200_000)
        let unknown = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: nil)

        XCTAssertEqual(atStandard.modelIdentifier, "gpt-5.5(medium)")
        XCTAssertEqual(unknown.modelIdentifier, "gpt-5.5(medium)")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter AppConfigTests/testCodexRoleModelIdentifierAppendsOneMillionSuffixForExtendedContext`
Expected: PASS 이미 (Task 3에서 `modelIdentifier` 구현을 완료했으므로) — 만약 PASS라면 그대로 다음 단계로 진행. FAIL이라면 Task 3의 `modelIdentifier` 구현을 다시 확인한다.

- [ ] **Step 3: 필요 시 구현 보정**

Task 3에서 이미 올바르게 구현했다면 변경 불필요. (이 하위 태스크는 회귀 방지 테스트 추가 목적)

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppConfigTests`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "test: cover [1m] suffix behavior on CodexRole.modelIdentifier"
```

### Part B — `CodexContextWindowExport` 헬퍼

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/CodexContextWindowExportTests.swift` 신규 파일 생성:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CodexContextWindowExportTests: XCTestCase {
    func testAutoCompactWindowReturnsMinimumAmongExtendedContextRoles() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000),
            sonnet: .init(model: "gpt-5.4-mini", reasoning: .medium, detectedContextWindow: 400_000),
            haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
        )

        XCTAssertEqual(CodexContextWindowExport.autoCompactWindow(for: codex), 372_000)
    }

    func testAutoCompactWindowReturnsNilWhenNoRoleExceedsStandardContext() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.5", reasoning: .xhigh, detectedContextWindow: 200_000),
            sonnet: .init(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: nil),
            haiku: .init(model: "gpt-5.5", reasoning: .low)
        )

        XCTAssertNil(CodexContextWindowExport.autoCompactWindow(for: codex))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter CodexContextWindowExportTests`
Expected: FAIL — no such module member `CodexContextWindowExport` / cannot find type

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerCore/Routing/CodexContextWindowExport.swift` 신규 생성:

```swift
import Foundation

public enum CodexContextWindowExport {
    public static func autoCompactWindow(for codex: AppConfig.Codex) -> Int? {
        [codex.opus, codex.sonnet, codex.haiku]
            .compactMap(\.detectedContextWindow)
            .filter { $0 > 200_000 }
            .min()
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter CodexContextWindowExportTests`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Routing/CodexContextWindowExport.swift Tests/CLIProxyManagerCoreTests/CodexContextWindowExportTests.swift
git commit -m "feat: add CodexContextWindowExport helper for auto-compact window"
```

### Part C — `ShellFunctionRenderer`에 `CLAUDE_CODE_AUTO_COMPACT_WINDOW` 반영

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`의 `testLegacyCodexCommandRendersRoleSpecificFastAlias` 다음에 추가:

```swift
    func testLegacyCodexCommandExportsAutoCompactWindowForExtendedContextRole() throws {
        var config = configuredCommands()
        config.ccodex = .init(
            opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000, fastModeEnabled: true),
            sonnet: .init(model: "gpt-5.6-sol", reasoning: .medium, detectedContextWindow: 372_000),
            haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
        )

        let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.6-sol-fast(xhigh)[1m]'"))
        XCTAssertTrue(script.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW='372000'"))
    }

    func testLegacyCodexCommandOmitsAutoCompactWindowWhenNoRoleExtendsContext() throws {
        var config = configuredCommands()
        config.ccodex = .init(
            opus: .init(model: "gpt-5.5", reasoning: .xhigh, detectedContextWindow: 200_000),
            sonnet: .init(model: "gpt-5.5", reasoning: .medium),
            haiku: .init(model: "gpt-5.5", reasoning: .low)
        )

        let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

        XCTAssertFalse(script.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
    }

    func testCodexAPICommandExportsAutoCompactWindow() throws {
        var config = configuredCommands()
        config.commands.ccodexapi = "ccodexapi"
        config.codexAPI = .init(
            codex: .init(
                opus: .init(model: "gpt-5.4", reasoning: .xhigh, detectedContextWindow: 1_050_000),
                sonnet: .init(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: 272_000),
                haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
            )
        )

        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cpm",
            enabledFunctions: .init(claudeOAuth: false, codex: false, claudeAPI: false, codexAPI: true)
        ).render()

        let function = renderedFunction(named: config.commands.ccodexapi, in: script)
        XCTAssertTrue(function.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW='272000'"))
    }

    func testOAuthCommandProfileExportsAutoCompactWindow() throws {
        var config = configuredCommands()
        config.oauthCommandProfiles = [
            .init(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "ccwork",
                codex: .init(
                    opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000),
                    sonnet: .init(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: 272_000),
                    haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
                ),
                modelPrefix: "codex-work"
            )
        ]

        let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

        let function = renderedFunction(named: "ccwork", in: script)
        XCTAssertTrue(function.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW='272000'"))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter ShellFunctionRendererTests/testLegacyCodexCommandExportsAutoCompactWindowForExtendedContextRole`
Expected: FAIL — `CLAUDE_CODE_AUTO_COMPACT_WINDOW` not found in script

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`에서 세 함수를 수정한다.

`renderLegacyOAuthFunctions()`(라인 178~213)의 codex 분기를 수정:

```swift
        if enabledFunctions.codex, hasCommandName(config.commands.ccodex) {
            let autoCompactWindow = CodexContextWindowExport.autoCompactWindow(for: config.ccodex)
            let autoCompactLine = autoCompactWindow.map { "  CLAUDE_CODE_AUTO_COMPACT_WINDOW='\($0)' \\\n" } ?? ""
            script += """
            \(config.commands.ccodex)() {
              if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:\(port)/v1/models" >/dev/null; then
                echo "CLIProxyAPI Manager is not running or authentication settings are invalid. Open the app to check the status."
                return 1
              fi

              ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)" \\
              ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
              ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellSingleQuoted(opusModel)) \\
              ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellSingleQuoted(sonnetModel)) \\
              ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellSingleQuoted(haikuModel)) \\
            \(autoCompactLine)  \(claudeCommand)
            }

            """
        }
```

`renderCodexAPIFunction()`(라인 145~164)을 수정:

```swift
    private func renderCodexAPIFunction() -> String {
        let claudeCommand = claudeCommand(skipPermissions: config.codexAPI.dangerousPermissionsEnabled)
        let codex = config.codexAPI.codex
        let autoCompactWindow = CodexContextWindowExport.autoCompactWindow(for: codex)
        let autoCompactLine = autoCompactWindow.map { "  CLAUDE_CODE_AUTO_COMPACT_WINDOW='\($0)' \\\n" } ?? ""
        return """
        \(config.commands.ccodexapi)() {
          if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:\(config.port)/v1/models" | grep -q 'cpm-codex-api/'; then
            echo "CLIProxyAPI Manager is not running or the OpenAI API key is not configured. Start it with cpm start, then retry."
            return 1
          fi

          ANTHROPIC_BASE_URL="http://127.0.0.1:\(config.port)" \\
          ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
          ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellSingleQuoted(prefixedModel(codex.opus.modelIdentifier, prefix: "cpm-codex-api"))) \\
          ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellSingleQuoted(prefixedModel(codex.sonnet.modelIdentifier, prefix: "cpm-codex-api"))) \\
          ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellSingleQuoted(prefixedModel(codex.haiku.modelIdentifier, prefix: "cpm-codex-api"))) \\
        \(autoCompactLine)  \(claudeCommand)
        }

        """
    }
```

`renderOAuthFunction(_:)`(라인 215~260)의 codex 분기(마지막 `return` 블록)를 수정:

```swift
        let errorMessage = "CLIProxyAPI Manager is not running or authentication settings are invalid. Start it with cpm start, then retry."
        let models = codexDefaultModels(for: commandProfile)
        let autoCompactWindow = CodexContextWindowExport.autoCompactWindow(for: commandProfile.codex ?? config.ccodex)
        let autoCompactLine = autoCompactWindow.map { "  CLAUDE_CODE_AUTO_COMPACT_WINDOW='\($0)' \\\n" } ?? ""

        return """
        \(commandName)() {
          if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:\(port)/v1/models" >/dev/null; then
            echo "\(errorMessage)"
            return 1
          fi

          ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)" \\
          ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
          ANTHROPIC_DEFAULT_OPUS_MODEL=\(shellSingleQuoted(models.opus)) \\
          ANTHROPIC_DEFAULT_SONNET_MODEL=\(shellSingleQuoted(models.sonnet)) \\
          ANTHROPIC_DEFAULT_HAIKU_MODEL=\(shellSingleQuoted(models.haiku)) \\
        \(autoCompactLine)  \(claudeCommand)
        }

        """
```

주의: 들여쓰기가 있는 Swift 멀티라인 문자열 리터럴은 첫 줄과 마지막 `"""` 기준 공통 들여쓰기를 제거하므로, `autoCompactLine`이 빈 문자열일 때도 줄바꿈이 하나 남지 않도록 `\(autoCompactLine)  \(claudeCommand)`처럼 같은 줄에 이어 붙인다(값이 있으면 `...\\\n  claude ...`, 없으면 그냥 `  claude ...`가 된다). 이 형태는 기존 `testRenderPassesArgumentsThroughToClaude`(각 함수 안에 `claude "$@"` 문자열이 정확히 존재하는지 카운트하는 테스트)에 영향 없음 — 공백 두 개는 이미 기존 코드의 들여쓰기와 동일하다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ShellFunctionRendererTests`
Expected: PASS (신규 4개 포함, 기존 테스트 회귀 없음)

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "feat: export CLAUDE_CODE_AUTO_COMPACT_WINDOW from ShellFunctionRenderer"
```

### Part D — `RoundRobinSelectionService`에 반영

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`의 `testCodexRoundRobinPrefixesFastAliasForOnlyEnabledRoles` 다음에 추가:

```swift
    func testCodexRoundRobinExportsAutoCompactWindowForExtendedContextRole() async throws {
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
                    opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000),
                    sonnet: .init(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: 272_000),
                    haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
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

        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-b/gpt-5.6-sol(xhigh)[1m]'"))
        XCTAssertTrue(output.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW='272000'"))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter RoundRobinSelectionServiceTests/testCodexRoundRobinExportsAutoCompactWindowForExtendedContextRole`
Expected: FAIL — `CLAUDE_CODE_AUTO_COMPACT_WINDOW` not found in output

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`의 `shellEnvironmentAssignments(profileID:config:authProfiles:)` 함수 끝부분(라인 96~102)을 수정:

```swift
        var assignments = [
            shellAssignment(name: "ANTHROPIC_DEFAULT_OPUS_MODEL", value: models.opus),
            shellAssignment(name: "ANTHROPIC_DEFAULT_SONNET_MODEL", value: models.sonnet),
            shellAssignment(name: "ANTHROPIC_DEFAULT_HAIKU_MODEL", value: models.haiku),
            shellAssignment(name: "CLIPROXY_ROUND_ROBIN_PROFILE", value: selected.authProfileID)
        ]
        if profile.provider == .codex,
           let autoCompactWindow = CodexContextWindowExport.autoCompactWindow(for: profile.codex ?? config.ccodex) {
            assignments.append(shellAssignment(name: "CLAUDE_CODE_AUTO_COMPACT_WINDOW", value: String(autoCompactWindow)))
        }
        return assignments.joined(separator: "\n")
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RoundRobinSelectionServiceTests`
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift
git commit -m "feat: export CLAUDE_CODE_AUTO_COMPACT_WINDOW from round-robin shell assignments"
```

---

## Task 6: `CodexRoleRoutingFields` UI를 읽기 전용 감지값 표시로 교체

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`
- Test: `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift` (표시 포맷 헬퍼용 신규 테스트)

**Interfaces:**
- Consumes: Task 3의 `AppConfig.CodexRole.detectedContextWindow: Int?`
- Produces: `CodexRoleRoutingOptions.contextWindowDisplay(_:) -> String` — `nil` 또는 `<= 200_000`이면 `"—"`, 그 외에는 `"372K"`, `"1.05M"` 형태의 축약 문자열.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift` 끝(마지막 `}` 앞)에 추가:

```swift
    func testContextWindowDisplayAbbreviatesLargeValues() {
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(372_000), "372K")
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(1_050_000), "1.05M")
    }

    func testContextWindowDisplayShowsDashForUnknownOrStandardValues() {
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(nil), "—")
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(200_000), "—")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter CodexRoleRoutingOptionsTests/testContextWindowDisplayAbbreviatesLargeValues`
Expected: FAIL — no member `contextWindowDisplay`

- [ ] **Step 3: 최소 구현**

`Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`의 `fastModeHelpText` 선언 다음에 추가:

```swift
    static func contextWindowDisplay(_ contextWindow: Int?) -> String {
        guard let contextWindow, contextWindow > 200_000 else { return "—" }
        if contextWindow % 1_000_000 == 0 {
            return "\(contextWindow / 1_000_000)M"
        }
        if contextWindow >= 1_000_000 {
            let millions = Double(contextWindow) / 1_000_000
            return String(format: "%.2fM", millions)
        }
        return "\(contextWindow / 1_000)K"
    }
```

이제 `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`에서 Task 3에서 임시로 넣은 `Text("—")` 자리를 실제 감지값 표시로 교체:

```swift
                Text(CodexRoleRoutingOptions.contextWindowDisplay(role.wrappedValue.detectedContextWindow))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter CodexRoleRoutingOptionsTests`
Expected: PASS

Run: `swift build`
Expected: 컴파일 성공

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift
git commit -m "feat: show detected Codex context window as read-only label"
```

---

## Task 7: 번들 CLIProxyAPI를 7.2.97로 갱신

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi` (바이너리)
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`

**Interfaces:**
- Consumes: 없음(외부 릴리스 자산)
- Produces: 갱신된 바이너리와 manifest. 기존 `CLIProxyAPIBinaryManifest`/`ProxyServiceManager` 파싱 로직 변경 없음.

- [ ] **Step 1: 현재 상태 확인**

Run: `python3 -m json.tool Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
Expected: `"version": "7.2.91"` 확인

- [ ] **Step 2: 벤더링 스크립트 실행**

Run: `scripts/vendor-cliproxyapi.sh 7.2.97`
Expected: `Vendored CLIProxyAPI 7.2.97 to .../cliproxyapi`, `Wrote manifest to .../cliproxyapi.manifest.json` 출력. (이 스크립트는 `gh release download`를 사용하므로 `gh auth status`가 인증되어 있어야 한다. 인증이 안 되어 있으면 사용자에게 `gh auth login` 요청 후 재시도.)

- [ ] **Step 3: 결과 검증**

Run: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi --version 2>&1 | grep 'CLIProxyAPI Version: 7.2.97'`
Expected: 버전 문자열 출력

Run: `python3 -m json.tool Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
Expected: `"version": "7.2.97"`, `"upstreamTag": "v7.2.97"` 확인

- [ ] **Step 4: 관련 테스트 재실행**

Run: `swift test --filter ProxyServiceManagerTests`
Expected: PASS(번들 바이너리 버전 문자열에 의존하는 테스트 없음 — sandbox에 별도 fake manifest를 쓰므로 회귀 없음)

- [ ] **Step 5: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
git commit -m "chore: vendor CLIProxyAPI 7.2.97"
```

---

## Task 8: 전체 회귀 테스트 및 development app bundle 검증

**Files:**
- 없음(검증 전용 태스크)

**Interfaces:**
- Consumes: Task 1~7의 모든 변경사항
- Produces: 통과한 전체 테스트 스위트, 빌드된 development app bundle

- [ ] **Step 1: 전체 테스트 스위트 실행**

Run: `swift test`
Expected: 모든 테스트 PASS (실패 시 `superpowers:systematic-debugging`으로 원인 조사 후 해당 Task로 돌아가 수정)

- [ ] **Step 2: 구버전 설정 파일 디코드 검증**

Run: `swift test --filter AppConfigTests`
Expected: PASS — 특히 `testCodexRoleIgnoresLegacyContextWindowStringKey`, `testOAuthCommandProfilesDecodeAndEncodeRoundTrip` 통과 확인

- [ ] **Step 3: development app bundle 빌드**

Run: `make bundle`
Expected: `Bundled build/CLIProxyManager.app` 출력, 에러 없음

- [ ] **Step 4: 코드사인 검증**

Run: `make verify`
Expected: `codesign verification passed` 출력

- [ ] **Step 5: 실제 검증 안내(사용자 수행)**

다음 내용을 사용자에게 안내한다(자동화하지 않음, 프로젝트 규칙에 따라 development build까지만 자동 검증):

1. `open build/CLIProxyManager.app`로 앱 실행.
2. Codex 역할에 `gpt-5.6-sol`(372K) 등 확장 context 모델을 지정하고 저장 → 설정 화면 Context 열에 `372K`가 읽기 전용으로 표시되는지 확인.
3. 생성된 `functions.zsh`(또는 zshrc 소스 블록)에 `[1m]`과 `CLAUDE_CODE_AUTO_COMPACT_WINDOW='372000'`이 포함되는지 확인.
4. 역할을 `gpt-5.4-mini`(400K) 등 다른 확장 모델로 바꾼 뒤 값이 재계산되는지 확인.
5. 모든 역할을 200K 이하 모델로 바꾼 뒤 `[1m]`과 `AUTO_COMPACT_WINDOW` export가 사라지는지 확인.
6. round-robin Codex 프로필에서도 동일하게 반영되는지 확인.
7. 실제 Claude Code에서 해당 함수를 실행해 `/status`로 컨텍스트 사용률과 compact 시점을 확인.

- [ ] **Step 6: 최종 커밋(필요 시)**

이전 태스크에서 이미 각 단계별로 커밋했으므로, 이 단계는 누락된 변경이 있을 때만 수행:

```bash
git status --short
# 변경사항이 남아있다면
git add -A
git commit -m "chore: finalize Codex context window recognition"
```
