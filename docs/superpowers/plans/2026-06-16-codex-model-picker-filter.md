# Codex Model Picker Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the CLIProxyManager Codex OAuth settings sheet only shows Codex/OpenAI models in its GPT model pickers, even when the local CLIProxyAPI `/v1/models` response includes Claude models from the same auth directory.

**Architecture:** Add a Codex-specific model listing path in `ProxyModelClient` that filters the merged `/v1/models` response by provider metadata (`owned_by == "openai"`) and safe Codex/OpenAI ID prefixes when metadata is absent. Wire `DashboardViewModel.loadCodexModels()` to this Codex-specific method, leaving the existing generic `models`/`baseModels` behavior unchanged.

**Tech Stack:** Swift, SwiftUI, XCTest, existing `HTTPClient` abstraction and `DashboardViewModel` dependency injection.

---

## File Structure

- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`
  - Decode `owned_by` from `/v1/models` responses.
  - Add `codexBaseModels(port:)` for Codex/OpenAI-only base model names.
  - Keep existing `models(port:)` and `baseModels(port:)` public behavior intact.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Extend `ProxyModelListing` with `codexBaseModels(port:)`.
  - Use `codexBaseModels(port:)` in `loadCodexModels()`.
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`
  - Add regression coverage for filtering Claude/Gemini out of Codex model lists.
  - Add coverage that `models(port:)` still returns the unfiltered merged list.
- Modify if required by compile errors: test stubs in `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - Update any `ProxyModelListing` stub to implement `codexBaseModels(port:)`.

---

### Task 1: Add Codex-specific model filtering in the core client

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`

- [ ] **Step 1: Write the failing filtering test**

Add this test to `ProxyModelClientTests` after `testModelsReturnsUniqueBaseModelNames()`:

```swift
func testCodexBaseModelsFiltersMergedProviderModelList() async throws {
    let data = Data(
        #"""
        {
          "data": [
            {"id":"claude-sonnet-4-6","owned_by":"anthropic","created":300},
            {"id":"gpt-5.5(xhigh)","owned_by":"openai","created":500},
            {"id":"gemini-2.5-pro","owned_by":"google","created":400},
            {"id":"codex-auto-review","created":200},
            {"id":"gpt-5.5(medium)","owned_by":"openai","created":100}
          ]
        }
        """#.utf8
    )
    let httpClient = StubHTTPClient(result: .success(data))
    let client = ProxyModelClient(httpClient: httpClient)

    let models = try await client.codexBaseModels(port: 18_317)

    XCTAssertEqual(models, ["gpt-5.5", "codex-auto-review"])
}
```

- [ ] **Step 2: Write the generic-list regression test**

Add this test to the same file to prove the existing generic behavior remains merged/unfiltered:

```swift
func testModelsKeepsMergedProviderModelList() async throws {
    let data = Data(
        #"""
        {
          "data": [
            {"id":"claude-sonnet-4-6","owned_by":"anthropic","created":300},
            {"id":"gpt-5.5","owned_by":"openai","created":500}
          ]
        }
        """#.utf8
    )
    let httpClient = StubHTTPClient(result: .success(data))
    let client = ProxyModelClient(httpClient: httpClient)

    let models = try await client.models(port: 18_317)

    XCTAssertEqual(models, ["gpt-5.5", "claude-sonnet-4-6"])
}
```

- [ ] **Step 3: Run the focused failing tests**

Run:

```bash
cd /Users/classting/Documents/dev/CLIProxyManager
swift test --filter ProxyModelClientTests
```

Expected: FAIL because `ProxyModelClient` does not yet define `codexBaseModels(port:)`.

- [ ] **Step 4: Implement the minimal core client change**

Replace `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift` with this shape, preserving imports and existing API:

