# Provider Routing and Model Capabilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude OAuth에만 Direct/CLIProxyAPI 선택을 제공하고, Claude/OpenAI API Key를 공식 upstream URL로 정상 등록하며, Codex 모델별 지원 reasoning만 선택할 수 있게 한다.

**Architecture:** `ProxyServiceManager`와 shell renderer에서 API Key provider 등록·preflight를 명시적으로 고정한다. `ProxyModelClient`는 일반 `/v1/models`와 Codex metadata 응답을 결합한 typed `CodexModelOption`을 반환하고, `DashboardViewModel`이 account/API Key/round-robin scope를 유지한 채 SwiftUI에 전달한다. SwiftUI의 routing field는 선택된 모델 capability로 reasoning picker와 모델 변경 정규화를 결정한다.

**Tech Stack:** Swift 6, SwiftUI, Foundation `URLSession`, Codable, XCTest, zsh shell functions, bundled CLIProxyAPI 7.2.66.

## Global Constraints

- macOS deployment target은 15.0, Swift tools version은 5.10을 유지한다.
- 기존 작업 트리의 API Key 파일 저장 변경을 되돌리거나 재작성하지 않는다.
- 연결 방식 선택지는 Claude OAuth에만 `CLIProxyAPI`와 `Direct`로 표시한다.
- Claude API Key와 OpenAI API Key는 항상 CLIProxyAPI를 사용한다.
- Claude API Key upstream은 정확히 `https://api.anthropic.com`, prefix는 `cpm-claude-api`다.
- OpenAI API Key upstream은 정확히 `https://api.openai.com/v1`, prefix는 `cpm-codex-api`다.
- custom base URL 및 OpenAI-compatible third-party provider 입력 UI는 추가하지 않는다.
- Claude API Key에는 모델 선택 UI를 추가하지 않는다.
- Codex OAuth와 OpenAI API Key 모두 해당 account/provider prefix의 모델 및 reasoning metadata를 사용한다.
- 신규 Codex OAuth와 OpenAI API Key의 기본 모델은 `gpt-5.6-terra`다; 기존 저장 모델은 자동 변경하지 않는다.
- Codex metadata에 없는 모델은 일반 모델 목록에서 제거하지 않고 capability unknown으로 유지한다.
- capability unknown 상태에서는 `auto`와 기존 저장 reasoning만 보존하며 새로운 값을 추측하지 않는다.
- `ultra`는 앱의 reasoning 선택지에 추가하지 않는다.
- 실제 generation 요청을 전송하지 않아 API 사용량과 과금을 발생시키지 않는다.
- 사용자 노출 문자열과 코드 주석은 기존 프로젝트의 영어 스타일을 따른다.

---

## File Structure

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`: `CodexReasoning.max`와 model identifier serialization을 소유한다.
- `Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift`: 모델 ID, supported reasoning, default reasoning을 표현하는 독립 typed value를 소유한다.
- `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`: 일반 모델 목록과 Codex client metadata를 조회·결합한다.
- `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`: 공식 API Key base URL과 prefix를 YAML에 생성한다.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`: API Key 전용 prefix 모델이 존재할 때만 command를 실행한다.
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`: typed model options를 global/account/API Key/round-robin scope로 제공한다.
- `Sources/CLIProxyManagerApp/Models/ModelSelectionOptions.swift`: 모델 picker의 legacy/current model 보존만 담당한다.
- `Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`: 모델별 reasoning 선택지와 모델 변경 정규화 규칙을 담당한다.
- `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`: typed options를 사용해 model/reasoning picker를 렌더한다.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`: OAuth/API Key settings sheet에 typed options를 전달하고 Claude connection UI를 분리한다.
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`, `ProviderListView.swift`, `RoundRobinSettingsView.swift`: typed options 전달 경로를 연결한다.
- `Sources/CLIProxyManagerApp/Views/AddProviderModal.swift`: Claude API Key가 Direct를 선택할 수 있다는 잘못된 문구를 제거한다.
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`: 공식 base URL YAML을 검증한다.
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`: 두 API Key command의 prefix preflight를 검증한다.
- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`: 신규 Terra 기본값, `max` encode/decode와 suffix를 검증한다.
- `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`: metadata parsing, fallback, ordering, scope를 검증한다.
- `Tests/CLIProxyManagerAppTests/ModelSelectionOptionsTests.swift`: model picker의 기존 보존 동작을 유지한다.
- `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`: reasoning capability와 정규화를 검증한다.
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`: account/API Key/round-robin scoped typed options를 검증한다.
- `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift`: API Key model normalization과 loading presentation 회귀를 유지한다.

### Task 1: API Key provider 등록과 shell preflight 수정

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift:517-562`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift:123-163`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift:24-99`
- Modify: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift:390-453`

**Interfaces:**
- Consumes: existing `ProxyServiceManager.config(for:)` and `ShellFunctionRenderer.renderClaudeAPIFunction()` / `renderCodexAPIFunction()`.
- Produces: YAML entries containing `base-url` and shell preflight checks containing the provider-specific prefix.
- No public Swift API signature changes.

- [ ] **Step 1: Add failing YAML assertions for both official base URLs**

Update `testStartAddsConfiguredAPIKeysWithFixedPrefixes()`:

```swift
func testStartAddsConfiguredAPIKeysWithOfficialBaseURLsAndFixedPrefixes() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary)
    let manager = ProxyServiceManager(
        paths: paths,
        launcher: FakeProcessLauncher(),
        claudeAPIKeyProvider: { "claude-key\"\nvalue" },
        codexAPIKeyProvider: { "codex-key" }
    )

    try await manager.start(port: 8317)

    let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
    XCTAssertTrue(config.contains("claude-api-key:"))
    XCTAssertTrue(config.contains("api-key: \"claude-key\\\"\\nvalue\""))
    XCTAssertTrue(config.contains("base-url: \"https://api.anthropic.com\""))
    XCTAssertTrue(config.contains("prefix: \"cpm-claude-api\""))
    XCTAssertTrue(config.contains("codex-api-key:"))
    XCTAssertTrue(config.contains("api-key: \"codex-key\""))
    XCTAssertTrue(config.contains("base-url: \"https://api.openai.com/v1\""))
    XCTAssertTrue(config.contains("prefix: \"cpm-codex-api\""))
}
```

Also strengthen `testStartWritesCompatibleConfigAndLaunchesBinaryWithConfigPath()`:

```swift
XCTAssertFalse(config.contains("https://api.anthropic.com"))
XCTAssertFalse(config.contains("https://api.openai.com/v1"))
```

- [ ] **Step 2: Run the focused YAML tests and verify failure**

Run:

```bash
swift test --filter ProxyServiceManagerTests/testStartAddsConfiguredAPIKeysWithOfficialBaseURLsAndFixedPrefixes
```

Expected: FAIL because neither provider block currently contains `base-url`.

- [ ] **Step 3: Add official base URLs to generated YAML**

In `ProxyServiceManager.config(for:)`, produce exactly:

```swift
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
if let key = nonEmpty(codexAPIKeyProvider()) {
    codexAPIConfiguration = """
    codex-api-key:
      - api-key: \(yamlDoubleQuoted(key))
        base-url: \(yamlDoubleQuoted("https://api.openai.com/v1"))
        prefix: \(yamlDoubleQuoted("cpm-codex-api"))
    """
} else {
    codexAPIConfiguration = ""
}
```

Do not add base URL fields to `AppConfig`.

- [ ] **Step 4: Add failing Codex API shell preflight assertions**

Extend `testCodexAPICommandUsesItsOwnRoutingAndSkipFlag()`:

```swift
XCTAssertTrue(function.contains("http://127.0.0.1:\(config.port)/v1/models"))
XCTAssertTrue(function.contains("grep -q 'cpm-codex-api/'"))
XCTAssertTrue(function.contains("OpenAI API key is not configured"))
```

Keep the existing Claude assertion:

```swift
XCTAssertTrue(function.contains("grep -q 'cpm-claude-api/'"))
```

- [ ] **Step 5: Run the focused renderer tests and verify failure**

Run:

```bash
swift test --filter ShellFunctionRendererTests/testCodexAPICommandUsesItsOwnRoutingAndSkipFlag
```

Expected: FAIL because the Codex API function currently discards the complete model response without checking `cpm-codex-api/`.

- [ ] **Step 6: Require provider-specific models in both API Key commands**

Make `renderCodexAPIFunction()` mirror Claude API preflight semantics:

```swift
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
  \(claudeCommand)
}
```

Do not change OAuth or round-robin preflight in this task.

- [ ] **Step 7: Run all focused provider registration tests**

Run:

```bash
swift test --filter ProxyServiceManagerTests && \
swift test --filter ShellFunctionRendererTests/testClaudeAPI && \
swift test --filter ShellFunctionRendererTests/testCodexAPI
```

Expected: PASS.

- [ ] **Step 8: Commit the provider registration fix**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift \
  Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "fix: register API key providers explicitly"
```

