# Claude OAuth Dynamic Models and Stale Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude OAuth proxy commands resolve account-scoped Opus, Sonnet, and Haiku models at command execution time, while subscription usage refresh failures retain and display the last successful snapshot with a warning-only stale state.

**Architecture:** Store Claude routing as an Automatic-or-explicit policy in `AppConfig`, discover models through the existing local `/v1/models` client, and make one pure `ClaudeModelResolver` the source of truth for settings previews, individual commands, and round robin. Separately, add `.stale(snapshot, issue)` to the usage state machine so `DashboardViewModel` can preserve successful data and cache entries while polling and presentation respond to the current issue.

**Tech Stack:** Swift 5.10 package, Swift 6 language mode where enabled by SwiftPM, SwiftUI, XCTest, macOS 15.0, CLIProxyAPI local HTTP model listing, Codable JSON configuration.

## Global Constraints

- Preserve every pre-existing modified and untracked file in this worktree; never reset, restore, checkout, stash, or overwrite unrelated changes.
- Several target files already contain uncommitted provider-routing work. Read the current file before each edit and apply only the new feature’s smallest exact replacement.
- Before and after every task, run `git diff --check` and inspect `git diff -- <task-files>`; never use broad `git add .` or `git add -A`.
- Do not create implementation commits unless the user explicitly authorizes commits. The commit commands below define review boundaries; when authorization is absent, stop after verifying the task and leave its changes unstaged.
- If commits are authorized while overlapping baseline changes remain uncommitted, stage with `git add -p` and verify `git diff --cached`; do not create a commit whose staged tree depends on unstaged baseline code.
- Keep `swift-tools-version` at `5.10`, the deployment floor at macOS `15.0`, and Sparkle at exact version `2.9.2`.
- Add no dependency and do not change CLIProxyAPI’s registry, OAuth refresh behavior, Codex routing, or Claude API Key model UI.
- Store only unprefixed Claude base model IDs. Apply the account prefix only when producing runtime environment assignments.
- `Automatic` resolves on every command invocation from that account’s current scoped `/v1/models` entries; do not replace it with a model ID at save time.
- Direct mode must not query the proxy and must remove `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, and all three `ANTHROPIC_DEFAULT_*_MODEL` variables.
- Keep `OAuthModelDefaults` constants only for scoped compatibility checks; do not update them to newer release IDs.
- Keep the usage cache schema exactly `[String: SubscriptionUsageSnapshot]`. Persist snapshots, not issues.
- A refresh issue never deletes a prior successful snapshot. `SubscriptionUsageIssue.stopsPolling` controls only automatic polling eligibility.
- Menu bar and overlay stale states keep the existing graph and percentage. Show one trailing `exclamationmark.triangle.fill` icon with `BrandPalette.statusWarning`, tooltip, and complete accessibility text.
- Runtime verification may call `/v1/models` and usage endpoints but must not send any billable Claude or Codex generation request.
- Development app verification uses `CONFIGURATION=debug` and `BUILD_DIR=build-development`.

---

## File Structure

### New core files

- `Sources/CLIProxyManagerCore/Proxy/ClaudeModelOption.swift` — account-scoped Claude model metadata, family classification, and the model-listing protocol used by runtime and app test doubles.
- `Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift` — Codable routing policy, deterministic resolver, actionable resolution errors, and shell assignment formatting.
- `Tests/CLIProxyManagerCoreTests/ClaudeModelResolverTests.swift` — resolver ordering, manual validation, fallback, and quoting tests.

### New app files

- `Sources/CLIProxyManagerApp/Models/ClaudeRoleRoutingOptions.swift` — pure picker row construction that reuses the core resolver and preserves unavailable saved selections.
- `Sources/CLIProxyManagerApp/Views/ClaudeRoleRoutingFields.swift` — the three role pickers and their shared loading/error presentation.
- `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift` — pure usage display mapping, warning text formatting, and the shared SwiftUI warning icon.
- `Tests/CLIProxyManagerAppTests/ClaudeRoleRoutingOptionsTests.swift` — Automatic preview, family filtering, unavailable-value preservation, and Direct visibility rules.
- `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift` — stale display mapping and deterministic tooltip/accessibility copy.

### Modified core files

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift` — optional Claude routing on OAuth command profiles and backward-compatible effective defaults.
- `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift` — exact-prefix Claude option discovery with `created` metadata.
- `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift` — `routing claude-models`, legacy validation, async round-robin dispatch, and stale quota output.
- `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift` — resolve Claude models for the account already selected by round robin.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift` — runtime helper invocation for Claude proxy functions and complete Direct environment cleanup.
- `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift` — `.stale(snapshot, issue)` plus shared snapshot/issue projections.

### Modified app files

- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` — scoped Claude model loading/saving and stale-while-error usage transitions, caching, and polling.
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift` — Claude routing state, proxy-only Models section, Direct explanation, refresh lifecycle, and save integration.
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift` — provide scoped model loader and save the routing policy.
- `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift` — render stale snapshots through the shared display mapping with one warning icon.
- `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — use the same stale presentation and warning icon.

### Modified tests

- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`
- `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
- `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

---

### Task 1: Persist Claude Routing Policy Without Breaking Existing Configs

