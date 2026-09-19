import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPISubscriptionQuotaClientTests: XCTestCase {
    func testClaudeUsageUsesFixedLoopbackManagementRequestsAndParsesWindows() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude-work.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":52.5,\"resets_at\":\"2026-07-10T14:30:00.123Z\"},\"seven_day\":{\"utilization\":31,\"resets_at\":\"2026-07-14T00:00:00Z\"}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_783_641_600) }
        )
        let profile = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Claude snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [52.5, 31])
        XCTAssertEqual(snapshot.windows.first?.resetAt, Date(timeIntervalSince1970: 1_783_693_800.123))
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://127.0.0.1:28317/v0/management/auth-files",
            "http://127.0.0.1:28317/v0/management/api-call"
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

    func testClaudeUsageSkipsEnabledExtraUsageWithoutUtilization() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":52},\"seven_day\":{\"utilization\":31},\"extra_usage\":{\"is_enabled\":true,\"utilization\":null}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Claude snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [52, 31])
    }

    func testClaudeUsageAllowsNullResetAt() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":52,\"resets_at\":null},\"seven_day\":{\"utilization\":31,\"resets_at\":\"2026-07-14T00:00:00Z\"}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Claude snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertNil(snapshot.windows.first?.resetAt)
    }

    func testClaudeUsageSkipsDisabledExtraUsage() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":52},\"extra_usage\":{\"is_enabled\":false}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Claude snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour"])
    }

    func testCodexUsageParsesPrimaryWindowWithoutSecondary() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":60,\"reset_at\":1783645200}}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Codex snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60])
    }

    func testCodexUsageParsesPrimaryAndSecondaryWindows() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":60,\"limit_window_seconds\":18000,\"reset_at\":1783645200},\"secondary_window\":{\"used_percent\":20,\"limit_window_seconds\":604800,\"reset_at\":1783904400}}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case let .available(snapshot)? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected available Codex snapshot")
        }
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [60, 20])
        XCTAssertEqual(snapshot.windows.map(\.limitWindowSeconds), [18_000, 604_800])
        let apiCall = try XCTUnwrap(transport.requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: apiCall) as? [String: Any])
        XCTAssertEqual(body["url"] as? String, "https://chatgpt.com/backend-api/wham/usage")
    }

    func testRequestedCodexResetCreditsUseAccountHeaderAndParseRedactedSnapshot() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex-work.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"reset_at\":1783645200}}}"}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"available_count\":2,\"total_earned_count\":4,\"credits\":[{\"title\":\"Full reset (earned)\",\"status\":\"available\",\"reset_type\":\"full\",\"expires_at\":\"2026-07-31T12:40:00.123Z\",\"granted_at\":\"2026-07-25T00:00:00Z\"}]}"}"#.utf8), statusCode: 200))
        ])
        let now = Date(timeIntervalSince1970: 1_784_100_000)
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport,
            now: { now }
        )
        let profile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            resetCreditsProfileIDs: [profile.id]
        )

        guard case let .available(snapshot)? = report.resetCreditsOutcomesByProfileID[profile.id] else {
            return XCTFail("Expected reset-credit snapshot")
        }
        XCTAssertEqual(snapshot.profileID, profile.id)
        XCTAssertEqual(snapshot.reportedAvailableCount, 2)
        XCTAssertEqual(snapshot.reportedTotalEarnedCount, 4)
        XCTAssertEqual(snapshot.credits.first?.title, "Full reset (earned)")
        XCTAssertEqual(snapshot.credits.first?.expiresAt, Date(timeIntervalSince1970: 1_785_501_600.123))
        XCTAssertEqual(snapshot.fetchedAt, now)

        let resetRequest = try XCTUnwrap(transport.requests.last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: resetRequest) as? [String: Any])
        XCTAssertEqual(body["auth_index"] as? String, "codex-index")
        XCTAssertEqual(body["method"] as? String, "GET")
        XCTAssertEqual(body["url"] as? String, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        let headers = try XCTUnwrap(body["header"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer $TOKEN$")
        XCTAssertEqual(headers["ChatGPT-Account-ID"], "acct_example")
        XCTAssertEqual(headers["originator"], "Codex Desktop")
        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertFalse(String(decoding: resetRequest, as: UTF8.self).contains("management-secret"))
    }

    func testResetOnlyCodexProfileSkipsUsageEndpointAndUsageState() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"available_count\":1,\"credits\":[{\"title\":\"Full reset\",\"status\":\"available\"}]}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertNil(report.statesByProfileID[profile.id])
        guard case .available? = report.resetCreditsOutcomesByProfileID[profile.id] else {
            return XCTFail("Expected reset credits to be available")
        }
        XCTAssertEqual(transport.requests.count, 2)
        let proxyURLs = try transport.requests.compactMap { request -> String? in
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return nil
            }
            return json["url"] as? String
        }
        XCTAssertEqual(proxyURLs, ["https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"])
        XCTAssertFalse(proxyURLs.contains("https://chatgpt.com/backend-api/wham/usage"))
    }

    func testInvalidPortReturnsTypedResetOutcomeWithoutNetworkRequest() async {
        let transport = StubSubscriptionUsageTransport(responses: [])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 0,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.transientFailure))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingManagementKeyReturnsTypedResetOutcomeWithoutNetworkRequest() async {
        let transport = StubSubscriptionUsageTransport(responses: [])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: nil),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.transientFailure))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAuthFilesAuthorizationFailureIsNotCredentialRejection() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{}"#.utf8), statusCode: 401))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.transientFailure))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [])
    }

    func testAuthFilesTransportFailureReturnsTypedResetOutcomeWithoutAttempt() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .failure(URLError(.cannotConnectToHost))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.transientFailure))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [])
    }

    func testAuthFilesSchemaFailureReturnsResetSchemaMismatchWithoutAttempt() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.schemaMismatch))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [])
    }

    func testMissingAccountIDRecordsDeferredResetDecision() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.accountIDUnavailable))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [profile.id])
    }

    func testResetEndpointSchemaFailureRecordsDispatchedAttempt() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            usageProfileIDs: [],
            resetCreditsProfileIDs: [profile.id]
        )

        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.schemaMismatch))
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [profile.id])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [])
    }

    func testUnselectedCodexProfileDoesNotCallResetCreditEndpoint() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            resetCreditsProfileIDs: []
        )

        XCTAssertTrue(report.resetCreditsOutcomesByProfileID.isEmpty)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testMissingAccountIDFailsOnlyResetCredits() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [profile],
            resetCreditsProfileIDs: [profile.id]
        )

        guard case .available? = report.statesByProfileID[profile.id] else {
            return XCTFail("Usage should remain available")
        }
        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.accountIDUnavailable))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testUsageFailureDoesNotDiscardResetCreditSuccess() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":500,"body":"{}"}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"available_count\":1,\"credits\":[{\"title\":\"Full reset\",\"status\":\"available\",\"expires_at\":\"2026-07-31T12:40:00Z\"}]}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_example", expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.transientFailure))
        guard case .available? = report.resetCreditsOutcomesByProfileID[profile.id] else {
            return XCTFail("Reset credits should succeed independently")
        }
    }

    func testMalformedResetCreditsDoNotDiscardUsageSuccess() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"codex-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"available_count\":1,\"credits\":[{\"status\":\"available\",\"expires_at\":\"not-a-date\"}]}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_example", expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

        guard case .available? = report.statesByProfileID[profile.id] else {
            return XCTFail("Usage should remain available")
        }
        XCTAssertEqual(report.resetCreditsOutcomesByProfileID[profile.id], .unavailable(.schemaMismatch))
    }

    func testClaudeProfileNeverRequestsResetCredits() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":10}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile], resetCreditsProfileIDs: [profile.id])

        XCTAssertTrue(report.resetCreditsOutcomesByProfileID.isEmpty)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testManagementAuthorizationFailureMapsToManagementKeyRejected() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data("{}".utf8), statusCode: 401))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.managementKeyRejected))
    }

    func testExpiredLocalProfileStillLetsCLIProxyAPIRefreshAndFetchUsage() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"active","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":12}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: nil,
            accountID: nil,
            expired: "2026-01-01T00:00:00Z",
            disabled: false
        )

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case .available? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected CLIProxyAPI to refresh the expired access token and return usage")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testClaudeProviderUnauthorizedResponseMapsToCredentialExpired() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":401,"body":"{}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.credentialExpired))
    }

    func testCredentialErrorStatusStillCallsProviderEndpointToAllowRefresh() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"error","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":7}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        guard case .available? = report.statesByProfileID[profile.id] else {
            return XCTFail("Expected provider API call to determine the current credential state")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testClaudeMalformedUsagePayloadMapsToSchemaMismatch() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[{"name":"claude.json","provider":"claude","auth_index":"claude-index","status":"ready","disabled":false}]}"#.utf8), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"five_hour\":{\"utilization\":\"not-a-number\"}}"}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(
            keyStore: StubManagementKeyStore(key: "management-secret"),
            transport: transport
        )
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.schemaMismatch))
    }

    func testMissingManagementKeyDoesNotSendNetworkRequests() async {
        let transport = StubSubscriptionUsageTransport(responses: [])
        let client = CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: nil), transport: transport)
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .managementKeyNotConfigured)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCooldownObservationSurvivesProviderUsageFailure() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: cooldownAuthFiles(), statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":429,"body":"{}"}"#.utf8), statusCode: 200))
        ])
        let report = await quotaClient(transport).fetchUsage(port: 28_317, profiles: [cooldownProfile])
        XCTAssertEqual(report.statesByProfileID[cooldownProfile.id], .unavailable(.transientFailure))
        let snapshot = try XCTUnwrap(report.cooldownStatesByProfileID[cooldownProfile.id]?.snapshot)
        XCTAssertEqual(snapshot.cooldowns.first?.reason, "quota")
        XCTAssertEqual(snapshot.cooldowns.first?.modelKey, "gpt-6-astra")
        XCTAssertEqual(snapshot.observedAt, Date(timeIntervalSince1970: 1_789_776_000))
        XCTAssertEqual(snapshot.cooldowns.first?.retryAt, Date(timeIntervalSince1970: 1_789_779_600.125))
    }

    func testCooldownUnsupportedEmptyAndMalformedAreDistinctWithoutBreakingUsage() async {
        for (field, expected) in [
            ("", "unsupported"), (",\"cooldowns\":null", "unsupported"),
            (",\"cooldowns\":[]", "empty"), (",\"cooldowns\":{}", "malformed"),
            (",\"cooldowns\":[{\"reason\":\"quota\"}]", "malformed")
        ] {
            let auth = Data("{\"files\":[{\"name\":\"codex.json\",\"provider\":\"codex\",\"auth_index\":\"fresh-index\",\"disabled\":false\(field)}]}".utf8)
            let transport = StubSubscriptionUsageTransport(responses: [
                .success(.init(data: auth, statusCode: 200)),
                .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
            ])
            let report = await quotaClient(transport).fetchUsage(port: 28_317, profiles: [cooldownProfile])
            XCTAssertNotNil(report.statesByProfileID[cooldownProfile.id]?.snapshot)
            let state = report.cooldownStatesByProfileID[cooldownProfile.id]
            switch expected {
            case "unsupported": XCTAssertEqual(state, .unsupported)
            case "empty": XCTAssertEqual(state?.snapshot?.cooldowns, [])
            default: XCTAssertEqual(state, .unavailable(.schemaMismatch))
            }
        }
    }

    func testResetQuotaUsesFreshUniqueCredentialAndOnlyLocalManagementEndpoint() async throws {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: cooldownAuthFiles(), statusCode: 200)),
            .success(.init(data: Data(#"{"status":"ok","auth_index":"fresh-index","models":["gpt-6-astra"]}"#.utf8), statusCode: 200))
        ])
        let result = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
        XCTAssertEqual(result, .reset)
        XCTAssertEqual(transport.requests.map { $0.url?.absoluteString }, [
            "http://127.0.0.1:28317/v0/management/auth-files",
            "http://127.0.0.1:28317/v0/management/reset-quota"
        ])
        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer management-secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["auth_index": "fresh-index"])
    }

    func testResetQuotaRefusesInvalidOrAmbiguousCredentialAndMalformedDiagnostics() async {
        for auth in [
            #"{"files":[]}"#,
            #"{"files":[{"name":"codex.json","provider":"claude","auth_index":"wrong","disabled":false}]}"#,
            #"{"files":[{"name":"codex.json","provider":"codex","auth_index":"","disabled":false}]}"#,
            #"{"files":[{"name":"codex.json","provider":"codex","auth_index":"a","disabled":true}]}"#,
            #"{"files":[{"name":"codex.json","provider":"codex","auth_index":"a","disabled":false,"status":"expired"}]}"#,
            #"{"files":[{"name":"codex.json","provider":"codex","auth_index":"a","disabled":false},{"name":"codex.json","provider":"codex","auth_index":"b","disabled":false}]}"#,
            #"{"files":[{"name":"codex.json","provider":"codex","auth_index":"a","disabled":false,"cooldowns":{}}]}"#
        ] {
            let transport = StubSubscriptionUsageTransport(responses: [.success(.init(data: Data(auth.utf8), statusCode: 200))])
            do {
                _ = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
                XCTFail("Invalid credential must not be reset")
            } catch {}
            XCTAssertEqual(transport.requests.map(\.httpMethod), ["GET"])
        }
    }

    func testResetQuotaChecksAuthorizationAgainAfterLookup() async {
        let transport = StubSubscriptionUsageTransport(responses: [.success(.init(data: cooldownAuthFiles(), statusCode: 200))])
        let authorization = ResetAuthorizationGate()
        do {
            _ = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { await authorization.allowOnce() })
            XCTFail("Invalidated operation must be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["GET"])
    }

    func testResetQuotaDoesNotPostForObservedEmptyOrNonQuotaCooldowns() async throws {
        for cooldowns in ["[]", #"[{"scope":"credential","reason":"unauthorized","retry_at":"2026-09-19T01:00:00Z","remaining_seconds":3600}]"#] {
            let transport = StubSubscriptionUsageTransport(responses: [.success(.init(data: cooldownAuthFiles(cooldowns: cooldowns), statusCode: 200))])
            let result = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
            guard case .notNeeded = result else { return XCTFail("Must leave non-quota state untouched") }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testResetQuotaSupportsLegacyAndRejectsFailedOrMismatchedAcknowledgment() async throws {
        let legacy = Data(#"{"files":[{"name":"codex.json","provider":"codex","auth_index":"fresh-index","disabled":false}]}"#.utf8)
        for (status, body, succeeds) in [
            (200, #"{"status":"ok","auth_index":"fresh-index"}"#, true),
            (200, #"{"status":"ok","auth_index":"other-index"}"#, false),
            (200, "{}", false), (401, "{}", false), (404, "{}", false),
            (429, "{}", false), (503, "{}", false)
        ] {
            let transport = StubSubscriptionUsageTransport(responses: [
                .success(.init(data: legacy, statusCode: 200)),
                .success(.init(data: Data(body.utf8), statusCode: status))
            ])
            do {
                let result = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
                XCTAssertTrue(succeeds)
                XCTAssertEqual(result, .reset)
            } catch { XCTAssertFalse(succeeds) }
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testResetQuotaDistinguishesRemovedCredentialFromUnsupportedEndpoint() async {
        for (body, expected) in [
            (#"{"error":"auth not found"}"#, SubscriptionUsageIssue.authFileNotMatched),
            ("404 page not found", .managementAPINotSupported)
        ] {
            let transport = StubSubscriptionUsageTransport(responses: [
                .success(.init(data: cooldownAuthFiles(), statusCode: 200)),
                .success(.init(data: Data(body.utf8), statusCode: 404))
            ])
            do {
                _ = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
                XCTFail("Missing credential or endpoint must fail")
            } catch {
                XCTAssertEqual(error as? AccountQuotaResetError, .management(expected))
            }
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testResetQuotaRejectsMalformedAcknowledgmentAsSchemaMismatch() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: cooldownAuthFiles(), statusCode: 200)),
            .success(.init(data: Data("not JSON".utf8), statusCode: 200))
        ])
        do {
            _ = try await quotaClient(transport).resetQuota(port: 28_317, profile: cooldownProfile, authorize: { true })
            XCTFail("Malformed acknowledgment must not be accepted")
        } catch {
            XCTAssertEqual(error as? AccountQuotaResetError, .management(.schemaMismatch))
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testCooldownRejectsBooleanDurationWithoutDiscardingUsage() async {
        let auth = cooldownAuthFiles(cooldowns: #"[{"scope":"credential","reason":"quota","retry_at":"2026-09-19T01:00:00Z","remaining_seconds":true}]"#)
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: auth, statusCode: 200)),
            .success(.init(data: Data(#"{"status_code":200,"body":"{\"rate_limit\":{\"primary_window\":{\"used_percent\":20}}}"}"#.utf8), statusCode: 200))
        ])
        let report = await quotaClient(transport).fetchUsage(port: 28_317, profiles: [cooldownProfile])
        XCTAssertEqual(report.cooldownStatesByProfileID[cooldownProfile.id], .unavailable(.schemaMismatch))
        XCTAssertNotNil(report.statesByProfileID[cooldownProfile.id]?.snapshot)
    }

    func testResetQuotaDoesNotRequestWithMissingKeyInvalidPortOrDisabledProfile() async {
        for (port, key, disabled) in [(0, "key", false), (28_317, "", false), (28_317, "key", true)] {
            let transport = StubSubscriptionUsageTransport(responses: [])
            let client = CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: key), transport: transport)
            let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: disabled)
            do {
                _ = try await client.resetQuota(port: port, profile: profile, authorize: { true })
                XCTFail("Preflight should reject invalid input")
            } catch {}
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    private var cooldownProfile: AuthProfile {
        AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
    }

    private func quotaClient(_ transport: StubSubscriptionUsageTransport) -> CLIProxyAPISubscriptionQuotaClient {
        CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: "management-secret"), transport: transport)
    }

    private func cooldownAuthFiles(cooldowns: String = #"[{"scope":"model","model_key":"gpt-6-astra","reason":"quota","retry_at":"2026-09-19T01:00:00.125Z","remaining_seconds":3600}]"#) -> Data {
        Data("{\"observed_at\":\"2026-09-19T00:00:00Z\",\"files\":[{\"name\":\"codex.json\",\"provider\":\"codex\",\"auth_index\":\"fresh-index\",\"status\":\"ready\",\"disabled\":false,\"cooldowns\":\(cooldowns)}]}".utf8)
    }

    func testDisabledProfileDoesNotCallProviderEndpoint() async {
        let transport = StubSubscriptionUsageTransport(responses: [
            .success(.init(data: Data(#"{"files":[]}"#.utf8), statusCode: 200))
        ])
        let client = CLIProxyAPISubscriptionQuotaClient(keyStore: StubManagementKeyStore(key: "management-secret"), transport: transport)
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: true)

        let report = await client.fetchUsage(port: 28_317, profiles: [profile])

        XCTAssertEqual(report.statesByProfileID[profile.id], .unavailable(.credentialDisabled))
        XCTAssertEqual(transport.requests.count, 1)
    }
}

private actor ResetAuthorizationGate {
    private var used = false
    func allowOnce() -> Bool {
        defer { used = true }
        return !used
    }
}

private final class StubManagementKeyStore: SubscriptionUsageManagementKeyProviding, @unchecked Sendable {
    private var key: String?

    init(key: String?) {
        self.key = key
    }

    func isConfigured() -> Bool { key != nil }
    func createManagementKeyIfNeeded() throws -> Bool {
        guard key == nil else { return false }
        key = "generated-management-key"
        return true
    }
    func setManagementKey(_ value: String) throws { key = value }
    func deleteManagementKey() throws { key = nil }
    func managementKey() throws -> String {
        guard let key else { throw SecretStoreError.missingSecret("subscription-usage-management-key") }
        return key
    }
}

private final class StubSubscriptionUsageTransport: ManagementAPIHTTPTransport, @unchecked Sendable {
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
        let result = lock.withLock { () -> Result<Response, Error> in
            requests.append(request)
            defer { responseIndex += 1 }
            return responseIndex < responses.count ? responses[responseIndex] : .failure(URLError(.badServerResponse))
        }
        let response = try result.get()
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!)
    }
}
