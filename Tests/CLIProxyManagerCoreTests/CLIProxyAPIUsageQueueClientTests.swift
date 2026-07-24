import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIUsageQueueClientTests: XCTestCase {
    func testPopUsageUsesLocalManagementEndpointAndNarrowDecodeModel() async throws {
        let body = Data(#"""
        [{
          "timestamp":"2026-07-25T01:02:03Z",
          "provider":"claude",
          "executor_type":"ClaudeExecutor",
          "model":"claude-opus-5",
          "alias":"cpm-claude-api/claude-opus-5",
          "auth_type":"apikey",
          "auth_index":"auth-1",
          "api_key":"sk-ant-secret",
          "request_id":"req-secret",
          "failed":false,
          "accounting_version":2,
          "token_breakdown":{
            "schema_version":2,"quality":"complete","total_tokens":30,
            "input":{"total_tokens":10,"uncached_tokens":7,"cache_read_tokens":2,"cache_write_tokens":1},
            "output":{"total_tokens":20,"non_reasoning_tokens":15,"reasoning_tokens":5},
            "unclassified_tokens":0
          },
          "service_tier":"default",
          "response_service_tier":"standard",
          "fail":{"status_code":500,"body":"sensitive"},
          "response_headers":{"Authorization":["secret"]}
        }]
        """#.utf8)
        let transport = StubManagementTransport(data: body, statusCode: 200)
        let client = CLIProxyAPIUsageQueueClient(
            keyStore: StubManagementKeyProvider(key: "management-key"),
            transport: transport
        )

        let records = try await client.popUsage(port: 18_317, count: 200)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "claude-opus-5")
        XCTAssertTrue(records[0].hasAuthIndex)
        XCTAssertEqual(records[0].tokenBreakdown.input.cacheWriteTokens, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18317/v0/management/usage-queue?count=200")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer management-key")
        let decodedLabels = Set(Mirror(reflecting: records[0]).children.compactMap(\.label))
        XCTAssertTrue(decodedLabels.isDisjoint(with: ["apiKey", "requestID", "authIndex", "fail", "responseHeaders"]))
    }

    func testDecodeFailureDoesNotExposeRawBody() async {
        let transport = StubManagementTransport(data: Data(#"[{"api_key":"sk-secret"}]"#.utf8), statusCode: 200)
        let client = CLIProxyAPIUsageQueueClient(
            keyStore: StubManagementKeyProvider(key: "management-key"),
            transport: transport
        )

        do {
            _ = try await client.popUsage(port: 18_317, count: 200)
            XCTFail("Expected schema mismatch")
        } catch {
            XCTAssertEqual(error as? APIUsageQueueClientError, .schemaMismatch)
            XCTAssertFalse(String(describing: error).contains("sk-secret"))
        }
    }

    func testStatusCodesMapWithoutIncludingBody() async {
        for (status, expected) in [(401, .managementKeyRejected), (404, .managementAPINotSupported), (429, .transientFailure), (503, .transientFailure)] as [(Int, APIUsageQueueClientError)] {
            let transport = StubManagementTransport(data: Data(#"{"error":"sk-secret"}"#.utf8), statusCode: status)
            let client = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: "key"), transport: transport)
            do {
                _ = try await client.popUsage(port: 18_317, count: 200)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? APIUsageQueueClientError, expected)
                XCTAssertFalse(String(describing: error).contains("sk-secret"))
            }
        }
    }

    func testMissingManagementKeyAndInvalidArgumentsFailBeforeTransport() async {
        let transport = StubManagementTransport(data: Data("[]".utf8), statusCode: 200)
        let missingKeyClient = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: ""), transport: transport)
        do {
            _ = try await missingKeyClient.popUsage(port: 18_317, count: 200)
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? APIUsageQueueClientError, .managementKeyNotConfigured)
        }

        let client = CLIProxyAPIUsageQueueClient(keyStore: StubManagementKeyProvider(key: "key"), transport: transport)
        for (port, count, expected) in [(0, 200, .invalidPort), (18_317, 0, .invalidCount)] as [(Int, Int, APIUsageQueueClientError)] {
            do {
                _ = try await client.popUsage(port: port, count: count)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? APIUsageQueueClientError, expected)
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

private final class StubManagementTransport: ManagementAPIHTTPTransport, @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.data = data
        self.response = HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, response)
    }
}

private struct StubManagementKeyProvider: SubscriptionUsageManagementKeyProviding {
    let key: String
    func isConfigured() -> Bool { !key.isEmpty }
    func managementKey() throws -> String { key }
    func createManagementKeyIfNeeded() throws -> Bool { false }
    func setManagementKey(_: String) throws {}
    func deleteManagementKey() throws {}
}