### Task 2: Typed Codex model capability 조회 추가

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:80-113`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift:1-108`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`

**Interfaces:**
- Produces: `public struct CodexModelOption: Equatable, Sendable`.
- Produces: `ProxyModelClient.codexModelOptions(port:) async throws -> [CodexModelOption]`.
- Produces: `ProxyModelClient.codexModelOptions(port:modelPrefix:) async throws -> [CodexModelOption]`.
- Preserves: existing `codexBaseModels` methods as wrappers returning `options.map(\.id)` so non-migrated callers and tests continue to compile during the task.

- [ ] **Step 1: Add failing Terra default and `max` serialization tests**

Add to `AppConfigTests`:

```swift
func testDefaultCodexRoutingUsesTerraWithRoleSpecificReasoning() {
    XCTAssertEqual(
        AppConfig.default.ccodex.opus,
        AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh, contextWindow: .auto)
    )
    XCTAssertEqual(
        AppConfig.default.ccodex.sonnet,
        AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .medium, contextWindow: .auto)
    )
    XCTAssertEqual(
        AppConfig.default.ccodex.haiku,
        AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .low, contextWindow: .auto)
    )
}

func testCodexReasoningMaxRendersAndRoundTrips() throws {
    let role = AppConfig.CodexRole(model: "gpt-5.6-sol", reasoning: .max, contextWindow: .auto)

    XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol(max)")

    let encoded = try JSONEncoder().encode(role)
    let decoded = try JSONDecoder().decode(AppConfig.CodexRole.self, from: encoded)
    XCTAssertEqual(decoded, role)
}
```

- [ ] **Step 2: Run the Terra default and `max` tests and verify failure**

Run:

```bash
swift test --filter AppConfigTests/testDefaultCodexRoutingUsesTerraWithRoleSpecificReasoning && \
swift test --filter AppConfigTests/testCodexReasoningMaxRendersAndRoundTrips
```

Expected: the default test fails with `gpt-5.5`, and the `max` test fails to compile because `CodexReasoning.max` does not exist.

- [ ] **Step 3: Set the new default to Terra and add `max` without changing existing `auto` semantics**

Update the default config:

```swift
ccodex: Codex(
    opus: CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh, contextWindow: .auto),
    sonnet: CodexRole(model: "gpt-5.6-terra", reasoning: .medium, contextWindow: .auto),
    haiku: CodexRole(model: "gpt-5.6-terra", reasoning: .low, contextWindow: .auto)
),
```

Update the enum and switch:

```swift
public enum CodexReasoning: String, Codable, CaseIterable, Sendable {
    case auto
    case low
    case medium
    case high
    case xhigh
    case max
}

public var modelIdentifier: String {
    switch reasoning {
    case .auto:
        model
    case .low, .medium, .high, .xhigh, .max:
        "\(model)(\(reasoning.rawValue))"
    }
}
```

- [ ] **Step 4: Add failing metadata parsing tests**

Add tests that return the regular endpoint first and metadata endpoint second through an ordered stub. Replace the existing `StubHTTPClient` storage with the following implementation so existing single-result tests still work and a missing second response becomes a metadata fallback failure:

```swift
private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var _requests: [(url: URL, headers: [String: String])] = []

    var requests: [(url: URL, headers: [String: String])] {
        lock.withLock { _requests }
    }

    init(result: Result<Data, Error>) {
        results = [result]
    }

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let result: Result<Data, Error> = lock.withLock {
            _requests.append((url, headers))
            guard !results.isEmpty else {
                return .failure(URLError(.badServerResponse))
            }
            return results.removeFirst()
        }
        return try result.get()
    }
}
```

Then add:

```swift
func testCodexModelOptionsCombineScopedModelsWithReasoningMetadata() async throws {
    let regular = Data(#"{"data":[{"id":"cpm-codex-api/gpt-5.6-sol","owned_by":"openai","created":300},{"id":"cpm-codex-api/gpt-5.5","owned_by":"openai","created":200}]}"#.utf8)
    let metadata = Data(#"{"models":[{"slug":"cpm-codex-api/gpt-5.6-sol","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},{"slug":"cpm-codex-api/gpt-5.5","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}]}"#.utf8)
    let httpClient = StubHTTPClient(results: [.success(regular), .success(metadata)])
    let client = ProxyModelClient(httpClient: httpClient)

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "cpm-codex-api")

    XCTAssertEqual(models, [
        CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low),
        CodexModelOption(id: "gpt-5.5", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
    ])
    XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [
        "http://127.0.0.1:18317/v1/models",
        "http://127.0.0.1:18317/v1/models?client_version=0.144.0"
    ])
}