```swift
import Foundation

public struct ProxyModelClient: Sendable {
    private let httpClient: any HTTPClient
    private let localAPIKey: String

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), localAPIKey: String = "sk-dummy") {
        self.httpClient = httpClient
        self.localAPIKey = localAPIKey
    }

    public func models(port: Int) async throws -> [String] {
        try await sortedModels(port: port).map(\.id)
    }

    public func baseModels(port: Int) async throws -> [String] {
        uniqueBaseModels(from: try await models(port: port))
    }

    public func codexBaseModels(port: Int) async throws -> [String] {
        let models = try await sortedModels(port: port)
            .filter(isCodexModel)
            .map(\.id)
        return uniqueBaseModels(from: models)
    }

    private func sortedModels(port: Int) async throws -> [ModelsResponse.Model] {
        guard (1...65_535).contains(port) else {
            throw ProxyServiceError.invalidPort(port)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let data = try await httpClient.get(url, headers: ["Authorization": "Bearer \(localAPIKey)"])
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // Sort by `created` descending so callers naturally see newest first.
        return response.data.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
    }

    private func uniqueBaseModels(from identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for model in identifiers.map(baseModelName) {
            if seen.insert(model).inserted {
                result.append(model)
            }
        }

        return result
    }

    private func baseModelName(_ identifier: String) -> String {
        guard let parenIndex = identifier.firstIndex(of: "(") else { return identifier }
        return String(identifier[..<parenIndex])
    }

    private func isCodexModel(_ model: ModelsResponse.Model) -> Bool {
        if model.ownedBy?.lowercased() == "openai" {
            return true
        }

        let id = model.id.lowercased()
        return id.hasPrefix("gpt-")
            || id.hasPrefix("codex-")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}

private struct ModelsResponse: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
        var created: Int64?
        var ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case created
            case ownedBy = "owned_by"
        }
    }
}
```

- [ ] **Step 5: Run the focused core tests**

Run:

```bash
cd /Users/classting/Documents/dev/CLIProxyManager
swift test --filter ProxyModelClientTests
```

Expected: PASS.

---

### Task 2: Wire the Codex settings screen to the filtered model list

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify if needed: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Update the app protocol**

In `DashboardViewModel.swift`, change the protocol near the top from:

```swift
protocol ProxyModelListing: Sendable {
    func baseModels(port: Int) async throws -> [String]
}
```

to:

```swift
protocol ProxyModelListing: Sendable {
    func baseModels(port: Int) async throws -> [String]
    func codexBaseModels(port: Int) async throws -> [String]
}
```

- [ ] **Step 2: Use Codex-filtered models in `loadCodexModels()`**

Change:

```swift
availableCodexModels = try await modelClient.baseModels(port: config.port)
```

to:

```swift
availableCodexModels = try await modelClient.codexBaseModels(port: config.port)
```

- [ ] **Step 3: Fix app test stubs if compilation requires it**

If any test stub conforming to `ProxyModelListing` fails to compile, update it from this kind of shape:

```swift
func baseModels(port: Int) async throws -> [String] {
    models
}
```

to:

```swift
func baseModels(port: Int) async throws -> [String] {
    models
}

func codexBaseModels(port: Int) async throws -> [String] {
    models
}
```

- [ ] **Step 4: Add or update a ViewModel test if an existing model-loading stub is present**

If `DashboardViewModelTests.swift` already has a model-loading test/stub, add this assertion pattern to verify the ViewModel uses the Codex-specific method rather than generic `baseModels`:

```swift
XCTAssertEqual(modelClient.codexBaseModelsCallCount, 1)
XCTAssertEqual(modelClient.baseModelsCallCount, 0)
```

If no such stub exists, skip adding a new ViewModel test; the core filtering test covers the bug and the compiler enforces the protocol wiring.

- [ ] **Step 5: Run focused app tests**

Run:

```bash
cd /Users/classting/Documents/dev/CLIProxyManager
swift test --filter DashboardViewModel
swift test --filter ModelSelectionOptionsTests
```

Expected: PASS.

---

### Task 3: Verify the full change

**Files:**
- No additional source files.

- [ ] **Step 1: Run all tests**

Run:

```bash
cd /Users/classting/Documents/dev/CLIProxyManager
swift test
```

Expected: PASS.

- [ ] **Step 2: Review the diff for scope**

Run:

```bash
cd /Users/classting/Documents/dev/CLIProxyManager
git diff -- Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
```

Expected: the diff only adds Codex/OpenAI filtering for the Codex settings model list and does not alter CLIProxyAPI binaries, CLIProxyManager runtime auth files, or unrelated UI.

- [ ] **Step 3: Do not commit unless requested**

The repository is on `main`; commit only if the user explicitly asks. Leave existing untracked files untouched.

---

## Self-Review

- Spec coverage: The plan filters the Codex settings model picker by changing the model source used by `DashboardViewModel.loadCodexModels()` and adding core regression tests.
- Placeholder scan: No TBD/TODO placeholders remain. The only conditional step is limited to compile-required test stub updates because the exact stub location is test-suite dependent.
- Type consistency: `ProxyModelListing.codexBaseModels(port:)` matches `ProxyModelClient.codexBaseModels(port:)`; `ModelsResponse.Model.ownedBy` decodes `owned_by`.