**Files:**
- Create: `Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift`
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:152-210`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

**Interfaces:**
- Produces: `ClaudeModelSelection`, `ClaudeRouting`, `ClaudeRouting.automatic`, and `AppConfig.OAuthCommandProfile.effectiveClaudeRouting`.
- Consumes: the existing `AppConfig.OAuthCommandProfile` Codable implementation.

- [ ] **Step 1: Add failing Codable and compatibility tests**

Append tests that establish the persisted string form, empty-value normalization, missing-field behavior, and Direct preservation:

```swift
func testClaudeModelSelectionUsesStringRepresentationAndNormalizesBlankValues() throws {
    let automatic = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""automatic""#.utf8))
    let blank = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""   ""#.utf8))
    let explicit = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""claude-opus-4-8""#.utf8))

    XCTAssertEqual(automatic, .automatic)
    XCTAssertEqual(blank, .automatic)
    XCTAssertEqual(explicit, .model("claude-opus-4-8"))
    XCTAssertEqual(String(decoding: try JSONEncoder().encode(automatic), as: UTF8.self), #""automatic""#)
    XCTAssertEqual(String(decoding: try JSONEncoder().encode(explicit), as: UTF8.self), #""claude-opus-4-8""#)
}

func testLegacyClaudeOAuthProfileUsesAutomaticEffectiveRoutingWithoutForcingStoredField() throws {
    let data = Data(#"""
    {
      "id": "claude-work",
      "provider": "claude",
      "authProfileID": "claude-work.json",
      "commandName": "ccwork",
      "connectionMode": "proxy"
    }
    """#.utf8)

    let profile = try JSONDecoder().decode(AppConfig.OAuthCommandProfile.self, from: data)

    XCTAssertNil(profile.claude)
    XCTAssertEqual(profile.effectiveClaudeRouting, .automatic)
}

func testClaudeRoutingRoundTripsAndSurvivesDirectMode() throws {
    let routing = ClaudeRouting(
        opus: .model("claude-opus-4-8"),
        sonnet: .automatic,
        haiku: .model("claude-haiku-4-5")
    )
    let profile = AppConfig.OAuthCommandProfile(
        id: "claude-work",
        provider: .claude,
        authProfileID: "claude-work.json",
        commandName: "ccwork",
        claude: routing,
        modelPrefix: "claude-work",
        connectionMode: .direct
    )

    let decoded = try JSONDecoder().decode(
        AppConfig.OAuthCommandProfile.self,
        from: JSONEncoder().encode(profile)
    )

    XCTAssertEqual(decoded.claude, routing)
    XCTAssertEqual(decoded.effectiveClaudeRouting, routing)
    XCTAssertEqual(decoded.connectionMode, .direct)
}
```

- [ ] **Step 2: Run the focused tests and verify the expected compile failure**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: FAIL because `ClaudeModelSelection`, `ClaudeRouting`, `claude`, and `effectiveClaudeRouting` do not exist.

- [ ] **Step 3: Implement the routing policy types**

Create `ClaudeModelRouting.swift` with the persisted string contract:

```swift
import Foundation

public enum ClaudeModelSelection: Codable, Equatable, Hashable, Sendable {
    case automatic
    case model(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self = value.isEmpty || value.caseInsensitiveCompare("automatic") == .orderedSame
            ? .automatic
            : .model(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic:
            try container.encode("automatic")
        case .model(let model):
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            try container.encode(trimmed.isEmpty ? "automatic" : trimmed)
        }
    }
}

public struct ClaudeRouting: Codable, Equatable, Sendable {
    public var opus: ClaudeModelSelection
    public var sonnet: ClaudeModelSelection
    public var haiku: ClaudeModelSelection

    public init(
        opus: ClaudeModelSelection,
        sonnet: ClaudeModelSelection,
        haiku: ClaudeModelSelection
    ) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
    }

    public static let automatic = ClaudeRouting(
        opus: .automatic,
        sonnet: .automatic,
        haiku: .automatic
    )
}
```

- [ ] **Step 4: Add the optional config field and effective default**

Update `OAuthCommandProfile` without mutating legacy files merely by decoding them:

```swift
public var dangerousPermissionsEnabled: Bool
public var claude: ClaudeRouting?
public var codex: Codex?
public var modelPrefix: String
```

Add `claude: ClaudeRouting? = nil` immediately before `codex` in the initializer, assign it, and include it in CodingKeys and decoding:

```swift
self.claude = claude
self.codex = codex
```

```swift
case dangerousPermissionsEnabled, claude, codex, modelPrefix, connectionMode, isEnabled
```

```swift
self.claude = try container.decodeIfPresent(ClaudeRouting.self, forKey: .claude)
self.codex = try container.decodeIfPresent(Codex.self, forKey: .codex)
```

Add the computed policy used by later tasks:

```swift
public var effectiveClaudeRouting: ClaudeRouting {
    provider == .claude ? (claude ?? .automatic) : .automatic
}
```

- [ ] **Step 5: Verify focused and related config tests**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter AppConfigStoreTests
```

Expected: PASS. Existing Codex profile encoding and connection-mode defaults remain unchanged.

- [ ] **Step 6: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift Sources/CLIProxyManagerCore/Config/AppConfig.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
```

If implementation commits are explicitly authorized and the staged tree is self-contained:

```bash
git add Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift
git add -p Sources/CLIProxyManagerCore/Config/AppConfig.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git diff --cached --check
git commit -m "feat: persist Claude OAuth model routing policy"
```

---

### Task 2: Discover Exact Account-Scoped Claude Models

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/ClaudeModelOption.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift:3-177`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift`

**Interfaces:**
- Produces: `ClaudeModelFamily`, `ClaudeModelOption`, `ClaudeModelListing`, and `ProxyModelClient.claudeModelOptions(port:modelPrefix:)`.
- Consumes: `ModelsResponse.Model`, existing port validation, and authenticated `GET /v1/models`.

- [ ] **Step 1: Add failing account-scope tests**

Add these cases to `ProxyModelClientTests`:

```swift
func testClaudeModelOptionsKeepOnlyExactAccountPrefixAndMetadata() async throws {
    let data = Data(#"""
    {"data":[
      {"id":"claude-work/claude-opus-4-8","owned_by":"anthropic","created":500},
      {"id":"claude-work/claude-sonnet-5","owned_by":"anthropic","created":400},
      {"id":"claude-work/claude-haiku-4-5","owned_by":"anthropic","created":300},
      {"id":"claude-work/claude-custom-preview","owned_by":"anthropic","created":200},
      {"id":"claude-worker/claude-opus-4-8","owned_by":"anthropic","created":600},
      {"id":"claude-personal/claude-opus-4-7","owned_by":"anthropic","created":700},
      {"id":"cpm-claude-api/claude-opus-4-8","owned_by":"anthropic","created":800},
      {"id":"claude-work/gpt-5.6","owned_by":"openai","created":900}
    ]}
    """#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(result: .success(data)))

    let options = try await client.claudeModelOptions(port: 18_317, modelPrefix: " claude-work ")

    XCTAssertEqual(options, [
        ClaudeModelOption(id: "claude-opus-4-8", family: .opus, created: 500),
        ClaudeModelOption(id: "claude-sonnet-5", family: .sonnet, created: 400),
        ClaudeModelOption(id: "claude-haiku-4-5", family: .haiku, created: 300),
        ClaudeModelOption(id: "claude-custom-preview", family: .other, created: 200)
    ])
}

func testClaudeModelOptionsKeepFirstDuplicateBaseID() async throws {
    let data = Data(#"{"data":[{"id":"claude-work/claude-opus-4-8","created":500},{"id":"claude-work/claude-opus-4-8","created":100}]}"#.utf8)
    let client = ProxyModelClient(httpClient: StubHTTPClient(result: .success(data)))

    let options = try await client.claudeModelOptions(port: 18_317, modelPrefix: "claude-work")

    XCTAssertEqual(options, [ClaudeModelOption(id: "claude-opus-4-8", family: .opus, created: 500)])
}

func testClaudeModelOptionsRejectBlankPrefixBeforeNetworkRequest() async {
    let httpClient = StubHTTPClient(result: .success(Data(#"{"data":[]}"#.utf8)))
    let client = ProxyModelClient(httpClient: httpClient)

    await XCTAssertThrowsErrorAsync(
        try await client.claudeModelOptions(port: 18_317, modelPrefix: "   ")
    ) { error in
        XCTAssertEqual(error as? ClaudeModelDiscoveryError, .emptyModelPrefix)
    }
    XCTAssertTrue(httpClient.requests.isEmpty)
}
```

- [ ] **Step 2: Run the focused test and observe missing-type failures**

Run:

```bash
swift test --filter ProxyModelClientTests
```

Expected: FAIL because the Claude option types and API are absent.

- [ ] **Step 3: Add typed metadata and the injection protocol**

Create `ClaudeModelOption.swift`:

```swift
import Foundation

public enum ClaudeModelFamily: String, Codable, Equatable, Sendable {
    case opus
    case sonnet
    case haiku
    case other

    public init(modelID: String) {
        let value = modelID.lowercased()
        if value.hasPrefix("claude-opus-") {
            self = .opus
        } else if value.hasPrefix("claude-sonnet-") {
            self = .sonnet
        } else if value.hasPrefix("claude-haiku-") {
            self = .haiku
        } else {
            self = .other
        }
    }

    public var displayName: String {
        rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
    }
}

public struct ClaudeModelOption: Equatable, Sendable {
    public let id: String
    public let family: ClaudeModelFamily
    public let created: Int?

    public init(id: String, family: ClaudeModelFamily? = nil, created: Int? = nil) {
        self.id = id
        self.family = family ?? ClaudeModelFamily(modelID: id)
        self.created = created
    }
}

public enum ClaudeModelDiscoveryError: Error, Equatable, LocalizedError {
    case emptyModelPrefix

    public var errorDescription: String? {
        "This Claude account does not have a routing prefix. Save the account settings, then retry."
    }
}

public protocol ClaudeModelListing: Sendable {
    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption]
}
```

- [ ] **Step 4: Implement exact-prefix extraction in `ProxyModelClient`**

Add protocol conformance and the public method:

```swift
extension ProxyModelClient: ClaudeModelListing {}
```

```swift
public func claudeModelOptions(
    port: Int,
    modelPrefix: String
) async throws -> [ClaudeModelOption] {
    let prefix = modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { throw ClaudeModelDiscoveryError.emptyModelPrefix }

    var seen = Set<String>()
    var result: [ClaudeModelOption] = []
    for model in try await sortedModels(port: port) {
        guard let baseID = modelIdentifier(model.id, withoutRoutingPrefix: prefix),
              baseID.lowercased().hasPrefix("claude-") else {
            continue
        }
        guard seen.insert(baseID).inserted else { continue }
        result.append(
            ClaudeModelOption(
                id: baseID,
                created: model.created.flatMap(Int.init(exactly:))
            )
        )
    }
    return result
}
```

Keep the exact `"prefix/"` boundary and do not reuse `baseModelName`, because Claude IDs must be preserved verbatim.

- [ ] **Step 5: Run model-client regressions**

Run:

```bash
swift test --filter ProxyModelClientTests
```

Expected: PASS, including all existing Codex capability tests.

- [ ] **Step 6: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/Proxy/ClaudeModelOption.swift Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
```

If commits are authorized and self-contained:

```bash
git add Sources/CLIProxyManagerCore/Proxy/ClaudeModelOption.swift
git add -p Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift
git diff --cached --check
git commit -m "feat: discover scoped Claude OAuth models"
```

---

### Task 3: Resolve Automatic and Explicit Claude Models Deterministically

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ClaudeModelResolverTests.swift`

**Interfaces:**
- Consumes: `ClaudeRouting`, `ClaudeModelOption`, `ClaudeModelFamily`, and `OAuthModelDefaults`.
- Produces: `ResolvedClaudeModels`, `ClaudeModelResolutionError`, `ClaudeModelResolver.resolve(routing:options:prefix:)`, `resolveBaseModel(selection:role:options:)`, and `orderedOptions(for:options:)`.

- [ ] **Step 1: Write resolver failure and ordering tests**

Create `ClaudeModelResolverTests.swift` with these representative cases:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ClaudeModelResolverTests: XCTestCase {
    func testAutomaticPrefersCreatedThenVersionThenDescendingID() throws {
        let options = [
            ClaudeModelOption(id: "claude-opus-4-7", created: 500),
            ClaudeModelOption(id: "claude-opus-4-8", created: 500),
            ClaudeModelOption(id: "claude-sonnet-4-6", created: nil),
            ClaudeModelOption(id: "claude-sonnet-5", created: nil),
            ClaudeModelOption(id: "claude-haiku-4-5-20251001", created: 300),
            ClaudeModelOption(id: "claude-haiku-4-5", created: 300)
        ]

        let resolved = try ClaudeModelResolver.resolve(
            routing: .automatic,
            options: options,
            prefix: "claude-work"
        )

        XCTAssertEqual(resolved.opus, "claude-work/claude-opus-4-8")
        XCTAssertEqual(resolved.sonnet, "claude-work/claude-sonnet-5")
        XCTAssertEqual(resolved.haiku, "claude-work/claude-haiku-4-5-20251001")
    }

    func testExplicitSelectionValidatesAvailabilityAndFamily() throws {
        let options = [
            ClaudeModelOption(id: "claude-opus-4-8", created: 500),
            ClaudeModelOption(id: "claude-sonnet-5", created: 400),
            ClaudeModelOption(id: "claude-haiku-4-5", created: 300)
        ]
        let routing = ClaudeRouting(
            opus: .model("claude-opus-4-8"),
            sonnet: .model("claude-sonnet-5"),
            haiku: .model("claude-haiku-4-5")
        )

        XCTAssertEqual(
            try ClaudeModelResolver.resolve(routing: routing, options: options, prefix: "claude-work"),
            ResolvedClaudeModels(
                opus: "claude-work/claude-opus-4-8",
                sonnet: "claude-work/claude-sonnet-5",
                haiku: "claude-work/claude-haiku-4-5"
            )
        )

        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .model("claude-sonnet-5"),
                role: .opus,
                options: options
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeModelResolutionError,
                .selectedModelHasWrongFamily(role: .opus, model: "claude-sonnet-5", actualFamily: .sonnet)
            )
        }
    }

    func testUnavailableExplicitSelectionDoesNotFallBackToAutomatic() {
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .model("claude-opus-4-7"),
                role: .opus,
                options: [ClaudeModelOption(id: "claude-opus-4-8")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeModelResolutionError,
                .selectedModelUnavailable(role: .opus, model: "claude-opus-4-7")
            )
        }
    }

    func testAutomaticCompatibilityFallbackIsScopedAndFamilySpecific() throws {
            let fallback = ClaudeModelOption(
            id: OAuthModelDefaults.claudeOpusModel,
            family: .other,
            created: nil
        )

        XCTAssertEqual(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .automatic,
                role: .opus,
                options: [fallback]
            ),
            OAuthModelDefaults.claudeOpusModel
        )
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .automatic,
                role: .sonnet,
                options: [fallback]
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeModelResolutionError, .noModelForFamily(.sonnet))
        }
    }

    func testEmptyScopedRegistryProducesPrefixSpecificError() {
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolve(routing: .automatic, options: [], prefix: "claude-work")
        ) { error in
            XCTAssertEqual(error as? ClaudeModelResolutionError, .noModelsAvailable(prefix: "claude-work"))
        }
    }

    func testShellAssignmentsSingleQuoteValues() throws {
        let resolved = ResolvedClaudeModels(
            opus: "claude-work/claude-opus-4-8",
            sonnet: "claude-work/claude-sonnet-5",
            haiku: "claude-work/claude-haiku-4-5"
        )

        XCTAssertEqual(resolved.shellEnvironmentAssignments, """
        ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-8'
        ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-5'
        ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5'
        """)
    }
}
```

- [ ] **Step 2: Run the resolver tests and verify missing API failures**

Run:

```bash
swift test --filter ClaudeModelResolverTests
```

Expected: FAIL because resolver types and methods are not defined.

- [ ] **Step 3: Add result and error types**

Append to `ClaudeModelRouting.swift`:

```swift
public struct ResolvedClaudeModels: Equatable, Sendable {
    public let opus: String
    public let sonnet: String
    public let haiku: String

    public init(opus: String, sonnet: String, haiku: String) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
    }

    public var shellEnvironmentAssignments: String {
        [
            "ANTHROPIC_DEFAULT_OPUS_MODEL=\(OAuthModelDefaults.shellSingleQuoted(opus))",
            "ANTHROPIC_DEFAULT_SONNET_MODEL=\(OAuthModelDefaults.shellSingleQuoted(sonnet))",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL=\(OAuthModelDefaults.shellSingleQuoted(haiku))"
        ].joined(separator: "\n")
    }
}

public enum ClaudeModelResolutionError: LocalizedError, Equatable {
    case noModelsAvailable(prefix: String)
    case noModelForFamily(ClaudeModelFamily)
    case selectedModelUnavailable(role: ClaudeModelFamily, model: String)
    case selectedModelHasWrongFamily(role: ClaudeModelFamily, model: String, actualFamily: ClaudeModelFamily)

    public var errorDescription: String? {
        switch self {
        case .noModelsAvailable(let prefix):
            "No Claude models are available for account prefix `\(prefix)`. Start CLIProxyAPI and verify this account, then retry."
        case .noModelForFamily(let family):
            "No \(family.displayName) model is available for this account. Refresh the account models or choose another account."
        case .selectedModelUnavailable(let role, let model):
            "Selected \(role.displayName) model \(model) is unavailable for this account. Choose another model or switch \(role.displayName) to Automatic."
        case .selectedModelHasWrongFamily(let role, let model, let actualFamily):
            "Selected \(role.displayName) model \(model) belongs to \(actualFamily.displayName). Choose a \(role.displayName) model or switch to Automatic."
        }
    }
}
```

- [ ] **Step 4: Implement one deterministic resolver used by UI and runtime**

Append the pure policy implementation:

```swift
public enum ClaudeModelResolver {
    public static func resolve(
        routing: ClaudeRouting,
        options: [ClaudeModelOption],
        prefix: String
    ) throws -> ResolvedClaudeModels {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.isEmpty else {
            throw ClaudeModelResolutionError.noModelsAvailable(prefix: trimmedPrefix)
        }

        return ResolvedClaudeModels(
            opus: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.opus, role: .opus, options: options),
                prefix: trimmedPrefix
            ),
            sonnet: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.sonnet, role: .sonnet, options: options),
                prefix: trimmedPrefix
            ),
            haiku: OAuthModelDefaults.prefixedModel(
                try resolveBaseModel(selection: routing.haiku, role: .haiku, options: options),
                prefix: trimmedPrefix
            )
        )
    }

    public static func resolveBaseModel(
        selection: ClaudeModelSelection,
        role: ClaudeModelFamily,
        options: [ClaudeModelOption]
    ) throws -> String {
        switch selection {
        case .automatic:
            if let latest = orderedOptions(for: role, options: options).first {
                return latest.id
            }
            let compatibilityID = compatibilityModelID(for: role)
            if options.contains(where: { $0.id == compatibilityID }) {
                return compatibilityID
            }
            throw ClaudeModelResolutionError.noModelForFamily(role)
        case .model(let rawModel):
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let option = options.first(where: { $0.id == model }) else {
                throw ClaudeModelResolutionError.selectedModelUnavailable(role: role, model: model)
            }
            guard option.family == role else {
                throw ClaudeModelResolutionError.selectedModelHasWrongFamily(
                    role: role,
                    model: model,
                    actualFamily: option.family
                )
            }
            return option.id
        }
    }

    public static func orderedOptions(
        for family: ClaudeModelFamily,
        options: [ClaudeModelOption]
    ) -> [ClaudeModelOption] {
        options.filter { $0.family == family }.sorted(by: isNewer)
    }

    private static func isNewer(_ lhs: ClaudeModelOption, _ rhs: ClaudeModelOption) -> Bool {
        switch (lhs.created, rhs.created) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let leftVersion = numericComponents(in: lhs.id)
            let rightVersion = numericComponents(in: rhs.id)
            if leftVersion != rightVersion {
                return versionIsGreater(leftVersion, than: rightVersion)
            }
            return lhs.id > rhs.id
        }
    }

    private static func numericComponents(in id: String) -> [Int] {
        id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private static func versionIsGreater(_ lhs: [Int], than rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func compatibilityModelID(for family: ClaudeModelFamily) -> String {
        switch family {
        case .opus: OAuthModelDefaults.claudeOpusModel
        case .sonnet: OAuthModelDefaults.claudeSonnetModel
        case .haiku: OAuthModelDefaults.claudeHaikuModel
        case .other: ""
        }
    }
}
```

- [ ] **Step 5: Run resolver and full core model tests**

Run:

```bash
swift test --filter ClaudeModelResolverTests
swift test --filter ProxyModelClientTests
swift test --filter AppConfigTests
```

Expected: PASS.

- [ ] **Step 6: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift Tests/CLIProxyManagerCoreTests/ClaudeModelResolverTests.swift
```

If commits are authorized and self-contained:

```bash
git add Sources/CLIProxyManagerCore/Routing/ClaudeModelRouting.swift Tests/CLIProxyManagerCoreTests/ClaudeModelResolverTests.swift
git diff --cached --check
git commit -m "feat: resolve Claude models from account capabilities"
```

---

### Task 4: Add the Runtime `routing claude-models` Helper

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:4-175,638-668`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Consumes: `ClaudeModelListing`, `ClaudeModelResolver`, `AppConfig.OAuthCommandProfile.effectiveClaudeRouting`, `AuthProfileStore`.
- Produces: `cpm routing claude-models <command-profile-id>` and `cpm routing claude-models --legacy`.

- [ ] **Step 1: Add failing individual and legacy routing tests**

Add a `StubClaudeModelListing` test double and tests for clean stdout, validation, and legacy ambiguity:

```swift
private final class StubClaudeModelListing: ClaudeModelListing, @unchecked Sendable {
    private(set) var requests: [(port: Int, prefix: String)] = []
    var optionsByPrefix: [String: [ClaudeModelOption]]

    init(optionsByPrefix: [String: [ClaudeModelOption]]) {
        self.optionsByPrefix = optionsByPrefix
    }

    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption] {
        requests.append((port, modelPrefix))
        return optionsByPrefix[modelPrefix] ?? []
    }
}
```

```swift
func testRoutingClaudeModelsPrintsOnlyShellAssignmentsForEnabledProxyProfile() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox)
    let configStore = AppConfigStore(paths: paths)
    var config = AppConfig.default
    config.port = 18_888
    config.oauthCommandProfiles = [
        .init(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            claude: .automatic,
            modelPrefix: "claude-work"
        )
    ]
    try configStore.save(config)
    let models = StubClaudeModelListing(optionsByPrefix: [
        "claude-work": [
            .init(id: "claude-opus-4-8", created: 500),
            .init(id: "claude-sonnet-5", created: 400),
            .init(id: "claude-haiku-4-5", created: 300)
        ]
    ])
    let output = OutputDouble(isInteractive: false)
    let command = CLIProxyManagerCommand(
        secretStore: InMemorySecretStore(),
        configStore: configStore,
        authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
        output: output,
        claudeModelClient: models
    )

    try await command.run(arguments: ["routing", "claude-models", "claude-work"])

    XCTAssertEqual(models.requests.map { "\($0.port):\($0.prefix)" }, ["18888:claude-work"])
    XCTAssertEqual(output.stderr, [])
    XCTAssertEqual(output.stdout, ["""
    ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-8'
    ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-5'
    ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5'

    """])
}

func testRoutingClaudeModelsRejectsDirectProfileWithoutQueryingModels() async {
    let sandbox = try! makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox)
    let configStore = AppConfigStore(paths: paths)
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "claude-direct",
            provider: .claude,
            authProfileID: "claude.json",
            commandName: "ccdirect",
            modelPrefix: "claude-direct",
            connectionMode: .direct
        )
    ]
    try! configStore.save(config)
    let models = StubClaudeModelListing(optionsByPrefix: [:])
    let command = CLIProxyManagerCommand(
        secretStore: InMemorySecretStore(),
        configStore: configStore,
        authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
        output: OutputDouble(isInteractive: false),
        claudeModelClient: models
    )

    await XCTAssertThrowsErrorAsync(
        try await command.run(arguments: ["routing", "claude-models", "claude-direct"])
    ) { error in
        XCTAssertEqual(
            error as? CLIProxyManagerCommandError,
            .prerequisite("Claude command profile `claude-direct` uses Direct mode and does not use proxy model routing.")
        )
    }
    XCTAssertTrue(models.requests.isEmpty)
}

func testLegacyClaudeRoutingRequiresExactlyOneEnabledPrefixedClaudeProfile() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox)
    try AppConfigStore(paths: paths).save(.default)
    try FileManager.default.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
    try Data(#"{"type":"claude","prefix":"claude-work","disabled":false}"#.utf8)
        .write(to: paths.authDirectory.appendingPathComponent("claude-work.json"))
    let models = StubClaudeModelListing(optionsByPrefix: [
        "claude-work": [
            .init(id: "claude-opus-4-8"),
            .init(id: "claude-sonnet-5"),
            .init(id: "claude-haiku-4-5")
        ]
    ])
    let output = OutputDouble(isInteractive: false)
    let command = CLIProxyManagerCommand(
        secretStore: InMemorySecretStore(),
        configStore: AppConfigStore(paths: paths),
        authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
        output: output,
        claudeModelClient: models
    )

    try await command.run(arguments: ["routing", "claude-models", "--legacy"])

    XCTAssertTrue(output.stdout.joined().contains("claude-work/claude-opus-4-8"))
}
```

Also add table-driven rejection cases for unknown, disabled, non-Claude, empty-prefix, and multiple legacy Claude profiles. Assert `CLIProxyManagerCommandError.prerequisite` with an action-oriented message and assert the listing stub received no request.

- [ ] **Step 2: Run command tests and verify failure**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: FAIL because the initializer and new route are absent.

- [ ] **Step 3: Inject the Claude model listing dependency**

Add a property and matching parameters to both command initializers:

```swift
private let claudeModelClient: any ClaudeModelListing
```

```swift
claudeModelClient: any ClaudeModelListing = ProxyModelClient()
```

Assign `self.claudeModelClient = claudeModelClient` in both initializers. Keep all existing dependency defaults unchanged.

- [ ] **Step 4: Dispatch and validate the new helper command**

Update usage text with:

```text
cpm routing claude-models <command-profile-id|--legacy>
```

Dispatch before the general switch:

```swift
if arguments.count == 3, arguments[0] == "routing", arguments[1] == "claude-models" {
    try await runClaudeModelsRouting(target: arguments[2])
    return
}
```

Implement the runtime method and keep stdout assignment-only:

```swift
private func runClaudeModelsRouting(target: String) async throws {
    let config = try configStore.load()
    let routing: ClaudeRouting
    let prefix: String

    if target == "--legacy" {
        guard config.oauthCommandProfiles.isEmpty else {
            throw CLIProxyManagerCommandError.prerequisite(
                "Legacy Claude routing is only available when account-specific command profiles have not been created."
            )
        }
        let profiles = try authProfileStore.profiles().filter {
            $0.type == .claude && !$0.disabled
        }
        guard profiles.count == 1, let profile = profiles.first else {
            let message = profiles.isEmpty
                ? "No enabled Claude OAuth account is available. Connect Claude OAuth in the app, then retry."
                : "Multiple Claude OAuth accounts are enabled. Save an account-specific command in the app, then retry."
            throw CLIProxyManagerCommandError.prerequisite(message)
        }
        prefix = profile.prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        routing = .automatic
    } else {
        guard let profile = config.oauthCommandProfiles.first(where: { $0.id == target }) else {
            throw CLIProxyManagerCommandError.prerequisite("Claude command profile `\(target)` was not found.")
        }
        guard profile.provider == .claude else {
            throw CLIProxyManagerCommandError.prerequisite("Command profile `\(target)` is not a Claude OAuth profile.")
        }
        guard profile.isEnabled else {
            throw CLIProxyManagerCommandError.prerequisite("Claude command profile `\(target)` is disabled.")
        }
        guard profile.connectionMode == .proxy else {
            throw CLIProxyManagerCommandError.prerequisite(
                "Claude command profile `\(target)` uses Direct mode and does not use proxy model routing."
            )
        }
        prefix = profile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        routing = profile.effectiveClaudeRouting
    }

    guard !prefix.isEmpty else {
        throw CLIProxyManagerCommandError.prerequisite(
            "This Claude account does not have a routing prefix. Save the account settings, then retry."
        )
    }

    do {
        let options = try await claudeModelClient.claudeModelOptions(
            port: config.port,
            modelPrefix: prefix
        )
        let resolved = try ClaudeModelResolver.resolve(
            routing: routing,
            options: options,
            prefix: prefix
        )
        output.writeStdout(resolved.shellEnvironmentAssignments + "\n")
    } catch {
        throw CLIProxyManagerCommandError.operation(error.localizedDescription)
    }
}
```

- [ ] **Step 5: Verify command behavior**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: PASS. Unknown command tests still return `.usage`; successful routing stdout contains no status prose.

- [ ] **Step 6: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git diff --cached --check
git commit -m "feat: resolve Claude OAuth models at command runtime"
```

---

### Task 5: Resolve Claude Round Robin After Account Selection

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:141-143,662-667`
- Test: `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Consumes: `ClaudeModelListing`, `ClaudeModelResolver`, selected `OAuthCommandProfile`, and existing `RoundRobinStateSelecting`.
- Produces: async `RoundRobinSelectionService.shellEnvironmentAssignments(profileID:config:authProfiles:)`.

- [ ] **Step 1: Replace the fixed-Claude expectation with selected-account capability tests**

Convert existing round-robin tests to async and replace `testClaudeSelectionUsesDefaultClaudeModels` with:

```swift
func testClaudeSelectionResolvesModelsForActuallySelectedAccount() async throws {
    var config = AppConfig.default
    config.port = 18_888
    config.oauthCommandProfiles = [
        .init(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            claude: .automatic,
            modelPrefix: "claude-work"
        ),
        .init(
            id: "claude-personal",
            provider: .claude,
            authProfileID: "claude-personal.json",
            commandName: "ccpersonal",
            claude: ClaudeRouting(
                opus: .model("claude-opus-4-7"),
                sonnet: .automatic,
                haiku: .automatic
            ),
            modelPrefix: "claude-personal"
        )
    ]
    config.roundRobinProfiles = [
        .init(
            id: "claude-default",
            provider: .claude,
            isEnabled: true,
            commandName: "cc",
            includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"]
        )
    ]
    let models = StubRoundRobinClaudeModelListing(optionsByPrefix: [
        "claude-work": [
            .init(id: "claude-opus-4-8"),
            .init(id: "claude-sonnet-5"),
            .init(id: "claude-haiku-4-5")
        ],
        "claude-personal": [
            .init(id: "claude-opus-4-7"),
            .init(id: "claude-sonnet-4-6"),
            .init(id: "claude-haiku-4-5")
        ]
    ])
    let service = RoundRobinSelectionService(
        stateSelector: StubRoundRobinStateSelector(selections: ["claude-personal.json"]),
        claudeModelClient: models
    )

    let output = try await service.shellEnvironmentAssignments(
        profileID: "claude-default",
        config: config,
        authProfiles: [
            .init(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-work"),
            .init(fileName: "claude-personal.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-personal")
        ]
    )

    XCTAssertEqual(models.prefixes, ["claude-personal"])
    XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-personal/claude-opus-4-7'"))
    XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-personal/claude-sonnet-4-6'"))
    XCTAssertTrue(output.contains("CLIPROXY_ROUND_ROBIN_PROFILE='claude-personal.json'"))
}
```

Add a second test where the selected account has an unavailable explicit Opus selection. Assert the resolver error is thrown, the state selector has exactly one call, and no second account is selected.

- [ ] **Step 2: Run the focused test and verify fixed-default behavior fails**

Run:

```bash
swift test --filter RoundRobinSelectionServiceTests
```

Expected: FAIL because the service is synchronous, lacks model-client injection, and still uses `OAuthModelDefaults` for Claude.

- [ ] **Step 3: Carry the command profile through candidate selection**

Change `Candidate` to retain policy and prefix:

```swift
private struct Candidate: Sendable {
    let authProfileID: String
    let commandProfile: AppConfig.OAuthCommandProfile
    let modelPrefix: String
}
```

When building a candidate, return all three values. Continue rejecting duplicate command profiles exactly as before.

- [ ] **Step 4: Make selection async and resolve only the selected Claude account**

Inject the model listing dependency:

```swift
private let stateSelector: any RoundRobinStateSelecting
private let claudeModelClient: any ClaudeModelListing

public init(
    stateSelector: any RoundRobinStateSelecting = RoundRobinStateStore(),
    claudeModelClient: any ClaudeModelListing = ProxyModelClient()
) {
    self.stateSelector = stateSelector
    self.claudeModelClient = claudeModelClient
}
```

Change the method to `async throws`. Replace the fixed model call with:

```swift
let models: (opus: String, sonnet: String, haiku: String)
switch profile.provider {
case .claude:
    let options = try await claudeModelClient.claudeModelOptions(
        port: config.port,
        modelPrefix: selected.modelPrefix
    )
    let resolved = try ClaudeModelResolver.resolve(
        routing: selected.commandProfile.effectiveClaudeRouting,
        options: options,
        prefix: selected.modelPrefix
    )
    models = (resolved.opus, resolved.sonnet, resolved.haiku)
case .codex:
    let codex = profile.codex ?? config.ccodex
    models = (
        OAuthModelDefaults.prefixedModel(codex.opus.modelIdentifier, prefix: selected.modelPrefix),
        OAuthModelDefaults.prefixedModel(codex.sonnet.modelIdentifier, prefix: selected.modelPrefix),
        OAuthModelDefaults.prefixedModel(codex.haiku.modelIdentifier, prefix: selected.modelPrefix)
    )
}
```

Do not catch resolver errors or select again.

- [ ] **Step 5: Await round-robin selection in the CLI**

Change dispatch and the helper method:

```swift
if arguments.count == 3, arguments[0] == "routing", arguments[1] == "next" {
    try await runRoutingNext(profileID: arguments[2])
    return
}
```

```swift
private func runRoutingNext(profileID: String) async throws {
    let config = try configStore.load()
    let authProfiles = try authProfileStore.profiles()
    let service = RoundRobinSelectionService(
        stateSelector: stateSelector,
        claudeModelClient: claudeModelClient
    )
    let assignments = try await service.shellEnvironmentAssignments(
        profileID: profileID,
        config: config,
        authProfiles: authProfiles
    )
    output.writeStdout(assignments + "\n")
}
```

Update every existing direct service invocation in tests to `try await` and mark the test `async`.

- [ ] **Step 6: Verify round robin and CLI regressions**

Run:

```bash
swift test --filter RoundRobinSelectionServiceTests
swift test --filter CLIProxyManagerCommandTests
```

Expected: PASS. Codex round robin output is unchanged and Claude requests only the selected account prefix.

- [ ] **Step 7: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git diff --cached --check
git commit -m "feat: apply selected Claude account routing to round robin"
```

---

### Task 6: Generate Dynamic Claude Shell Functions and Isolate Direct Mode

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift:90-323`
- Test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

**Interfaces:**
- Consumes: `cpm routing claude-models`, existing helper path quoting, and the existing Claude command builder.
- Produces: helper-driven individual and legacy Claude proxy functions; fully unset Direct functions.

- [ ] **Step 1: Change fixed-model tests into runtime-helper tests**

Update or add assertions:

```swift
func testClaudeOAuthProxyFunctionResolvesModelsAtInvocationTime() throws {
    var config = configuredCommands()
    config.oauthCommandProfiles = [
        .init(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            claude: .automatic,
            modelPrefix: "claude-work"
        )
    ]

    let script = try ShellFunctionRenderer(
        config: config,
        helperCommand: "/usr/local/bin/cpm"
    ).render()

    XCTAssertTrue(script.contains("routing claude-models 'claude-work'"))
    XCTAssertTrue(script.contains("if ! routing_env="))
    XCTAssertTrue(script.contains("eval \"$routing_env\""))
    XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL=\"$ANTHROPIC_DEFAULT_OPUS_MODEL\""))
    XCTAssertFalse(script.contains("claude-work/claude-opus-4-7"))
    XCTAssertFalse(script.contains("claude-work/claude-sonnet-4-6"))
    XCTAssertFalse(script.contains("claude-work/claude-haiku-4-5-20251001"))
}

func testLegacyClaudeOAuthFunctionUsesExplicitLegacyResolver() throws {
    let script = try ShellFunctionRenderer(
        config: configuredCommands(),
        helperCommand: "/usr/local/bin/cpm"
    ).render()

    XCTAssertTrue(script.contains("routing claude-models '--legacy'"))
    XCTAssertFalse(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7'"))
}

func testDirectClaudeFunctionUnsetsProxyCredentialsAndAllModelOverrides() throws {
    var config = configuredCommands()
    config.oauthCommandProfiles = [
        .init(
            id: "claude-direct",
            provider: .claude,
            authProfileID: "claude.json",
            commandName: "ccdirect",
            modelPrefix: "claude-direct",
            connectionMode: .direct
        )
    ]

    let script = try ShellFunctionRenderer(config: config, helperCommand: "/usr/local/bin/cpm").render()

    XCTAssertTrue(script.contains("env -u ANTHROPIC_BASE_URL"))
    XCTAssertTrue(script.contains("-u ANTHROPIC_AUTH_TOKEN"))
    XCTAssertTrue(script.contains("-u ANTHROPIC_API_KEY"))
    XCTAssertTrue(script.contains("-u ANTHROPIC_DEFAULT_OPUS_MODEL"))
    XCTAssertTrue(script.contains("-u ANTHROPIC_DEFAULT_SONNET_MODEL"))
    XCTAssertTrue(script.contains("-u ANTHROPIC_DEFAULT_HAIKU_MODEL"))
    XCTAssertFalse(script.contains("routing claude-models 'claude-direct'"))
}
```

Keep the existing Codex and Claude API Key expectations intact.

- [ ] **Step 2: Run renderer tests and verify fixed model assertions fail**

Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: FAIL because Claude OAuth functions still inline fixed IDs and Direct removes only three variables.

- [ ] **Step 3: Add a focused helper-driven Claude function renderer**

Add:

```swift
private func renderClaudeProxyFunction(
    commandName: String,
    routingTarget: String,
    dangerousPermissionsEnabled: Bool
) -> String {
    let claudeCommand = claudeCommand(skipPermissions: dangerousPermissionsEnabled)
    return """
    \(commandName)() {
      local routing_env
      if ! routing_env="$(\(shellSingleQuoted(helperCommand)) routing claude-models \(shellSingleQuoted(routingTarget)))"; then
        return 1
      fi
      eval "$routing_env"

      ANTHROPIC_BASE_URL="http://127.0.0.1:\(config.port)" \\
      ANTHROPIC_AUTH_TOKEN='sk-dummy' \\
      ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL" \\
      ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_DEFAULT_SONNET_MODEL" \\
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_DEFAULT_HAIKU_MODEL" \\
      \(claudeCommand)
    }

    """
}
```

Use `routingTarget: "--legacy"` in the legacy Claude branch and `routingTarget: commandProfile.id` for account-specific Claude proxy profiles. Remove the Claude fixed-model locals from `renderLegacyOAuthFunctions`.

- [ ] **Step 4: Keep Codex static routing and expand Direct unsets**

In `renderOAuthFunction`, branch in this order:

```swift
if commandProfile.provider == .claude, commandProfile.connectionMode == .direct {
    return """
    \(commandName)() {
      env -u ANTHROPIC_BASE_URL \\
          -u ANTHROPIC_AUTH_TOKEN \\
          -u ANTHROPIC_API_KEY \\
          -u ANTHROPIC_DEFAULT_OPUS_MODEL \\
          -u ANTHROPIC_DEFAULT_SONNET_MODEL \\
          -u ANTHROPIC_DEFAULT_HAIKU_MODEL \\
          \(claudeCommand)
    }

    """
}
if commandProfile.provider == .claude {
    return renderClaudeProxyFunction(
        commandName: commandName,
        routingTarget: commandProfile.id,
        dangerousPermissionsEnabled: commandProfile.dangerousPermissionsEnabled
    )
}
```

Leave the existing Codex proxy function’s static role model mapping and health check unchanged. Remove the Claude case from `defaultModels(for:)` by replacing it with a Codex-only helper used only after the Claude branches return.

- [ ] **Step 5: Verify renderer and shell-install regressions**

Run:

```bash
swift test --filter ShellFunctionRendererTests
swift test --filter DashboardViewModelRefreshTests/testInstallShellFunctions
```

Expected: PASS. Generated Claude OAuth functions contain no fixed Claude release ID.

- [ ] **Step 6: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git diff --cached --check
git commit -m "feat: render dynamic Claude OAuth shell routing"
```

---

### Task 7: Load and Save Scoped Claude Routing in the Dashboard View Model

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:23-34,1094-1139,1410-1453`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:3203-3265`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift:961-1034`

**Interfaces:**
- Consumes: `ClaudeModelListing`, `OAuthCommandProfile.effectiveClaudeRouting`, scoped model prefix.
- Produces: `DashboardViewModel.claudeModels(for:)` and a save API that accepts `ClaudeRouting` while preserving it across connection-mode switches.

- [ ] **Step 1: Add failing scoped loading and save-preservation tests**

Add to `DashboardViewModelTests`:

```swift
func testClaudeModelsForProviderUseOnlyThatCommandProfilePrefix() async throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            modelPrefix: "claude-work"
        )
    ]
    let modelClient = StubProxyModelClient(claudeOptionsByPrefix: [
        "claude-work": [
            .init(id: "claude-opus-4-8"),
            .init(id: "claude-sonnet-5"),
            .init(id: "claude-haiku-4-5")
        ]
    ])
    let viewModel = DashboardViewModel(
        configStore: StubConfigStore(config: config),
        shellInstaller: StubShellInstaller(),
        modelClient: modelClient,
        authProfileStore: StubAuthProfileStore(profiles: []),
        proxyService: StubProxyServiceStarter(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )

    let options = try await viewModel.claudeModels(for: .init(rawValue: "claude-work"))

    XCTAssertEqual(options.map(\.id), ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"])
    XCTAssertEqual(modelClient.claudePrefixRequests, [PrefixModelRequest(port: config.port, prefix: "claude-work")])
}
```

Add to `ProviderSettingsViewModelTests`:

```swift
func testSaveClaudeOAuthSettingsPersistsRoutingAndDirectModeWithoutDiscardingPolicy() throws {
    var config = AppConfig.default
    config.oauthCommandProfiles = [
        .init(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            modelPrefix: "claude-work"
        )
    ]
    let store = StubConfigStore(config: config)
    let viewModel = DashboardViewModel(
        configStore: store,
        shellInstaller: StubShellInstaller(),
        authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
        proxyService: StubProxyService(),
        claudeConnector: connectedClaudeConnector(),
        secretStore: InMemorySecretStore()
    )
    let routing = ClaudeRouting(
        opus: .model("claude-opus-4-8"),
        sonnet: .automatic,
        haiku: .model("claude-haiku-4-5")
    )

    try viewModel.saveClaudeOAuthSettings(
        provider: .init(rawValue: "claude-work"),
        functionName: "ccwork",
        nickname: "Work",
        dangerousPermissionsEnabled: false,
        connectionMode: .direct,
        claudeRouting: routing
    )

    let saved = try XCTUnwrap(store.savedConfigs.last?.oauthCommandProfiles.first)
    XCTAssertEqual(saved.claude, routing)
    XCTAssertEqual(saved.connectionMode, .direct)
}
```

- [ ] **Step 2: Run focused app tests and verify protocol/signature failures**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests/testClaudeModelsForProvider
swift test --filter ProviderSettingsViewModelTests/testSaveClaudeOAuthSettingsPersistsRouting
```

Expected: FAIL because the app protocol, test double, load method, and save parameter are missing.

- [ ] **Step 3: Extend the app model-listing abstraction**

Add to `ProxyModelListing`:

```swift
func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption]
```

The existing `ProxyModelClient` conformance then satisfies both Codex and Claude requirements. Extend `StubProxyModelClient` without removing its existing initializers or Codex request recording:

```swift
private let claudeOptionsByPrefix: [String: [ClaudeModelOption]]
private var _claudePrefixRequests: [PrefixModelRequest] = []

var claudePrefixRequests: [PrefixModelRequest] {
    lock.withLock { _claudePrefixRequests }
}

init(claudeOptionsByPrefix: [String: [ClaudeModelOption]]) {
    options = []
    optionsByPrefix = [:]
    self.claudeOptionsByPrefix = claudeOptionsByPrefix
}

func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption] {
    lock.withLock {
        _claudePrefixRequests.append(PrefixModelRequest(port: port, prefix: modelPrefix))
    }
    return claudeOptionsByPrefix[modelPrefix] ?? []
}
```

Initialize `claudeOptionsByPrefix = [:]` in each existing `init(models:)`, `init(options:)`, `init(modelsByPrefix:)`, and `init(optionsByPrefix:)`. This keeps every existing test call source-compatible while adding the dedicated Claude test initializer.

- [ ] **Step 4: Add the scoped Claude loader**

Implement:

```swift
func claudeModels(for provider: ProviderRowState.ID) async throws -> [ClaudeModelOption] {
    guard let commandProfile = config.oauthCommandProfiles.first(where: {
        $0.id == provider.rawValue && $0.provider == .claude
    }) else {
        return []
    }
    let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty else { throw ClaudeModelDiscoveryError.emptyModelPrefix }
    return try await modelClient.claudeModelOptions(port: config.port, modelPrefix: prefix)
}
```

Do not use the global Codex model list as a fallback.

- [ ] **Step 5: Persist explicit routing through the existing save transaction**

Extend the account-specific save signature:

```swift
func saveClaudeOAuthSettings(
    provider: ProviderRowState.ID,
    functionName: String,
    nickname: String,
    dangerousPermissionsEnabled: Bool,
    connectionMode: AppConfig.ConnectionMode? = nil,
    claudeRouting: ClaudeRouting? = nil
) throws
```

Inside the matched profile branch:

```swift
if let connectionMode {
    updatedConfig.oauthCommandProfiles[index].connectionMode = connectionMode
}
if let claudeRouting {
    updatedConfig.oauthCommandProfiles[index].claude = claudeRouting
}
```

Update the legacy overload to pass its current profile’s `claude` value so existing settings remain unchanged. Do not clear routing when `connectionMode == .direct`.

- [ ] **Step 6: Verify focused and full provider settings tests**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests/testClaudeModelsForProvider
swift test --filter ProviderSettingsViewModelTests
```

Expected: PASS. Existing nickname-based prefix synchronization and rollback tests remain green.

- [ ] **Step 7: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift
git diff --cached --check
git commit -m "feat: load and save Claude account model routing"
```

---

### Task 8: Add Proxy-Only Claude Role Pickers With Automatic Previews

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/ClaudeRoleRoutingOptions.swift`
- Create: `Sources/CLIProxyManagerApp/Views/ClaudeRoleRoutingFields.swift`
- Create: `Tests/CLIProxyManagerAppTests/ClaudeRoleRoutingOptionsTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift:434-645`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:303-338`
- Modify: `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift`

**Interfaces:**
- Consumes: `ClaudeModelResolver.resolveBaseModel`, `orderedOptions`, `DashboardViewModel.claudeModels(for:)`, and `saveClaudeOAuthSettings(...claudeRouting:)`.
- Produces: deterministic picker rows, `ClaudeRoleRoutingFields`, proxy-only section visibility, and refresh-error preservation.

- [ ] **Step 1: Write pure picker-option tests**

Create `ClaudeRoleRoutingOptionsTests.swift`:

```swift
import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class ClaudeRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        ClaudeModelOption(id: "claude-opus-4-8", created: 500),
        ClaudeModelOption(id: "claude-opus-4-7", created: 400),
        ClaudeModelOption(id: "claude-sonnet-5", created: 500),
        ClaudeModelOption(id: "claude-haiku-4-5", created: 500),
        ClaudeModelOption(id: "claude-custom-preview", family: .other, created: 600)
    ]

    func testAutomaticRowUsesTheRuntimeResolverResult() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .opus,
            selection: .automatic,
            options: options
        )

        XCTAssertEqual(rows.first, .init(selection: .automatic, label: "Automatic — claude-opus-4-8"))
        XCTAssertEqual(rows.dropFirst().map(\.selection), [
            .model("claude-opus-4-8"),
            .model("claude-opus-4-7")
        ])
    }

    func testRowsExcludeWrongFamiliesAndOtherModels() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .sonnet,
            selection: .automatic,
            options: options
        )

        XCTAssertEqual(rows.map(\.selection), [.automatic, .model("claude-sonnet-5")])
    }

    func testRowsPreserveUnavailableStoredSelection() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .opus,
            selection: .model("claude-opus-4-6"),
            options: options
        )

        XCTAssertEqual(rows.last, .init(
            selection: .model("claude-opus-4-6"),
            label: "Unavailable — claude-opus-4-6"
        ))
    }

    func testModelsSectionVisibilityIsProxyOnly() {
        XCTAssertTrue(ClaudeRoleRoutingOptions.showsModels(connectionMode: .proxy))
        XCTAssertFalse(ClaudeRoleRoutingOptions.showsModels(connectionMode: .direct))
    }
}
```

- [ ] **Step 2: Run the new test and verify missing helper failures**

Run:

```bash
swift test --filter ClaudeRoleRoutingOptionsTests
```

Expected: FAIL because the option helper does not exist.

- [ ] **Step 3: Implement pure picker row construction**

Create `ClaudeRoleRoutingOptions.swift`:

```swift
import CLIProxyManagerCore

struct ClaudeModelPickerRow: Equatable, Identifiable {
    let selection: ClaudeModelSelection
    let label: String

    var id: String {
        switch selection {
        case .automatic: "automatic"
        case .model(let model): "model:\(model)"
        }
    }
}

enum ClaudeRoleRoutingOptions {
    static func showsModels(connectionMode: AppConfig.ConnectionMode) -> Bool {
        connectionMode == .proxy
    }

    static func rows(
        role: ClaudeModelFamily,
        selection: ClaudeModelSelection,
        options: [ClaudeModelOption]
    ) -> [ClaudeModelPickerRow] {
        let automaticLabel: String
        if let model = try? ClaudeModelResolver.resolveBaseModel(
            selection: .automatic,
            role: role,
            options: options
        ) {
            automaticLabel = "Automatic — \(model)"
        } else {
            automaticLabel = "Automatic"
        }

        var rows = [ClaudeModelPickerRow(selection: .automatic, label: automaticLabel)]
        rows += ClaudeModelResolver.orderedOptions(for: role, options: options).map {
            ClaudeModelPickerRow(selection: .model($0.id), label: $0.id)
        }
        if case .model(let current) = selection,
           !rows.contains(where: { $0.selection == .model(current) }) {
            rows.append(.init(selection: .model(current), label: "Unavailable — \(current)"))
        }
        return rows
    }
}
```

- [ ] **Step 4: Build focused reusable role fields**

Create `ClaudeRoleRoutingFields.swift` with one role row and a three-role wrapper:

```swift
import CLIProxyManagerCore
import SwiftUI

struct ClaudeRoleRoutingFields: View {
    @Binding var routing: ClaudeRouting
    let options: [ClaudeModelOption]

    var body: some View {
        GroupCard {
            ClaudeModelRoleRow(
                label: "Opus",
                role: .opus,
                selection: $routing.opus,
                options: options,
                isLast: false
            )
            ClaudeModelRoleRow(
                label: "Sonnet",
                role: .sonnet,
                selection: $routing.sonnet,
                options: options,
                isLast: false
            )
            ClaudeModelRoleRow(
                label: "Haiku",
                role: .haiku,
                selection: $routing.haiku,
                options: options,
                isLast: true
            )
        }
    }
}

private struct ClaudeModelRoleRow: View {
    let label: String
    let role: ClaudeModelFamily
    @Binding var selection: ClaudeModelSelection
    let options: [ClaudeModelOption]
    let isLast: Bool

    var body: some View {
        CardRow(
            label: label,
            description: "Select Automatic to use this account’s latest available \(label) model.",
            isLast: isLast
        ) {
            Picker(label, selection: $selection) {
                ForEach(ClaudeRoleRoutingOptions.rows(
                    role: role,
                    selection: selection,
                    options: options
                )) { row in
                    Text(row.label).tag(row.selection)
                }
            }
            .labelsHidden()
            .frame(width: 225)
        }
    }
}
```

- [ ] **Step 5: Wire state, loading, Direct copy, and save into the Claude sheet**

Extend `OAuthSettingsInitialState` with `claudeRouting` and initialize it from `commandProfile.effectiveClaudeRouting`, defaulting to `.automatic` for initial or legacy settings.

Add sheet state and inputs:

```swift
@State private var claudeRouting: ClaudeRouting
@State private var scopedModels: [ClaudeModelOption] = []
@State private var modelLoadError: String?
@State private var isReloadingModels = false
let refreshModels: () async throws -> [ClaudeModelOption]
let save: (String, String, Bool, AppConfig.ConnectionMode, ClaudeRouting) throws -> Void
```

In the content, replace the single connection section with:

```swift
ClaudeOAuthConnectionModeSection(connectionMode: $connectionMode)

if ClaudeRoleRoutingOptions.showsModels(connectionMode: connectionMode) {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            GroupTitle(text: "Models")
            Spacer()
            Button {
                Task { await reloadModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isReloadingModels)
            .help("Refresh models for this Claude account")
        }
        ClaudeRoleRoutingFields(routing: $claudeRouting, options: scopedModels)
        if isReloadingModels {
            Text("Loading models for this Claude account.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        } else if let modelLoadError {
            Text(modelLoadError)
                .font(.system(size: 11.5))
                .foregroundStyle(BrandPalette.statusWarning)
        }
    }
} else {
    Text("Direct uses Claude Code's current model policy.")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
}
```

Save all five values and load without clearing stored state:

```swift
try save(
    functionName,
    nickname,
    dangerousPermissionsEnabled,
    connectionMode,
    claudeRouting
)
```

```swift
private func reloadModels() async {
    guard connectionMode == .proxy, !isReloadingModels else { return }
    isReloadingModels = true
    defer { isReloadingModels = false }
    do {
        scopedModels = try await refreshModels()
        modelLoadError = nil
    } catch {
        modelLoadError = error.localizedDescription
    }
}
```

Call `.task(id: connectionMode) { if connectionMode == .proxy { await reloadModels() } }`. Do not assign to `claudeRouting` from the fetched options.

- [ ] **Step 6: Connect the sheet to `DashboardViewModel`**

In `DashboardView` pass:

```swift
refreshModels: {
    try await viewModel.claudeModels(for: provider)
},
```

Update the save closure:

```swift
save: { functionName, nickname, dangerousPermissionsEnabled, connectionMode, claudeRouting in
    try viewModel.saveClaudeOAuthSettings(
        provider: provider,
        functionName: functionName,
        nickname: nickname,
        dangerousPermissionsEnabled: dangerousPermissionsEnabled,
        connectionMode: connectionMode,
        claudeRouting: claudeRouting
    )
    activeSheet = nil
}
```

Update every other `ClaudeOAuthProviderSettingsSheet` construction, including previews or provider list flows, with the same load/save signature.

- [ ] **Step 7: Verify picker helper, sheet metrics, and provider settings**

Run:

```bash
swift test --filter ClaudeRoleRoutingOptionsTests
swift test --filter ProviderSettingsSheetMetricsTests
swift test --filter ProviderSettingsViewModelTests
```

Expected: PASS. Refresh failure leaves `claudeRouting` unchanged, Direct hides fields, and returning to proxy shows the prior state.

- [ ] **Step 8: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerApp/Models/ClaudeRoleRoutingOptions.swift Sources/CLIProxyManagerApp/Views/ClaudeRoleRoutingFields.swift Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/ClaudeRoleRoutingOptionsTests.swift Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift
```

If commits are authorized and self-contained:

```bash
git add Sources/CLIProxyManagerApp/Models/ClaudeRoleRoutingOptions.swift Sources/CLIProxyManagerApp/Views/ClaudeRoleRoutingFields.swift Tests/CLIProxyManagerAppTests/ClaudeRoleRoutingOptionsTests.swift
git add -p Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift
git diff --cached --check
git commit -m "feat: add Claude OAuth model routing controls"
```

---

### Task 9: Represent Stale Usage and Preserve It in CLI Output

**Files:**
- Modify: `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift:87-102`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:494-521,589-621`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Produces: `.stale(SubscriptionUsageSnapshot, SubscriptionUsageIssue)`, `snapshot`, `issue`, `stopsAutomaticPolling`, stale text output, and JSON status `stale`.
- Consumes: existing snapshot rendering and `SubscriptionUsageIssue.stopsPolling`.

- [ ] **Step 1: Add failing stale text and JSON tests**

Add a quota test using a stale Codex snapshot:

```swift
func testQuotaTextPrintsStaleSnapshotBeforeWarning() async throws {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [
            .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )
    let command = try quotaCommand(
        profileType: .codex,
        profileFileName: "codex.json",
        state: .stale(snapshot, .credentialExpired)
    )

    try await command.command.run(arguments: ["quota"])

    let text = command.output.stdout.joined()
    XCTAssertTrue(text.contains("5h   ██░░░░░░░░  15%"))
    XCTAssertTrue(text.contains("Warning: Credential needs attention. Showing last successful usage."))
    XCTAssertLessThan(
        try XCTUnwrap(text.range(of: "15%")?.lowerBound),
        try XCTUnwrap(text.range(of: "Warning:")?.lowerBound)
    )
}
```

Add a JSON test asserting `status == "stale"`, `issue == "credentialExpired"`, and windows remain present. Reuse the current sandbox setup if introducing a `quotaCommand` test helper would duplicate too much setup.

- [ ] **Step 2: Run CLI tests and verify the enum case is missing**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: FAIL because `.stale` is undefined.

- [ ] **Step 3: Add stale state and shared projections**

Update the enum:

```swift
public enum AccountSubscriptionUsageState: Equatable, Sendable {
    case disabled
    case managementKeyNotConfigured
    case loading
    case available(SubscriptionUsageSnapshot)
    case stale(SubscriptionUsageSnapshot, SubscriptionUsageIssue)
    case unavailable(SubscriptionUsageIssue)

    public var snapshot: SubscriptionUsageSnapshot? {
        switch self {
        case .available(let snapshot), .stale(let snapshot, _): snapshot
        case .disabled, .managementKeyNotConfigured, .loading, .unavailable: nil
        }
    }

    public var issue: SubscriptionUsageIssue? {
        switch self {
        case .stale(_, let issue), .unavailable(let issue): issue
        case .disabled, .managementKeyNotConfigured, .loading, .available: nil
        }
    }

    public var stopsAutomaticPolling: Bool {
        issue?.stopsPolling ?? false
    }

    public var shouldDisplayInMenuBar: Bool {
        switch self {
        case .disabled, .managementKeyNotConfigured, .unavailable(.proxyUnavailable): false
        case .loading, .available, .stale, .unavailable: true
        }
    }
}
```

- [ ] **Step 4: Reuse snapshot text rendering and append the stale warning**

Extract existing `.available` rendering into:

```swift
private func writeQuotaSnapshot(_ snapshot: SubscriptionUsageSnapshot, provider: AuthProfileType) {
    guard !snapshot.windows.isEmpty else {
        output.writeStdout("  Usage details unavailable\n")
        return
    }
    for window in snapshot.windows {
        let percent = Int(min(max(window.usedPercent, 0), 100).rounded())
        let label = quotaWindowLabel(window, provider: provider)
        let displayLabel = label.count < 4
            ? label.padding(toLength: 4, withPad: " ", startingAt: 0)
            : label
        output.writeStdout("  \(displayLabel) \(quotaProgressBar(usedPercent: window.usedPercent)) \(String(format: "%3d", percent))%\n")
        if let resetAt = window.resetAt {
            output.writeStdout("       Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))\n")
        }
    }
}
```

Use it in the switch:

```swift
case .available(let snapshot):
    writeQuotaSnapshot(snapshot, provider: provider)
case .stale(let snapshot, let issue):
    writeQuotaSnapshot(snapshot, provider: provider)
    output.writeStdout("  Warning: \(issue.message) Showing last successful usage.\n")
```

- [ ] **Step 5: Preserve stale windows in JSON**

Add:

```swift
case .stale(let snapshot, let value):
    status = "stale"
    issue = value
    windows = snapshot.windows
```

Keep `.unavailable` windowless.

- [ ] **Step 6: Verify core usage output**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests
```

Expected: PASS, including existing available and unavailable output.

- [ ] **Step 7: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git diff --cached --check
git commit -m "feat: represent stale subscription usage"
```

---

### Task 10: Apply Stale-While-Error State Transitions, Cache, and Polling

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:419-623,677-683`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:2419-2821`
- Test: `Tests/CLIProxyManagerAppTests/SubscriptionUsageSnapshotCacheTests.swift`

**Interfaces:**
- Consumes: `AccountSubscriptionUsageState.snapshot`, `issue`, and `stopsAutomaticPolling`.
- Produces: profile-local merge policy, cache persistence for available and stale states, terminal stale polling exclusion, retriable stale backoff, and force-refresh recovery.

- [ ] **Step 1: Rewrite existing failure expectations to require `.stale`**

Replace the transient and terminal tests with assertions that retain the original snapshot and latest issue:

```swift
func testAutomaticUsageRefreshKeepsSnapshotAndMarksTransientFailureStale() async {
    var config = AppConfig.default
    config.subscriptionUsage.isEnabled = true
    let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
    let initialState = availableUsageState(for: profile)
    let snapshot = try! XCTUnwrap(initialState.snapshot)
    let quotaClient = RecordingSubscriptionQuotaClient(reports: [
        .init(statesByProfileID: [profile.id: initialState], fetchedAt: snapshot.fetchedAt),
        .init(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60))
    ])
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
        proxyService: StubProxyServiceStarter(),
        profiles: [profile],
        quotaClient: quotaClient
    )
    viewModel.serverStatus = readyStatus()

    await viewModel.refreshSubscriptionUsage()
    await viewModel.refreshSubscriptionUsage()

    XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(snapshot, .transientFailure))
}
```

Rename `testAutomaticUsageRefreshReplacesExistingUsageAfterTerminalFailure` to `testAutomaticUsageRefreshKeepsSnapshotAndCacheAfterTerminalFailure` and expect:

```swift
XCTAssertEqual(
    viewModel.subscriptionUsageStates[profile.id],
    .stale(try XCTUnwrap(initialState.snapshot), .credentialExpired)
)
XCTAssertEqual(cache.load(), [profile.id: try XCTUnwrap(initialState.snapshot)])
```

Change the manual-failure expectation to stale. Add a stale-to-success test and a stale-to-new-issue test.

- [ ] **Step 2: Add polling-specific stale tests**

Add tests proving:

```swift
XCTAssertEqual(
    await quotaClient.requestedProfileIDs(),
    [[claude.id, codex.id], [codex.id]]
)
```

when Claude is `.stale(snapshot, .credentialExpired)`, and proving a forced refresh later includes both profiles and changes Claude to `.available(newSnapshot)`. Add a transient stale test whose recorded delays are `60s`, `120s`, and whose snapshot remains unchanged while the issue updates.

- [ ] **Step 3: Run the focused app test group and verify current behavior fails**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests/testAutomaticUsageRefresh
swift test --filter DashboardViewModelRefreshTests/testManualUsageRefresh
swift test --filter DashboardViewModelRefreshTests/testNonRetriableProfile
```

Expected: FAIL because current code either suppresses retriable errors entirely or replaces terminal snapshots.

- [ ] **Step 4: Persist every state carrying a successful snapshot**

Replace cache reduction with:

```swift
private func persistSuccessfulSubscriptionUsageSnapshots() {
    let snapshots = subscriptionUsageStates.reduce(
        into: [String: SubscriptionUsageSnapshot]()
    ) { result, entry in
        if let snapshot = entry.value.snapshot {
            result[entry.key] = snapshot
        }
    }
    try? subscriptionUsageSnapshotCache.save(snapshots)
}
```

Keep restore behavior as `.available(snapshot)`. Existing profile filtering in `refreshProfiles()` remains the account-removal cleanup path.

- [ ] **Step 5: Preserve existing snapshots while requests are in flight**

When selecting IDs to mark `.loading`, treat both snapshot-bearing states as displayable:

```swift
let unavailableProfileIDs = Set(profiles.compactMap { profile -> String? in
    previousStates[profile.id]?.snapshot == nil ? profile.id : nil
})
```

- [ ] **Step 6: Merge reports per profile without deleting successful data**

Replace the old `preservingAvailableStates` special case with:

```swift
private func mergedSubscriptionUsageState(
    previous: AccountSubscriptionUsageState?,
    reported: AccountSubscriptionUsageState
) -> AccountSubscriptionUsageState {
    switch reported {
    case .available:
        return reported
    case .unavailable(let issue):
        guard let snapshot = previous?.snapshot else { return reported }
        return .stale(snapshot, issue)
    case .stale(let snapshot, let issue):
        return .stale(snapshot, issue)
    case .disabled, .managementKeyNotConfigured, .loading:
        return reported
    }
}
```

Apply it for every requested profile:

```swift
var didUpdateStates = false
var successfulSnapshots: [SubscriptionUsageSnapshot] = []
for profile in profiles {
    let reported = report.statesByProfileID[profile.id] ?? .unavailable(.transientFailure)
    let merged = mergedSubscriptionUsageState(
        previous: previousStates?[profile.id] ?? subscriptionUsageStates[profile.id],
        reported: reported
    )
    subscriptionUsageStates[profile.id] = merged
    if case .available(let snapshot) = reported {
        successfulSnapshots.append(snapshot)
    }
    didUpdateStates = true
}
if let latestSuccess = successfulSnapshots.map(\.fetchedAt).max() {
    lastSuccessfulSubscriptionUsageRefreshAt = latestSuccess
}
if didUpdateStates {
    persistSuccessfulSubscriptionUsageSnapshots()
}
```

Do not set the last-success timestamp from `report.fetchedAt` when every result is an error.

- [ ] **Step 7: Make automatic polling issue-aware for stale and unavailable states**

Replace `refreshableSubscriptionUsageProfiles()` with:

```swift
private func refreshableSubscriptionUsageProfiles() -> [AuthProfile] {
    authProfiles.filter { profile in
        guard isSubscriptionUsageEnabled(for: profile) else { return false }
        return !(subscriptionUsageStates[profile.id]?.stopsAutomaticPolling ?? false)
    }
}
```

Update scheduler switches:

```swift
switch state {
case .available, .loading:
    return true
case .stale(_, let issue), .unavailable(let issue):
    return !issue.stopsPolling
case .disabled, .managementKeyNotConfigured:
    return false
}
```

```swift
if case let .stale(_, issue) = state {
    return !issue.stopsPolling
}
if case let .unavailable(issue) = state {
    return !issue.stopsPolling
}
return false
```

Forced refresh continues using all enabled profiles, so terminal stale and unavailable accounts remain manually recoverable.

- [ ] **Step 8: Verify usage state, cache, and polling tests**

Run:

```bash
swift test --filter DashboardViewModelRefreshTests/testAutomaticUsageRefresh
swift test --filter DashboardViewModelRefreshTests/testManualUsageRefresh
swift test --filter DashboardViewModelRefreshTests/testNonRetriableProfile
swift test --filter DashboardViewModelRefreshTests/testTransientUsageFailure
swift test --filter SubscriptionUsageSnapshotCacheTests
```

Expected: PASS. Cache content survives terminal issues; automatic polling omits only terminal-issue profiles; force refresh includes them.

- [ ] **Step 9: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageSnapshotCacheTests.swift
```

If commits are authorized and self-contained:

```bash
git add -p Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageSnapshotCacheTests.swift
git diff --cached --check
git commit -m "fix: retain last successful usage after refresh errors"
```

---

### Task 11: Show Stale Usage With One Shared Warning Icon

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift`
- Create: `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift:209-263`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:120-181`

**Interfaces:**
- Consumes: `AccountSubscriptionUsageState`, snapshot `fetchedAt`, `BrandPalette.statusWarning`.
- Produces: `SubscriptionUsageDisplayState`, deterministic warning copy, and `SubscriptionUsageWarningIcon(issue:lastUpdatedAt:)`.

- [ ] **Step 1: Add failing display-mapping and copy tests**

Create `SubscriptionUsageWarningIconTests.swift`:

```swift
import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class SubscriptionUsageWarningIconTests: XCTestCase {
    func testStaleStateKeepsSnapshotAndAddsWarningPresentation() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        XCTAssertEqual(
            subscriptionUsageDisplayState(for: .stale(snapshot, .credentialExpired)),
            .snapshot(snapshot, warning: .credentialExpired)
        )
    }

    func testUnavailableWithoutSnapshotKeepsFullUnavailableMessage() {
        XCTAssertEqual(
            subscriptionUsageDisplayState(for: .unavailable(.credentialExpired)),
            .unavailable("Usage unavailable — Credential needs attention.")
        )
    }

    func testWarningMessageIncludesIssueAndDeterministicLastUpdatedAge() {
        let message = SubscriptionUsageWarningPresentation.message(
            issue: .credentialExpired,
            lastUpdatedAt: Date(timeIntervalSince1970: 60),
            now: Date(timeIntervalSince1970: 780)
        )

        XCTAssertEqual(message, "Credential needs attention. Showing usage last updated 12 minutes ago.")
    }
}
```

- [ ] **Step 2: Run the new test and verify missing presentation types**

Run:

```bash
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: FAIL because the common presentation does not exist.

- [ ] **Step 3: Implement the common display mapping and warning copy**

Create `SubscriptionUsageWarningIcon.swift`:

```swift
import CLIProxyManagerCore
import SwiftUI

enum SubscriptionUsageDisplayState: Equatable {
    case hidden
    case loading(String)
    case unavailable(String)
    case snapshot(SubscriptionUsageSnapshot, warning: SubscriptionUsageIssue?)
}

func subscriptionUsageDisplayState(
    for state: AccountSubscriptionUsageState
) -> SubscriptionUsageDisplayState {
    switch state {
    case .disabled, .managementKeyNotConfigured:
        .hidden
    case .loading:
        .loading("Checking subscription usage…")
    case .available(let snapshot):
        .snapshot(snapshot, warning: nil)
    case .stale(let snapshot, let issue):
        .snapshot(snapshot, warning: issue)
    case .unavailable(let issue):
        .unavailable("Usage unavailable — \(issue.message)")
    }
}

enum SubscriptionUsageWarningPresentation {
    static func message(
        issue: SubscriptionUsageIssue,
        lastUpdatedAt: Date,
        now: Date = .now
    ) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(lastUpdatedAt) / 60))
        let age = minutes == 0
            ? "just now"
            : "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        return "\(issue.message) Showing usage last updated \(age)."
    }
}

struct SubscriptionUsageWarningIcon: View {
    let issue: SubscriptionUsageIssue
    let lastUpdatedAt: Date

    var body: some View {
        let message = SubscriptionUsageWarningPresentation.message(
            issue: issue,
            lastUpdatedAt: lastUpdatedAt
        )
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BrandPalette.statusWarning)
            .help(message)
            .accessibilityLabel(Text(message))
    }
}
```

Menu bar still special-cases snapshotless `.unavailable(.proxyUnavailable)` as hidden; overlay still converts it to `Start the server to check usage`. Apply those policies before calling the shared general mapping.

- [ ] **Step 4: Render one warning beside the entire menu-bar graph**

Refactor the snapshot branch into an `HStack(alignment: .top)`:

```swift
case .snapshot(let snapshot, let warning):
    HStack(alignment: .top, spacing: 6) {
        snapshotUsage(snapshot)
        if let warning {
            SubscriptionUsageWarningIcon(
                issue: warning,
                lastUpdatedAt: snapshot.fetchedAt
            )
            .padding(.top, 1)
        }
    }
```

Move the existing empty-window and `ForEach` body into:

```swift
@ViewBuilder
private func snapshotUsage(_ snapshot: SubscriptionUsageSnapshot) -> some View {
    if snapshot.windows.isEmpty {
        Text("Usage details unavailable")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
    } else {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshot.windows) { window in
                usageWindow(window)
            }
        }
    }
}
```

The warning is outside `ForEach`, so it appears once per account.

- [ ] **Step 5: Apply the same structure to the overlay**

Use an `HStack(alignment: .top)` with `UsageOverlayProgressRow` content and the same `SubscriptionUsageWarningIcon`. Keep the overlay’s snapshotless proxy-unavailable server hint. Do not duplicate warning copy.

- [ ] **Step 6: Verify presentation and usage regressions**

Run:

```bash
swift test --filter SubscriptionUsageWarningIconTests
swift test --filter DashboardViewModelRefreshTests/testAutomaticUsageRefresh
swift test --filter DashboardViewModelRefreshTests/testManualUsageRefresh
```

Expected: PASS. The pure display test proves stale retains the graph model; both views compile against the exhaustive state switch.

- [ ] **Step 7: Prepare the review boundary**

Run:

```bash
git diff --check
git diff -- Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift
```

If commits are authorized and self-contained:

```bash
git add Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift
git add -p Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift
git diff --cached --check
git commit -m "feat: show stale usage with a warning icon"
```

---

### Task 12: Run Full Regression and Development Runtime Verification

**Files:**
- Verify all source and test files listed above.
- Verify generated artifact: `$HOME/.cliproxy-manager/dev/functions.zsh`.
- Verify development bundle: `build-development/CLIProxyManager.app`.

**Interfaces:**
- Consumes: completed implementation.
- Produces: evidence that tests, development build, model listing, shell routing, Direct isolation, round robin selection, and stale recovery meet the spec without generation requests.

- [ ] **Step 1: Run all focused suites together**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter ProxyModelClientTests
swift test --filter ClaudeModelResolverTests
swift test --filter CLIProxyManagerCommandTests
swift test --filter RoundRobinSelectionServiceTests
swift test --filter ShellFunctionRendererTests
swift test --filter ClaudeRoleRoutingOptionsTests
swift test --filter ProviderSettingsViewModelTests
swift test --filter ProviderSettingsSheetMetricsTests
swift test --filter DashboardViewModelRefreshTests
swift test --filter SubscriptionUsageSnapshotCacheTests
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: every command exits `0`.

- [ ] **Step 2: Run the complete package test suite**

Run:

```bash
swift test
```

Expected: all core and app tests PASS with zero failures.

- [ ] **Step 3: Check formatting artifacts and fixed-model leaks**

Run:

```bash
git diff --check
! grep -R "claude-work/claude-opus-4-7\|claude-personal/claude-sonnet-4-6" Sources/CLIProxyManagerCore/Shell
```

Expected: both commands exit `0`. Compatibility constants may still exist in `OAuthModelDefaults.swift`; no account-specific shell function contains them.

- [ ] **Step 4: Build the development app bundle and helpers**

Run:

```bash
make bundle CONFIGURATION=debug BUILD_DIR=build-development
```

Expected: `Bundled build-development/CLIProxyManager.app`, with executable helpers at:

```text
build-development/CLIProxyManager.app/Contents/Helpers/cpm
build-development/CLIProxyManager.app/Contents/Helpers/cliproxy-manager
```

- [ ] **Step 5: Verify the generated Claude OAuth shell function is dynamic**

Open the development app, save one Claude OAuth proxy account, and install shell functions. Then run:

```bash
grep -n "routing claude-models\|ANTHROPIC_DEFAULT_OPUS_MODEL\|ANTHROPIC_DEFAULT_SONNET_MODEL\|ANTHROPIC_DEFAULT_HAIKU_MODEL" "$HOME/.cliproxy-manager/dev/functions.zsh"
```

Expected: the Claude OAuth function invokes `routing claude-models '<profile-id>'`, forwards the three variables from `routing_env`, and does not contain a fixed Claude release ID.

- [ ] **Step 6: Compare scoped `/v1/models` with helper output without generating content**

Run:

```bash
DEV_CPM="build-development/CLIProxyManager.app/Contents/Helpers/cpm"
CONFIG="$HOME/.cliproxy-manager/dev/config.json"
read -r PROFILE_ID PORT <<EOF
$(/usr/bin/python3 - "$CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for profile in config.get("oauthCommandProfiles", []):
    if profile.get("provider") == "claude" and profile.get("connectionMode", "proxy") == "proxy" and profile.get("isEnabled", True):
        print(profile["id"], config["port"])
        break
PY
)
EOF
test -n "$PROFILE_ID"
test -n "$PORT"
"$DEV_CPM" routing claude-models "$PROFILE_ID"
```

Expected: exactly three shell assignments. Compare their prefixes and model IDs with:

```bash
curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:$PORT/v1/models" | /usr/bin/python3 -m json.tool
```

Expected: each assignment exists under the same selected account prefix, and Automatic matches the resolver’s `created`/version/string ordering.

- [ ] **Step 7: Verify Direct strips parent-shell overrides without a generation request**

Create a temporary fake `claude`, discover a Direct function name, and invoke only the generated shell wrapper:

```bash
TMP_BIN="$(mktemp -d /tmp/cpm-direct-check.XXXXXX)"
cat > "$TMP_BIN/claude" <<'SH'
#!/bin/zsh
env | grep '^ANTHROPIC_' | sort
SH
chmod +x "$TMP_BIN/claude"
DIRECT_COMMAND="$(/usr/bin/python3 - "$HOME/.cliproxy-manager/dev/config.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for profile in config.get("oauthCommandProfiles", []):
    if profile.get("provider") == "claude" and profile.get("connectionMode") == "direct" and profile.get("isEnabled", True):
        print(profile["commandName"])
        break
PY
)"
test -n "$DIRECT_COMMAND"
PATH="$TMP_BIN:$PATH" zsh -c '
  source "$1"
  export ANTHROPIC_BASE_URL=parent
  export ANTHROPIC_AUTH_TOKEN=parent
  export ANTHROPIC_API_KEY=parent
  export ANTHROPIC_DEFAULT_OPUS_MODEL=parent
  export ANTHROPIC_DEFAULT_SONNET_MODEL=parent
  export ANTHROPIC_DEFAULT_HAIKU_MODEL=parent
  "$2"
' check "$HOME/.cliproxy-manager/dev/functions.zsh" "$DIRECT_COMMAND"
rm -rf "$TMP_BIN"
```

Expected: no `ANTHROPIC_` line is printed. The fake executable prevents a generation request.

- [ ] **Step 8: Verify round robin routing output only**

Find an enabled Claude round-robin profile and invoke the helper repeatedly, without launching Claude:

```bash
ROUND_ROBIN_ID="$(/usr/bin/python3 - "$HOME/.cliproxy-manager/dev/config.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for profile in config.get("roundRobinProfiles", []):
    if profile.get("provider") == "claude" and profile.get("isEnabled"):
        print(profile["id"])
        break
PY
)"
test -n "$ROUND_ROBIN_ID"
for _ in 1 2 3 4; do
  "$DEV_CPM" routing next "$ROUND_ROBIN_ID"
done
```

Expected: every output contains one `CLIPROXY_ROUND_ROBIN_PROFILE` and three model assignments using that selected account’s prefix and saved policy. An unavailable manual selection exits non-zero instead of selecting another account.

- [ ] **Step 9: Verify stale usage recovery with tests and the development UI**

Run the deterministic state-machine tests once more:

```bash
swift test --filter DashboardViewModelRefreshTests/testAutomaticUsageRefreshKeepsSnapshotAndCacheAfterTerminalFailure
swift test --filter DashboardViewModelRefreshTests/testManualUsageRefresh
swift test --filter SubscriptionUsageWarningIconTests
```

Then use the development app with an existing successful Codex usage snapshot:

1. Confirm percentage bars are visible.
2. Reproduce the safe credential-error state used by the test environment or let the naturally intermittent credential issue occur; do not modify or revoke a production credential solely for this check.
3. Confirm bars and fetched timestamp remain visible.
4. Confirm one trailing warning triangle appears and its tooltip contains the issue plus last-success age.
5. Restore credential health and click manual refresh.
6. Confirm the warning disappears and the new snapshot replaces the old one.

Expected: no graph disappearance, no cache deletion, terminal automatic polling stops only for the affected profile, and manual refresh recovers it.

- [ ] **Step 10: Final review of scope and working-tree safety**

Run:

```bash
git status --short
git diff --check
git diff --stat
git diff -- Sources/CLIProxyManagerCore Sources/CLIProxyManagerApp Tests/CLIProxyManagerCoreTests Tests/CLIProxyManagerAppTests
```

Expected: only intended feature changes are present in addition to the pre-existing provider-routing work. No README, release, dependency, binary, signing, or generated local configuration file was changed by this plan.

- [ ] **Step 11: Prepare the final integration commit boundary**

Only if the user explicitly authorizes commits and all prerequisite baseline changes are already committed:

```bash
git add -p Sources/CLIProxyManagerCore Sources/CLIProxyManagerApp Tests/CLIProxyManagerCoreTests Tests/CLIProxyManagerAppTests
git diff --cached --check
git diff --cached --stat
git commit -m "feat: add dynamic Claude OAuth routing and stale usage"
```

Otherwise, leave changes unstaged and report the exact passing tests, development build path, runtime checks performed, and any checks skipped because the local account setup was unavailable.