func testCodexModelOptionsKeepRegularModelsWhenMetadataFails() async throws {
    let regular = Data(#"{"data":[{"id":"cpm-codex-api/custom-gpt","owned_by":"openai","created":300}]}"#.utf8)
    let httpClient = StubHTTPClient(results: [
        .success(regular),
        .failure(URLError(.cannotParseResponse))
    ])
    let client = ProxyModelClient(httpClient: httpClient)

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "cpm-codex-api")

    XCTAssertEqual(models, [CodexModelOption(id: "custom-gpt", supportedReasoning: [], defaultReasoning: nil)])
}

func testCodexModelOptionsIgnoreUnknownReasoningAndMetadataOnlyModels() async throws {
    let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.5","owned_by":"openai","created":300}]}"#.utf8)
    let metadata = Data(#"{"models":[{"slug":"codex-work/gpt-5.5","default_reasoning_level":"future","supported_reasoning_levels":[{"effort":"medium"},{"effort":"future"}]},{"slug":"codex-work/metadata-only","supported_reasoning_levels":[{"effort":"high"}]}]}"#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

    let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

    XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.5", supportedReasoning: [.medium], defaultReasoning: nil)])
}
```

- [ ] **Step 5: Run metadata tests and verify failure**

Run:

```bash
swift test --filter ProxyModelClientTests/testCodexModelOptions
```

Expected: compilation failure because `CodexModelOption` and `codexModelOptions` do not exist.

- [ ] **Step 6: Add the typed model value**

Create `CodexModelOption.swift`:

```swift
import Foundation

public struct CodexModelOption: Equatable, Sendable {
    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?

    public init(
        id: String,
        supportedReasoning: [AppConfig.CodexReasoning] = [],
        defaultReasoning: AppConfig.CodexReasoning? = nil
    ) {
        self.id = id
        self.supportedReasoning = supportedReasoning
        self.defaultReasoning = defaultReasoning
    }
}
```

- [ ] **Step 7: Implement dual-endpoint fetching and safe metadata fallback**

Refactor `ProxyModelClient` around these exact public methods:

```swift
public func codexModelOptions(port: Int) async throws -> [CodexModelOption] {
    try await codexModelOptions(port: port, modelPrefix: nil)
}

public func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
    let prefix = modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await codexModelOptions(port: port, modelPrefix: prefix.isEmpty ? nil : prefix)
}

public func codexBaseModels(port: Int) async throws -> [String] {
    try await codexModelOptions(port: port).map(\.id)
}

public func codexBaseModels(port: Int, modelPrefix: String) async throws -> [String] {
    try await codexModelOptions(port: port, modelPrefix: modelPrefix).map(\.id)
}
```

Use one regular request as the source of model membership/order, followed by a best-effort metadata request:

```swift
private func codexModelOptions(port: Int, modelPrefix: String?) async throws -> [CodexModelOption] {
    let regularModels = try await sortedModels(port: port)
    let scopedIDs = uniqueCodexModelIDs(from: regularModels, modelPrefix: modelPrefix)

    let metadataByID: [String: CodexClientModelsResponse.Model]
    do {
        metadataByID = try await codexMetadata(port: port, modelPrefix: modelPrefix)
    } catch {
        metadataByID = [:]
    }

    return scopedIDs.map { id in
        guard let metadata = metadataByID[id] else { return CodexModelOption(id: id) }
        let supported = metadata.supportedReasoningLevels.compactMap { level -> AppConfig.CodexReasoning? in
            guard let reasoning = AppConfig.CodexReasoning(rawValue: level.effort), reasoning != .auto else { return nil }
            return reasoning
        }.reduce(into: [AppConfig.CodexReasoning]()) { values, reasoning in
            if !values.contains(reasoning) { values.append(reasoning) }
        }
        let defaultReasoning = metadata.defaultReasoningLevel.flatMap(AppConfig.CodexReasoning.init(rawValue:))
        return CodexModelOption(
            id: id,
            supportedReasoning: supported,
            defaultReasoning: defaultReasoning.flatMap { supported.contains($0) ? $0 : nil }
        )
    }
}
```

Use the following helpers for membership, de-duplication, and metadata lookup. For global calls, keep routed IDs such as `codex-work/gpt-5.5`; for prefixed calls, strip only the exact requested prefix:

```swift
private func uniqueCodexModelIDs(
    from models: [ModelsResponse.Model],
    modelPrefix: String?
) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for model in models {
        let identifier: String
        if let modelPrefix {
            guard let unprefixed = modelIdentifier(model.id, withoutRoutingPrefix: modelPrefix),
                  isCodexModelID(unprefixed, ownedBy: model.ownedBy) else {
                continue
            }
            identifier = baseModelName(unprefixed)
        } else {
            guard isCodexModel(model) else { continue }
            identifier = baseModelName(model.id)
        }
        if seen.insert(identifier).inserted {
            result.append(identifier)
        }
    }
    return result
}

private func scopedModelID(_ identifier: String, modelPrefix: String?) -> String? {
    guard let modelPrefix else { return baseModelName(identifier) }
    guard let unprefixed = modelIdentifier(identifier, withoutRoutingPrefix: modelPrefix) else { return nil }
    return baseModelName(unprefixed)
}

