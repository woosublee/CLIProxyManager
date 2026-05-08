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
