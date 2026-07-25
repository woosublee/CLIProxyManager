import XCTest
@testable import CLIProxyManagerCore

final class APIUsageAccountingTests: XCTestCase {
    func testClaudeAPIKeyRecordMapsToStableProfileAndPrefersResponseTier() {
        let record = makeRecord(provider: "claude", executor: "ClaudeExecutor", alias: "cpm-claude-api/claude-opus-5", authType: "apikey", responseTier: "standard")

        XCTAssertEqual(APIUsageRecordMapper().classify(record), .aggregate(APIUsageAggregateInput(
            timestamp: record.timestamp, profileID: "claude-api", provider: .claude,
            model: "claude-opus-5", effectiveServiceTier: "standard", pricingVariant: .standard,
            tokenBreakdown: record.tokenBreakdown, failed: false
        )))
    }

    func testCodexLongContextUsesStableProfileAndLongContextVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_001)

        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.profileID, "codex-api")
        XCTAssertEqual(input.provider, .openAI)
        XCTAssertEqual(input.pricingVariant, .standardLongContext)
    }

    func testLongContextBoundaryIsStrictlyGreaterThan272K() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_000)
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .standard)
    }

    func testGPT54MiniDoesNotUseLongContextVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.4-mini", alias: "cpm-codex-api/gpt-5.4-mini", inputTotal: 300_000)
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .standard)
    }

    func testAPIKeyAuthAliasesAreAcceptedAndOAuthIsIgnored() {
        for authType in ["apikey", "api_key", "api-key"] {
            guard case .aggregate = APIUsageRecordMapper().classify(makeRecord(authType: authType)) else {
                return XCTFail("Expected API key alias \(authType) to aggregate")
            }
        }
        XCTAssertEqual(APIUsageRecordMapper().classify(makeRecord(authType: "oauth")), .ignored)
    }

    func testEmptyAuthIndexCannotMapProviderAndRawValueIsNotStored() {
        let record = makeRecord(authIndex: "   ")
        XCTAssertFalse(record.hasAuthIndex)
        guard case let .issue(issue) = APIUsageRecordMapper().classify(record) else {
            return XCTFail("Expected mapping issue")
        }
        XCTAssertEqual(issue.reason, .unknownProviderMapping)
        XCTAssertFalse(Mirror(reflecting: record).children.compactMap(\.label).contains("authIndex"))
    }

    func testOnlyProviderMatchedManagedModelAliasesAreCanonicalized() {
        let managed = makeRecord(
            provider: "codex",
            executor: "CodexExecutor",
            model: "cpm-codex-api/gpt-5.6-sol-fast(xhigh)",
            alias: "cpm-codex-api/gpt-5.6-sol-fast(xhigh)"
        )
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(managed) else {
            return XCTFail("Expected aggregate")
        }
        XCTAssertEqual(input.model, "gpt-5.6-sol")

        for model in [
            "third-party/gpt-5.6-sol",
            "gpt-5.6-sol(fake)",
            "cpm-claude-api/gpt-5.6-sol"
        ] {
            let record = makeRecord(
                provider: "codex",
                executor: "CodexExecutor",
                model: model,
                alias: "cpm-codex-api/\(model)"
            )
            guard case let .aggregate(unknown) = APIUsageRecordMapper().classify(record) else {
                return XCTFail("Expected aggregate for \(model)")
            }
            XCTAssertEqual(unknown.model, model)
        }
    }

    func testPriorityLongContextIsPreservedAsUnsupportedVariant() {
        let record = makeRecord(provider: "codex", executor: "CodexExecutor", model: "gpt-5.6-sol", alias: "cpm-codex-api/gpt-5.6-sol", inputTotal: 272_001, responseTier: "priority")
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected aggregate") }
        XCTAssertEqual(input.pricingVariant, .priorityLongContext)
    }

    func testUnclassifiedAccountingBecomesIssueCount() {
        let record = makeRecord(quality: .unclassified)
        XCTAssertEqual(APIUsageRecordMapper().classify(record), .issue(APIUsageIssueInput(timestamp: record.timestamp, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting)))
    }

    func testInvalidV2InvariantBecomesIssueInsteadOfAggregate() {
        let record = makeInvalidRecord(totalTokens: 999)
        guard case let .issue(issue) = APIUsageRecordMapper().classify(record) else { return XCTFail("Expected issue") }
        XCTAssertEqual(issue.reason, .incompleteTokenAccounting)
    }

    func testUnsupportedAccountingVersionAndUnknownProviderBecomeTypedIssues() {
        var unsupportedObject = recordJSONObject()
        unsupportedObject["accounting_version"] = 3
        guard case let .issue(unsupported) = APIUsageRecordMapper().classify(decodeRecord(unsupportedObject)) else { return XCTFail("Expected issue") }
        XCTAssertEqual(unsupported.reason, .unsupportedAccountingVersion)

        let unknown = makeRecord(provider: "other", executor: "OtherExecutor", alias: "other/model")
        guard case let .issue(mapping) = APIUsageRecordMapper().classify(unknown) else { return XCTFail("Expected issue") }
        XCTAssertNil(mapping.profileID)
        XCTAssertEqual(mapping.reason, .unknownProviderMapping)
    }

    func testCompleteFailedRequestRemainsAnAggregate() {
        var object = recordJSONObject()
        object["failed"] = true
        guard case let .aggregate(input) = APIUsageRecordMapper().classify(decodeRecord(object)) else { return XCTFail("Expected aggregate") }
        XCTAssertTrue(input.failed)
        XCTAssertEqual(input.tokenBreakdown.totalTokens, 30)
    }
}

