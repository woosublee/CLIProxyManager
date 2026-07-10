import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPISubscriptionQuotaClientTests: XCTestCase {
    func testClaudeUsageUsesFixedLoopbackManagementRequestsAndParsesWindows() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude-work.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":52.5,\"resets_at\":\"2026-07-10T14:30:00Z\"},\"seven_day\":{\"utilization\":31,\"resets_at\":\"2026-07-14T00:00:00Z\"}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_641_600) }
        )
        let profile = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 18_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Claude snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [52.5, 31])
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://127.0.0.1:18317/v0/management/auth-files",
            "http://127.0.0.1:18317/v0/management/api-call"
        ])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer management-secret")
        let apiCall = try XCTUnwrap(transport.requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: apiCall) as? [String: Any])
        XCTAssertEqual(body["auth_index"] as? String, "claude-index")
        XCTAssertEqual(body["url"] as? String, "https://api.anthropic.com/api/oauth/usage")
        let headers = try XCTUnwrap(body["header"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer $TOKEN$")
        XCTAssertFalse(String(decoding: apiCall, as: UTF8.self).contains("management-secret"))
    }

    func testCodexUsageParsesPrimaryAndSecondaryWindows() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":60,\"reset_at\":1783645200},\"secondary_window\":{\"used_percent\":20,\"reset_at\":1783904400}}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 18_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Codex snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60, 20])
        let apiCall = try XCTUnwrap(transport.requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: apiCall) as? [String: Any])
        XCTAssertEqual(body["url"] as? String, "https://chatgpt.com/backend-api/wham/usage")
    }

    func testMissingManagementKeyDoesNotSendNetworkRequests() async {
        let transport = StubSubscriptionUsageTransport(responses: [])
        let client = CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: nil), transport: transport)
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 18_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .managementKeyNotConfigured)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDisabledProfileDoesNotCallProviderEndpoint() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[]}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: "management-secret"), transport: transport)
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: true)

        let report = await client.fetchUsage(port: 18_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.credentialDisabled))
        XCTAssertEqual(transport.requests.count, 1)
    }
}

private final class StubManagementKeyStore: SubscriptionUsageManagementKeyProviding, @unchecked Sendable {
    private var key: String?

    init(key: String?) {
        self.key = key
    }

    func isConfigured() -> Bool { key != nil }
    func setManagementKey(_ value: String) throws { key = value }
    func deleteManagementKey() throws { key = nil }
    func managementKey() throws -> String {
        guard let key else { throw SecretStoreError.missingSecret("subscription-usage-management-key") }
        return key
    }
}

private final class StubSubscriptionUsageTransport: SubscriptionUsageHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let statusCode: Int
    }

    private let responses: [Result<Response, Error>]
    private var responseIndex = 0
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    init(responses: [Result<Response, Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let result = responseIndex < responses.count ? responses[responseIndex] : .failure(URLError(.badServerResponse))
        responseIndex += 1
        lock.unlock()
        let response = try result.get()
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!)
    }
}
