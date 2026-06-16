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
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let result: Result<Data, Error>
    private let lock = NSLock()
    private var _requests: [(url: URL, headers: [String: String])] = []

    var requests: [(url: URL, headers: [String: String])] {
        lock.withLock { _requests }
    }

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _requests.append((url, headers)) }
        return try result.get()
    }
}
