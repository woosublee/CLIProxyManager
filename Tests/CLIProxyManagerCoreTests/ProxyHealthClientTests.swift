import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyHealthClientTests: XCTestCase {
    func testStatusReturnsReadyWhenModelsEndpointResponds() async throws {
        let httpClient = StubHTTPClient(result: .success(Data("{}".utf8)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(httpClient.requestedURLs, [URL(string: "http://127.0.0.1:8317/v1/models")!])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI 실행 중",
                message: "포트 8317에서 모델 목록을 불러올 수 있습니다."
            )
        )
    }

    func testStatusReturnsErrorWhenModelsEndpointFails() async throws {
        let httpClient = StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(httpClient.requestedURLs, [URL(string: "http://127.0.0.1:8317/v1/models")!])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI 중지됨",
                message: "앱에서 서버를 시작하세요."
            )
        )
    }

    func testStatusReturnsWarningWhenServerRespondsWithBadStatus() async throws {
        let httpClient = StubHTTPClient(result: .failure(HTTPClientError.badStatus(401)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 8317)

        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI 응답 오류",
                message: "서버가 응답했지만 모델 목록을 불러오지 못했습니다. HTTP 401"
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
                title: "CLIProxyAPI 응답 시간 초과",
                message: "서버가 시간 내에 응답하지 않았습니다."
            )
        )
    }

    func testStatusRejectsInvalidPort() async throws {
        let httpClient = StubHTTPClient(result: .success(Data("{}".utf8)))
        let client = ProxyHealthClient(httpClient: httpClient)

        let status = await client.status(port: 0)

        XCTAssertEqual(httpClient.requestedURLs, [])
        XCTAssertEqual(
            status,
            DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI 포트 설정 오류",
                message: "포트는 1부터 65535 사이여야 합니다."
            )
        )
    }
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let result: Result<Data, Error>
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] {
        lock.withLock { _requestedURLs }
    }

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func get(_ url: URL) async throws -> Data {
        lock.withLock { _requestedURLs.append(url) }
        return try result.get()
    }
}

private struct SlowHTTPClient: HTTPClient {
    func get(_ url: URL) async throws -> Data {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return Data()
    }
}