private func recordJSONObject(
    provider: String = "claude",
    executor: String = "ClaudeExecutor",
    model: String = "claude-opus-5",
    alias: String = "cpm-claude-api/claude-opus-5",
    authType: String = "apikey",
    authIndex: String = "auth-1",
    inputTotal: Int64 = 10,
    total: Int64? = nil,
    quality: APIUsageTokenAccountingQuality = .complete,
    responseTier: String? = nil
) -> [String: Any] {
    let isComplete = quality == .complete
    let resolvedTotal = total ?? (inputTotal + 20)
    let normalizedInput = isComplete ? inputTotal : 0
    let outputTotal = isComplete ? resolvedTotal - inputTotal : 0
    var object: [String: Any] = [
        "timestamp": "2026-07-25T01:02:03Z",
        "provider": provider,
        "executor_type": executor,
        "model": model,
        "alias": alias,
        "auth_type": authType,
        "auth_index": authIndex,
        "failed": false,
        "accounting_version": 2,
        "token_breakdown": [
            "schema_version": 2,
            "quality": quality.rawValue,
            "total_tokens": resolvedTotal,
            "input": ["total_tokens": normalizedInput, "uncached_tokens": normalizedInput, "cache_read_tokens": 0, "cache_write_tokens": 0],
            "output": ["total_tokens": outputTotal, "non_reasoning_tokens": outputTotal, "reasoning_tokens": 0],
            "unclassified_tokens": isComplete ? 0 : resolvedTotal
        ],
        "service_tier": "default"
    ]
    if let responseTier { object["response_service_tier"] = responseTier }
    return object
}

private func decodeRecord(_ object: [String: Any]) -> APIUsageQueueRecord {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(APIUsageQueueRecord.self, from: JSONSerialization.data(withJSONObject: object))
}

private func makeRecord(
    provider: String = "claude",
    executor: String = "ClaudeExecutor",
    model: String = "claude-opus-5",
    alias: String = "cpm-claude-api/claude-opus-5",
    authType: String = "apikey",
    authIndex: String = "auth-1",
    inputTotal: Int64 = 10,
    total: Int64? = nil,
    quality: APIUsageTokenAccountingQuality = .complete,
    responseTier: String? = nil
) -> APIUsageQueueRecord {
    decodeRecord(recordJSONObject(provider: provider, executor: executor, model: model, alias: alias, authType: authType, authIndex: authIndex, inputTotal: inputTotal, total: total, quality: quality, responseTier: responseTier))
}

private func makeInvalidRecord(totalTokens: Int64) -> APIUsageQueueRecord {
    var object = recordJSONObject()
    var breakdown = object["token_breakdown"] as! [String: Any]
    breakdown["total_tokens"] = totalTokens
    object["token_breakdown"] = breakdown
    return decodeRecord(object)
}