private func codexMetadata(
    port: Int,
    modelPrefix: String?
) async throws -> [String: CodexClientModelsResponse.Model] {
    guard (1...65_535).contains(port) else {
        throw ProxyServiceError.invalidPort(port)
    }
    var components = URLComponents(string: "http://127.0.0.1:\(port)/v1/models")!
    components.queryItems = [URLQueryItem(name: "client_version", value: "0.144.0")]
    let data = try await httpClient.get(
        components.url!,
        headers: ["Authorization": "Bearer \(localAPIKey)"]
    )
    let response = try JSONDecoder().decode(CodexClientModelsResponse.self, from: data)
    var result: [String: CodexClientModelsResponse.Model] = [:]
    for model in response.models {
        guard let id = scopedModelID(model.slug, modelPrefix: modelPrefix) else { continue }
        if result[id] == nil {
            result[id] = model
        }
    }
    return result
}
```

Add response types:

```swift
private struct CodexClientModelsResponse: Decodable {
    var models: [Model]

    struct Model: Decodable {
        var slug: String
        var supportedReasoningLevels: [ReasoningLevel]
        var defaultReasoningLevel: String?
        var visibility: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case visibility
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try container.decode(String.self, forKey: .slug)
            supportedReasoningLevels = try container.decodeIfPresent([ReasoningLevel].self, forKey: .supportedReasoningLevels) ?? []
            defaultReasoningLevel = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel)
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        }
    }

    struct ReasoningLevel: Decodable {
        var effort: String
    }
}
```

The `codexMetadata` helper above uses `URLComponents`, so the exact query remains `client_version=0.144.0`. Do not filter on `visibility`: prefixed credentials may legitimately expose entries that the unprefixed Codex client template marks hidden. For global `codexModelOptions(port:)`, preserve existing routed IDs; for prefixed calls, strip only the exact requested route prefix.

- [ ] **Step 8: Run all Core model tests**

Run:

```bash
swift test --filter AppConfigTests/testDefaultCodexRoutingUsesTerraWithRoleSpecificReasoning && \
swift test --filter AppConfigTests/testCodexReasoningMaxRendersAndRoundTrips && \
swift test --filter ProxyModelClientTests
```

Expected: PASS, including existing ordering, owner filtering, namespaced ID, and invalid-port tests.

- [ ] **Step 9: Commit the typed capability client**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift \
  Sources/CLIProxyManagerCore/Proxy/CodexModelOption.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift \
  Tests/CLIProxyManagerCoreTests/AppConfigTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
git commit -m "feat: load Codex model capabilities"
```

### Task 3: DashboardViewModel의 scoped typed model flow로 전환

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:23-35,107-126,1429-1475`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:1332-1585,3096-3159`

**Interfaces:**
- Updates protocol: `ProxyModelListing.codexModelOptions(port:)` and `codexModelOptions(port:modelPrefix:)`.
- Produces: `@Published private(set) var availableCodexModelOptions: [CodexModelOption]`.
- Preserves convenience: `var availableCodexModels: [String] { availableCodexModelOptions.map(\.id) }`.
- Produces: `preferredCodexDefaultModel(in:) -> String?`, preferring exact `gpt-5.6-terra` and otherwise the first scoped option.
- Produces: `codexAPIModels()`, `codexModels(for:)`, and `codexModels(forRoundRobinProfile:)` returning `[CodexModelOption]`.

- [ ] **Step 1: Convert the model-client stub and add failing typed assertions**

Replace the protocol in `DashboardViewModel.swift`:

```swift
protocol ProxyModelListing: Sendable {
    func codexModelOptions(port: Int) async throws -> [CodexModelOption]
    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption]
}

extension ProxyModelListing {
    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
        try await codexModelOptions(port: port)
    }
}
```

Update the test stub shape before production implementation:

```swift
private final class StubProxyModelClient: ProxyModelListing, @unchecked Sendable {
    private let options: [CodexModelOption]
    private let optionsByPrefix: [String: [CodexModelOption]]
    // keep the existing lock and counters

    init(models: [String]) {
        options = models.map { CodexModelOption(id: $0) }
        optionsByPrefix = [:]
    }

    init(options: [CodexModelOption]) {
        self.options = options
        optionsByPrefix = [:]
    }

    init(modelsByPrefix: [String: [String]]) {
        options = []
        optionsByPrefix = modelsByPrefix.mapValues { $0.map { CodexModelOption(id: $0) } }
    }

    init(optionsByPrefix: [String: [CodexModelOption]]) {
        options = []
        self.optionsByPrefix = optionsByPrefix
    }

    func codexModelOptions(port: Int) async throws -> [CodexModelOption] {
        lock.withLock {
            _ports.append(port)
            _codexBaseModelsCallCount += 1
        }
        return options
    }

    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
        lock.withLock {
            _prefixRequests.append(PrefixModelRequest(port: port, prefix: modelPrefix))
            _codexBaseModelsCallCount += 1
        }
        return optionsByPrefix[modelPrefix] ?? options
    }
}
```

Update `testCodexAPIModelsUseFixedAPIKeyRoutingPrefix()` to assert capabilities survive:

```swift
let expected = [
    CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low)
]
let modelClient = StubProxyModelClient(optionsByPrefix: ["cpm-codex-api": expected])
let viewModel = DashboardViewModel(
    configStore: StubConfigStore(config: .default),
    shellInstaller: StubShellInstaller(),
    modelClient: modelClient,
    authProfileStore: StubAuthProfileStore(profiles: []),
    oauthLoginService: StubOAuthLoginService(),
    proxyService: StubProxyServiceStarter(),
    claudeConnector: connectedClaudeConnector(),
    secretStore: InMemorySecretStore()
)

let models = try await viewModel.codexAPIModels()

XCTAssertEqual(models, expected)
XCTAssertEqual(modelClient.prefixRequests.map(\.prefix), ["cpm-codex-api"])
```

- [ ] **Step 2: Add failing Terra default and round-robin capability tests**

Add the default-selection test:

```swift
func testPreferredCodexDefaultModelUsesTerraThenFirstScopedModel() {
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: .default),
        shellInstaller: StubShellInstaller(),
        modelClient: StubProxyModelClient(models: []),
        authProfileStore: StubAuthProfileStore(profiles: []),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    XCTAssertEqual(
        viewModel.preferredCodexDefaultModel(in: [
            CodexModelOption(id: "gpt-5.6-sol"),
            CodexModelOption(id: "gpt-5.6-terra"),
            CodexModelOption(id: "gpt-5.5")
        ]),
        "gpt-5.6-terra"
    )
    XCTAssertEqual(
        viewModel.preferredCodexDefaultModel(in: [CodexModelOption(id: "gpt-5.5")]),
        "gpt-5.5"
    )
}
```

