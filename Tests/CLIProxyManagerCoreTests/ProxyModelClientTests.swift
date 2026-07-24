import XCTest
@testable import CLIProxyManagerCore

final class ProxyModelClientTests: XCTestCase {
    func testModelsFetchesModelIDsWithLocalAPIKeyHeader() async throws {
        let data = Data(#"{"data":[{"id":"gpt-5.5(xhigh)"},{"id":"gpt-5.5(medium)"}]}"#.utf8)
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.models(port: 18_317)

        XCTAssertEqual(models, ["gpt-5.5(xhigh)", "gpt-5.5(medium)"])
        XCTAssertEqual(httpClient.requests.first?.url, URL(string: "http://127.0.0.1:18317/v1/models")!)
        XCTAssertEqual(httpClient.requests.first?.headers["Authorization"], "Bearer sk-dummy")
    }

    func testModelsReturnsUniqueBaseModelNames() async throws {
        let data = Data(#"{"data":[{"id":"gpt-5.5(xhigh)"},{"id":"gpt-5.5(medium)"},{"id":"gpt-5.6"}]}"#.utf8)
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.baseModels(port: 18_317)

        XCTAssertEqual(models, ["gpt-5.5", "gpt-5.6"])
    }

    func testBaseModelsKeepsRoutingPrefixForGenericModelList() async throws {
        let data = Data(#"{"data":[{"id":"codex-work/gpt-5.5(xhigh)"},{"id":"codex-work/gpt-5.5(medium)"}]}"#.utf8)
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.baseModels(port: 18_317)

        XCTAssertEqual(models, ["codex-work/gpt-5.5"])
    }

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

    func testCodexBaseModelsTrustsExplicitOwnerBeforePrefixFallback() async throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id":"gpt-fake","owned_by":"anthropic","created":500},
                {"id":"o3-fake","owned_by":"google","created":400},
                {"id":"gpt-image-2","owned_by":"openai","created":300},
                {"id":"codex-auto-review","created":200}
              ]
            }
            """#.utf8
        )
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.codexBaseModels(port: 18_317)

        XCTAssertEqual(models, ["gpt-image-2", "codex-auto-review"])
    }

    func testCodexBaseModelsKeepsRoutingPrefixesInGlobalModelList() async throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id":"codex-work/gpt-5.5(xhigh)","created":500},
                {"id":"codex-personal/gpt-5.5(medium)","created":400},
                {"id":"codex-work/gpt-5.6","created":300}
              ]
            }
            """#.utf8
        )
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.codexBaseModels(port: 18_317)

        XCTAssertEqual(models, ["codex-work/gpt-5.5", "codex-personal/gpt-5.5", "codex-work/gpt-5.6"])
    }

    func testCodexBaseModelsWithModelPrefixReturnsOnlyThatAccountsModels() async throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id":"codex-work/gpt-5.6","created":500},
                {"id":"codex-personal/gpt-5.5","created":400},
                {"id":"codex-work/gpt-5.5(xhigh)","created":300}
              ]
            }
            """#.utf8
        )
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.codexBaseModels(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, ["gpt-5.6", "gpt-5.5"])
    }

    func testCodexBaseModelsWithModelPrefixMatchesPrefixCaseInsensitively() async throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id":"Codex-Work/gpt-5.6","created":500},
                {"id":"CODEX-PERSONAL/gpt-5.5","created":400},
                {"id":"codex-work/gpt-5.5(xhigh)","created":300}
              ]
            }
            """#.utf8
        )
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.codexBaseModels(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, ["gpt-5.6", "gpt-5.5"])
    }

    func testCodexBaseModelsPreservesNamespacedOpenAIModelIDs() async throws {
        let data = Data(
            #"""
            {
              "data": [
                {"id":"openai/gpt-5.5(xhigh)","owned_by":"openai","created":500},
                {"id":"openai/gpt-5.5(medium)","owned_by":"openai","created":400}
              ]
            }
            """#.utf8
        )
        let httpClient = StubHTTPClient(result: .success(data))
        let client = ProxyModelClient(httpClient: httpClient)

        let models = try await client.codexBaseModels(port: 18_317)

        XCTAssertEqual(models, ["openai/gpt-5.5"])
    }

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

    func testCodexModelOptionsApplyFastFallbackToRoutingPrefixedModels() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300},{"id":"codex-work/gpt-5.4-mini","owned_by":"openai","created":200},{"id":"codex-work/custom-model","owned_by":"openai","created":100}]}"#.utf8)
        let metadata = Data(#"{"models":[]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317)

        XCTAssertEqual(models.map(\.id), ["codex-work/gpt-5.6-sol", "codex-work/gpt-5.4-mini", "codex-work/custom-model"])
        XCTAssertEqual(models.map(\.supportsFastMode), [true, false, false])
    }

    func testCodexModelOptionsHideManagedFastAliases() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol-fast","owned_by":"openai","created":400},{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300}]}"#.utf8)
        let metadata = Data(#"{"models":[]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.6-sol", supportsFastMode: true)])
    }

    func testCodexModelOptionsIgnoreManagedAliasMetadata() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/gpt-5.6-sol","owned_by":"openai","created":300}]}"#.utf8)
        let metadata = Data(#"{"models":[{"slug":"codex-work/gpt-5.6-sol-fast","supported_reasoning_levels":[{"effort":"low"}],"additional_speed_tiers":["fast"]},{"slug":"codex-work/gpt-5.6-sol","supported_reasoning_levels":[{"effort":"xhigh"}]}]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, [
            CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.xhigh], defaultReasoning: nil, supportsFastMode: true)
        ])
    }

    func testCodexModelOptionsMatchMetadataCaseInsensitivelyAndPreserveRegularIDCasing() async throws {
        let regular = Data(#"{"data":[{"id":"codex-work/GPT-5.6-Sol","owned_by":"openai","created":300}]}"#.utf8)
        let metadata = Data(#"{"models":[{"slug":"CODEX-WORK/gpt-5.6-sol","supported_reasoning_levels":[{"effort":"high"}]}]}"#.utf8)
        let client = ProxyModelClient(httpClient: StubHTTPClient(results: [.success(regular), .success(metadata)]))

        let models = try await client.codexModelOptions(port: 18_317, modelPrefix: "codex-work")

        XCTAssertEqual(models, [
            CodexModelOption(id: "GPT-5.6-Sol", supportedReasoning: [.high], defaultReasoning: nil, supportsFastMode: true)
        ])
    }

    func testModelsRejectsInvalidPortBeforeRequestingModels() async throws {
        let httpClient = StubHTTPClient(result: .success(Data(#"{"data":[]}"#.utf8)))
        let client = ProxyModelClient(httpClient: httpClient)

        do {
            _ = try await client.models(port: 0)
            XCTFail("Expected invalid port error")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .invalidPort(0))
        }

        XCTAssertEqual(httpClient.requests.count, 0)
    }

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

        do {
            _ = try await client.claudeModelOptions(port: 18_317, modelPrefix: "   ")
            XCTFail("Expected empty model prefix error")
        } catch {
            XCTAssertEqual(error as? ClaudeModelDiscoveryError, .emptyModelPrefix)
        }
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testCodexModelOptionContextWindowDefaultsToNil() {
        let option = CodexModelOption(id: "gpt-5.6-sol")

        XCTAssertNil(option.contextWindow)
    }

    func testCodexModelOptionContextWindowCanBeSet() {
        let option = CodexModelOption(id: "gpt-5.6-sol", contextWindow: 372_000)

        XCTAssertEqual(option.contextWindow, 372_000)
    }
}

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
