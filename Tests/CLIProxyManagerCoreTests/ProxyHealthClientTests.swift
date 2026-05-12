import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyHealthClientTests: XCTestCase {
    func testStatusReturnsReadyWhenModelsEndpointResponds() async throws {
        let httpClient = StubHTTPClient(result: .success(Data("{}".utf8)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(httpClient.requests.map(\.url), [URL(string: "http://127.0.0.1:8317/v1/models")!])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 8317."
            )
        )
    }

    func testStatusSendsLocalAPIKeyHeader() async throws {
        let httpClient = StubHTTPClient(result: .success(Data("{}".utf8)))
        let client = ProxyHealthClient(httpClient: httpClient)

        _ = await client.status(port: 18_317)

        XCTAssertEqual(httpClient.requests.first?.url, URL(string: "http://127.0.0.1:18317/v1/models")!)
        XCTAssertEqual(httpClient.requests.first?.headers["Authorization"], "Bearer sk-dummy")
    }

    func testStatusReturnsErrorWhenModelsEndpointFails() async throws {
        let httpClient = StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(httpClient.requests.map(\.url), [URL(string: "http://127.0.0.1:8317/v1/models")!])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Stopped",
                message: ""
            )
        )
    }

    func testStatusReturnsWarningWhenModelsEndpointRejectsLocalAPIKey() async throws {
        let httpClient = StubHTTPClient(result: .failure(HTTPClientError.badStatus(401)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 18_317)

        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Authentication Needs Attention",
                message: "The server responded, but models could not be loaded with the sk-dummy local API key."
            )
        )
    }

    func testStatusReturnsWarningWhenServerRespondsWithUnexpectedBadStatus() async throws {
        let httpClient = StubHTTPClient(result: .failure(HTTPClientError.badStatus(500)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Response Error",
                message: "The server responded, but models could not be loaded. HTTP 500"
            )
        )
    }

    func testStatusReturnsTimeoutWhenHTTPClientDoesNotRespond() async throws {
        let client = ProxyHealthClient(httpClient: SlowHTTPClient(), timeout: 0.01)

        let status = await client.status(port: 8317)

        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI Response Timed Out",
                message: "The server did not respond in time."
            )
        )
    }

    func testStatusRejectsInvalidPort() async throws {
        let httpClient = StubHTTPClient(result: .success(Data("{}".utf8)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 0)

        XCTAssertEqual(httpClient.requests.map(\.url), [])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI Port Configuration Error",
                message: "Port must be between 1 and 65535."
            )
        )
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

private struct SlowHTTPClient: HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return Data()
    }
}