Add the OAuth account capability test:

```swift
func testCodexModelsForProviderPreserveOAuthReasoningMetadata() async throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(id: "codex-work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work")
    ]
    let expected = [
        CodexModelOption(id: "gpt-5.6-terra", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .medium)
    ]
    let modelClient = StubProxyModelClient(optionsByPrefix: ["codex-work": expected])
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        modelClient: modelClient,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work")
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    XCTAssertEqual(try await viewModel.codexModels(for: .init(rawValue: "codex-work")), expected)
}
```

Then add the round-robin test:

```swift
func testRoundRobinCodexModelsIntersectModelsAndReasoningCapabilities() async throws {
    let modelClient = StubProxyModelClient(optionsByPrefix: [
        "codex-work": [
            CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low),
            CodexModelOption(id: "gpt-5.5", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
        ],
        "codex-personal": [
            CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
        ]
    ])
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(id: "work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work"),
        .init(id: "personal", provider: .codex, authProfileID: "personal.json", modelPrefix: "codex-personal")
    ]
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        modelClient: modelClient,
        authProfileStore: StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
            AuthProfile(fileName: "personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
        ]),
        oauthLoginService: StubOAuthLoginService(),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )
    let profile = AppConfig.RoundRobinProfile(
        id: "codex-round-robin",
        provider: .codex,
        includedAuthProfileIDs: ["work.json", "personal.json"]
    )

    let models = try await viewModel.codexModels(forRoundRobinProfile: profile)

    XCTAssertEqual(models, [
        CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
    ])
}
```

- [ ] **Step 3: Run the focused view-model tests and verify failure**

Run:

```bash
swift test --filter DashboardViewModelTests/testCodexAPIModelsUseFixedAPIKeyRoutingPrefix && \
swift test --filter DashboardViewModelTests/testPreferredCodexDefaultModelUsesTerraThenFirstScopedModel && \
swift test --filter DashboardViewModelTests/testCodexModelsForProviderPreserveOAuthReasoningMetadata && \
swift test --filter DashboardViewModelTests/testRoundRobinCodexModelsIntersectModelsAndReasoningCapabilities
```

Expected: compilation failures until production return types are converted.

- [ ] **Step 4: Publish typed options and preserve string convenience**

Replace the stored string array:

```swift
@Published private(set) var availableCodexModelOptions: [CodexModelOption] = []

var availableCodexModels: [String] {
    availableCodexModelOptions.map(\.id)
}

func preferredCodexDefaultModel(in options: [CodexModelOption]) -> String? {
    options.first(where: { $0.id == "gpt-5.6-terra" })?.id ?? options.first?.id
}

var latestBaseCodexModel: String? {
    preferredCodexDefaultModel(in: availableCodexModelOptions)
}
```

Update loading and failure:

```swift
func loadCodexModels() async {
    codexModelLoadingState = .loadingModels
    do {
        availableCodexModelOptions = try await modelClient.codexModelOptions(port: config.port)
        codexModelLoadingState = .idle
    } catch {
        handleCodexModelLoadingFailure(error)
    }
}

private func handleCodexModelLoadingFailure(_ error: Error? = nil) {
    availableCodexModelOptions = []
    let fallbackMessage = "Codex is connected, but the app could not load models through the local proxy server. Start the server and refresh, or keep the saved model."
    codexModelLoadingState = .failed(error?.localizedDescription ?? fallbackMessage)
}
```

- [ ] **Step 5: Return typed options for each scope**

```swift
func codexAPIModels() async throws -> [CodexModelOption] {
    try await modelClient.codexModelOptions(port: config.port, modelPrefix: "cpm-codex-api")
}

func codexModels(for provider: ProviderRowState.ID) async throws -> [CodexModelOption] {
    guard let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }) else {
        return availableCodexModelOptions
    }
    let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { return availableCodexModelOptions }
    return try await modelClient.codexModelOptions(port: config.port, modelPrefix: prefix)
}
```

For round robin, preserve the first account's model ordering and intersect capability levels:

```swift
func codexModels(forRoundRobinProfile profile: AppConfig.RoundRobinProfile) async throws -> [CodexModelOption] {
    let prefixes = roundRobinModelPrefixes(for: profile)
    guard let firstPrefix = prefixes.first else { return availableCodexModelOptions }
    var common = try await modelClient.codexModelOptions(port: config.port, modelPrefix: firstPrefix)

    for prefix in prefixes.dropFirst() {
        let next = try await modelClient.codexModelOptions(port: config.port, modelPrefix: prefix)
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        common = common.compactMap { current in
            guard let other = nextByID[current.id] else { return nil }
            let supported = current.supportedReasoning.filter(other.supportedReasoning.contains)
            let defaultReasoning: AppConfig.CodexReasoning?
            if let otherDefault = other.defaultReasoning, supported.contains(otherDefault) {
                defaultReasoning = otherDefault
            } else if let currentDefault = current.defaultReasoning, supported.contains(currentDefault) {
                defaultReasoning = currentDefault
            } else {
                defaultReasoning = nil
            }
            return CodexModelOption(id: current.id, supportedReasoning: supported, defaultReasoning: defaultReasoning)
        }
    }
    return common
}
```

- [ ] **Step 6: Run all DashboardViewModel model tests**

Run:

```bash
swift test --filter DashboardViewModelTests/testCodex && \
swift test --filter DashboardViewModelTests/testRoundRobinCodexModels && \
swift test --filter DashboardViewModelTests/testRefreshCodexModels
```

Expected: PASS.

