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