- [ ] **Step 7: Commit the typed view-model flow**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "refactor: preserve Codex model capabilities"
```

### Task 4: 모델별 reasoning picker와 settings UI 연결

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift`
- Create: `Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift:13-64,188-224,504-884,888-1190`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:252-378`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderListView.swift:55-102`
- Modify: `Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift:41-240`
- Modify: `Sources/CLIProxyManagerApp/Views/AddProviderModal.swift:56-80`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift`

**Interfaces:**
- Produces: `CodexRoleRoutingOptions.modelIDs(currentModel:options:)`.
- Produces: `CodexRoleRoutingOptions.reasoningValues(currentReasoning:model:options:)`.
- Produces: `CodexRoleRoutingOptions.normalizedReasoning(currentReasoning:model:options:)`.
- Updates: `CodexRoleRoutingFields(..., availableModels: [CodexModelOption])`.
- Updates all Codex sheet refresh closures to `() async throws -> [CodexModelOption]`.

- [ ] **Step 1: Add failing pure reasoning-option tests**

Create `CodexRoleRoutingOptionsTests.swift`:

```swift
import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class CodexRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        CodexModelOption(id: "gpt-5.5", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium),
        CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low)
    ]

    func testReasoningValuesAlwaysStartWithAutoAndFollowModelCapabilityOrder() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(currentReasoning: .xhigh, model: "gpt-5.5", options: options),
            [.auto, .low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(currentReasoning: .max, model: "gpt-5.6-sol", options: options),
            [.auto, .low, .medium, .high, .xhigh, .max]
        )
    }

    func testUnknownCapabilityPreservesOnlyAutoAndCurrentStoredReasoning() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(currentReasoning: .xhigh, model: "custom-model", options: options),
            [.auto, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(currentReasoning: .auto, model: "custom-model", options: options),
            [.auto]
        )
    }

    func testModelChangeUsesSupportedDefaultThenAuto() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(currentReasoning: .max, model: "gpt-5.5", options: options),
            .medium
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(currentReasoning: .max, model: "custom-model", options: options),
            .max
        )
    }

    func testModelIDsPreserveLegacyCurrentModelWithoutAddingRoutedModel() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "legacy-model", options: options),
            ["legacy-model", "gpt-5.5", "gpt-5.6-sol"]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "codex-work/gpt-5.5", options: options),
            ["gpt-5.5", "gpt-5.6-sol"]
        )
    }
}
```

The unknown model normalization intentionally preserves the stored value until capability is known; model-change UI invokes normalization only for a selected known option.

- [ ] **Step 2: Run the pure tests and verify compilation failure**

Run:

```bash
swift test --filter CodexRoleRoutingOptionsTests
```

Expected: compilation failure because `CodexRoleRoutingOptions` does not exist.

- [ ] **Step 3: Implement the pure routing-option policy**

Create `CodexRoleRoutingOptions.swift`:

```swift
import CLIProxyManagerCore
import Foundation

enum CodexRoleRoutingOptions {
    static func modelIDs(currentModel: String, options: [CodexModelOption]) -> [String] {
        ModelSelectionOptions.options(currentModel: currentModel, availableModels: options.map(\.id))
    }

    static func reasoningValues(
        currentReasoning: AppConfig.CodexReasoning,
        model: String,
        options: [CodexModelOption]
    ) -> [AppConfig.CodexReasoning] {
        guard let option = options.first(where: { $0.id == model }) else {
            return currentReasoning == .auto ? [.auto] : [.auto, currentReasoning]
        }
        return [.auto] + option.supportedReasoning.filter { $0 != .auto }
    }

    static func normalizedReasoning(
        currentReasoning: AppConfig.CodexReasoning,
        model: String,
        options: [CodexModelOption]
    ) -> AppConfig.CodexReasoning {
        guard let option = options.first(where: { $0.id == model }) else { return currentReasoning }
        if currentReasoning == .auto || option.supportedReasoning.contains(currentReasoning) {
            return currentReasoning
        }
        if let defaultReasoning = option.defaultReasoning,
           option.supportedReasoning.contains(defaultReasoning) {
            return defaultReasoning
        }
        return .auto
    }
}
```

- [ ] **Step 4: Convert `CodexRoleRoutingFields` to typed options**

Change its property and picker bindings:

```swift
let availableModels: [CodexModelOption]
```

Add a model binding that normalizes reasoning atomically:

```swift
private func modelBinding(for role: Binding<AppConfig.CodexRole>) -> Binding<String> {
    Binding(
        get: { role.wrappedValue.model },
        set: { model in
            var updated = role.wrappedValue
            updated.model = model
            updated.reasoning = CodexRoleRoutingOptions.normalizedReasoning(
                currentReasoning: updated.reasoning,
                model: model,
                options: availableModels
            )
            role.wrappedValue = updated
        }
    )
}
```

Use it in the row:

```swift
Picker("", selection: modelBinding(for: role)) {
    ForEach(CodexRoleRoutingOptions.modelIDs(currentModel: role.wrappedValue.model, options: availableModels), id: \.self) { model in
        Text(model).tag(model)
    }
}

Picker("", selection: role.reasoning) {
    ForEach(
        CodexRoleRoutingOptions.reasoningValues(
            currentReasoning: role.wrappedValue.reasoning,
            model: role.wrappedValue.model,
            options: availableModels
        ),
        id: \.self
    ) { reasoning in
        Text(reasoning.rawValue).tag(reasoning)
    }
}
```

Keep context window choices unchanged.

- [ ] **Step 5: Convert provider sheets to typed options without global fallback leakage**

In `CodexProviderSettingsSheet` and `CodexAPIProviderSettingsSheet`:

```swift
@State private var scopedAvailableModels: [CodexModelOption]
let availableModels: [CodexModelOption]
let refreshModels: () async throws -> [CodexModelOption]
```

Pass an explicit preferred-model closure to both sheets:

```swift
let preferredModel: ([CodexModelOption]) -> String?
```

`DashboardView` and `ProviderListView` pass:

```swift
preferredModel: { viewModel.preferredCodexDefaultModel(in: $0) }
```

Use it only when a role model is blank or the provider is in initial setup:

```swift
private func applyDefaultModel(from models: [CodexModelOption]) {
    guard let defaultModel = preferredModel(models) else { return }
    if opus.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { opus.model = defaultModel }
    if sonnet.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sonnet.model = defaultModel }
    if haiku.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { haiku.model = defaultModel }
}

private func applyInitialDefaultsIfNeeded() {
    guard isInitialSetup, !didApplyInitialDefaults,
          let defaultModel = preferredModel(scopedAvailableModels) else { return }
    opus.model = defaultModel
    sonnet.model = defaultModel
    haiku.model = defaultModel
    didApplyInitialDefaults = true
}
```

This replaces the global `latestModel` closure, whose created-time tie currently selects Terra accidentally rather than by policy. Existing non-initial OAuth and configured API Key values remain untouched.

For API Key initial saved models, preserve normalized IDs as unknown-capability placeholders until refresh:

```swift
let normalizedModels = CodexAPIModelOptions.baseModels(
    from: [normalizedCodex.opus.model, normalizedCodex.sonnet.model, normalizedCodex.haiku.model]
).map { CodexModelOption(id: $0) }
```

In API Key reload, do not substitute OAuth/global options:

```swift
do {
    scopedAvailableModels = try await refreshModels()
    applyDefaultModel(from: scopedAvailableModels)
    if !isConfigured {
        applyInitialDefaultsIfNeeded()
    }
} catch {
    // Keep the current API-key-scoped options; OAuth/global models are not valid fallbacks.
}
```

For a new API Key, `applyInitialDefaultsIfNeeded()` selects `gpt-5.6-terra` from the `cpm-codex-api` scoped options. For an already configured API Key, the normalized saved role models remain unchanged. Keep `CodexAPIModelOptions.normalized(_:)` for legacy routed model strings saved before this change.

- [ ] **Step 6: Split Claude OAuth selection from fixed API Key presentation**

Replace `ClaudeConnectionModeSection.Presentation` with two focused views:

```swift
private struct ClaudeOAuthConnectionModeSection: View {
    @Binding var connectionMode: AppConfig.ConnectionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupTitle(text: "Connection")
            Picker("Connection", selection: $connectionMode) {
                Text("CLIProxyAPI").tag(AppConfig.ConnectionMode.proxy)
                Text("Direct").tag(AppConfig.ConnectionMode.direct)
            }
            .pickerStyle(.segmented)
            Text(connectionMode == .proxy
                 ? "Routes this registered OAuth account through CLIProxyAPI."
                 : "Runs Claude Code directly with its current official login.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct FixedCLIProxyAPIConnectionSection: View {
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupTitle(text: "Connection")
            GroupCard {
                CardRow(label: "CLIProxyAPI", description: description, isLast: true) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BrandPalette.statusRunning)
                }
            }
        }
    }
}
```

Use:

```swift
ClaudeOAuthConnectionModeSection(connectionMode: $connectionMode)
```

in the OAuth sheet and:

```swift
FixedCLIProxyAPIConnectionSection(
    description: "API key requests always route through CLIProxyAPI to keep them separate from the current OAuth subscription login."
)
```

in the Claude API Key sheet. OpenAI API Key may retain its existing fixed-routing explanatory text; do not add a picker.

- [ ] **Step 7: Update all typed option call sites**

Use `viewModel.availableCodexModelOptions` in `DashboardView` and `ProviderListView`:

```swift
availableModels: viewModel.availableCodexModelOptions
```

Keep refresh closures returning the typed scoped result:

```swift
refreshModels: {
    await viewModel.refreshCodexModels()
    return try await viewModel.codexModels(for: provider)
}
```

In `RoundRobinSettingsView`:

```swift
@State private var codexModels: [CodexModelOption] = []
```

and:

```swift
private struct CodexRoundRobinRoleFields: View {
    @Binding var profile: AppConfig.RoundRobinProfile
    let availableModels: [CodexModelOption]
    // pass directly to CodexRoleRoutingFields
}
```

- [ ] **Step 8: Correct Add Provider copy**

Replace the Claude API Key detail:

```swift
detail: provider == .claude
    ? "Save an Anthropic API key for use through CLIProxyAPI."
    : "Save an OpenAI API key for use through CLIProxyAPI."
```

No API Key connection choice should mention Direct.

- [ ] **Step 9: Update sheet helper tests for typed values**

In `ProviderSettingsSheetMetricsTests`, keep the normalization test and add a typed conversion assertion:

```swift
func testCodexAPIModelsNormalizePrefixesReasoningAndDuplicates() {
    let modelIDs = CodexAPIModelOptions.baseModels(from: [
        "cpm-codex-api/gpt-5.6(xhigh)",
        "codex-work/gpt-5.6",
        "openai/gpt-5.6-mini(low)",
        "gpt-5.6-mini"
    ])

    XCTAssertEqual(modelIDs, ["gpt-5.6", "gpt-5.6-mini"])
}
```

Do not move capability policy into `ProviderSettingsSheets.swift`; it belongs in `CodexRoleRoutingOptions`.

- [ ] **Step 10: Run all app model/settings tests**

Run:

```bash
swift test --filter CodexRoleRoutingOptionsTests && \
swift test --filter ModelSelectionOptionsTests && \
swift test --filter ProviderSettingsSheetMetricsTests && \
swift test --filter ProviderSettingsViewModelTests && \
swift test --filter DashboardViewModelTests
```

Expected: PASS.

- [ ] **Step 11: Commit the capability-aware UI**

```bash
git add Sources/CLIProxyManagerApp/Models/CodexRoleRoutingOptions.swift \
  Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift \
  Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/ProviderListView.swift \
  Sources/CLIProxyManagerApp/Views/RoundRobinSettingsView.swift \
  Sources/CLIProxyManagerApp/Views/AddProviderModal.swift \
  Tests/CLIProxyManagerAppTests/CodexRoleRoutingOptionsTests.swift \
  Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift
git commit -m "feat: constrain Codex reasoning by model"
```

### Task 5: 전체 회귀 및 개발 빌드 런타임 검증

**Files:**
- Modify only if verification exposes a defect in files already listed above.
- Verify: `docs/superpowers/specs/2026-07-12-provider-routing-and-model-capabilities-design.md`
- Verify runtime files under `~/.cliproxy-manager/dev/` without committing them.

**Interfaces:**
- Consumes all prior task outputs.
- Produces no new public API.
- Runtime verification must not send generation requests.

- [ ] **Step 1: Run the complete Swift test suite**

Run:

```bash
swift test
```

Expected: all `CLIProxyManagerCoreTests` and `CLIProxyManagerAppTests` pass with zero failures.

- [ ] **Step 2: Build a development app bundle**

Run:

```bash
BUILD_DIR="${CLAUDE_JOB_DIR:-/tmp}/cliproxy-manager-provider-routing" \
make bundle CONFIGURATION=debug BUILD_DIR="${CLAUDE_JOB_DIR:-/tmp}/cliproxy-manager-provider-routing"
```

Expected:

- command exits 0;
- `CLIProxyManager.app/Contents/MacOS/CLIProxyManager` exists and is executable;
- `CLIProxyManager.app/Contents/Helpers/cliproxy-manager` exists and is executable;
- bundled `cliproxyapi` exists.

- [ ] **Step 3: Back up files that a development app launch can rewrite**

Use one deterministic backup location so the restore command is exact:

```bash
backup_dir="/tmp/cpm-provider-routing-backup-$USER"
rm -rf "$backup_dir"
mkdir -m 700 "$backup_dir"
for file in "$HOME/.cliproxy-manager/dev/functions.zsh" "$HOME/.zshrc"; do
  if [[ -e "$file" ]]; then
    cp -p "$file" "$backup_dir/$(basename "$file")"
  fi
done
```

Expected: the directory exists with mode `0700` and contains copies of every pre-existing file from the loop.

- [ ] **Step 4: Launch the development app and wait for port 18318**

Run the built development app from the bundle, then wait without sending a generation request:

```bash
open -n "${CLAUDE_JOB_DIR:-/tmp}/cliproxy-manager-provider-routing/CLIProxyManager.app"
for _ in {1..80}; do
  curl -fsS -H 'Authorization: Bearer sk-dummy' \
    'http://127.0.0.1:18318/v1/models' \
    -o /tmp/cpm-provider-routing-models.json && break
  sleep 0.25
done
test -s /tmp/cpm-provider-routing-models.json
```

Expected: the model response file is created.

- [ ] **Step 5: Verify API Key providers and OAuth/API Key scoped models**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
models = json.load(open('/tmp/cpm-provider-routing-models.json')).get('data', [])
ids = [item.get('id', '') for item in models]
claude = [model for model in ids if model.startswith('cpm-claude-api/')]
codex = [model for model in ids if model.startswith('cpm-codex-api/')]
oauth_prefixes = sorted({model.split('/', 1)[0] for model in ids
                         if model.startswith('codex-') and '/' in model and not model.startswith('cpm-codex-api/')})
print('claude_api_models=', len(claude))
print('codex_api_models=', len(codex))
print('codex_oauth_prefixes=', oauth_prefixes)
assert claude, 'missing cpm-claude-api models'
assert codex, 'missing cpm-codex-api models'
assert oauth_prefixes, 'missing Codex OAuth scoped models'
for prefix in oauth_prefixes:
    assert f'{prefix}/gpt-5.6-terra' in ids

log = Path.home()/'.cliproxy-manager/dev/auth/logs/main.log'
recent = '\n'.join(log.read_text(errors='replace').splitlines()[-200:])
assert '1 Claude API keys' in recent
assert '1 Codex keys' in recent
print('provider registration verified')
PY
```

Expected: both API Key counts are greater than zero, at least one Codex OAuth prefix exists, every detected OAuth prefix exposes `gpt-5.6-terra`, and provider registration is verified.

If the user's development secret files are not configured, do not create billable credentials. Instead, repeat the previously proven isolated YAML test using the existing configured development keys only when they are already present; otherwise report runtime provider verification as skipped and retain the unit-test evidence.

- [ ] **Step 6: Verify model-specific metadata without generation**

Run:

```bash
curl -fsS -H 'Authorization: Bearer sk-dummy' \
  'http://127.0.0.1:18318/v1/models?client_version=0.144.0' \
  -o /tmp/cpm-provider-routing-codex-models.json
python3 - <<'PY'
import json
models = json.load(open('/tmp/cpm-provider-routing-codex-models.json')).get('models', [])
scoped = {m.get('slug'): [r.get('effort') for r in m.get('supported_reasoning_levels', [])]
          for m in models}
api_prefix = 'cpm-codex-api'
oauth_prefixes = sorted({slug.split('/', 1)[0] for slug in scoped
                         if slug.startswith('codex-') and '/' in slug and not slug.startswith(api_prefix + '/')})
print('api=', {k: v for k, v in scoped.items() if k.startswith(api_prefix + '/')})
print('oauth_prefixes=', oauth_prefixes)
assert 'max' not in scoped[f'{api_prefix}/gpt-5.5']
assert 'max' in scoped[f'{api_prefix}/gpt-5.6-terra']
for prefix in oauth_prefixes:
    assert 'max' not in scoped[f'{prefix}/gpt-5.5']
    assert 'max' in scoped[f'{prefix}/gpt-5.6-terra']
PY
```

Expected: OpenAI API Key와 각 Codex OAuth account에서 GPT-5.5는 `xhigh`까지만 제공하고 GPT-5.6 Terra는 `max`를 포함한다.

- [ ] **Step 7: Quit the development app and restore rewritten files**

Quit only the development app instance and restore the deterministic backup from Step 3:

```bash
pkill -f '/cliproxy-manager-provider-routing/CLIProxyManager.app/Contents/MacOS/CLIProxyManager' || true
backup_dir="/tmp/cpm-provider-routing-backup-$USER"
if [[ -f "$backup_dir/functions.zsh" ]]; then
  cp -p "$backup_dir/functions.zsh" "$HOME/.cliproxy-manager/dev/functions.zsh"
fi
if [[ -f "$backup_dir/.zshrc" ]]; then
  cp -p "$backup_dir/.zshrc" "$HOME/.zshrc"
fi
rm -rf "$backup_dir"
```

Expected: the development process exits and the original files are restored byte-for-byte.

- [ ] **Step 8: Confirm working-tree scope and final diff**

Run:

```bash
git status --short
git diff --check
git diff --stat 20dc8ac..HEAD
```

Expected:

- no whitespace errors;
- only files required by this plan plus the already-existing API Key file-store work are modified;
- no runtime files under `~/.cliproxy-manager` are tracked.

- [ ] **Step 9: Run final tests after runtime restoration**

Run:

```bash
swift test
```

Expected: all tests pass again after runtime verification.

- [ ] **Step 10: Commit a verification correction only when the final diff contains one**

First inspect the exact changed paths:

```bash
git diff --name-only 20dc8ac..HEAD
git status --short
```

If runtime verification required a correction, stage only the concrete regression test and source path shown by those commands, then commit:

```bash
git add Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift
git commit -m "fix: complete provider routing verification"
```

The command above is the expected correction pair for a provider-registration regression. If a different previously listed component required correction, substitute only that component's already-listed test/source pair. If no source correction was required, do not create an empty commit. Do not amend the design document commit `20dc8ac`.
