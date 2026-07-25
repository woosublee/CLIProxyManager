import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class APIPriceCatalogTests: XCTestCase {
    func testClaudeSonnetIntroductoryPriceEndsAtSeptemberBoundary() throws {
        let catalog = APIPriceCatalog.current
        let august = try XCTUnwrap(catalog.entry(
            provider: .claude,
            model: "claude-sonnet-5",
            serviceTier: "standard",
            variant: .standard,
            at: iso("2026-08-31T23:59:59Z")
        ))
        let september = try XCTUnwrap(catalog.entry(
            provider: .claude,
            model: "claude-sonnet-5",
            serviceTier: "standard",
            variant: .standard,
            at: iso("2026-09-01T00:00:00Z")
        ))

        XCTAssertEqual(august.rates.uncachedInputUSDPerMillion, Decimal(string: "2"))
        XCTAssertEqual(september.rates.uncachedInputUSDPerMillion, Decimal(string: "3"))
        XCTAssertNotEqual(august.effectiveFrom, september.effectiveFrom)
    }

    func testGPT56HasShortLongPriorityAndCacheWriteRates() throws {
        let catalog = APIPriceCatalog.current
        let short = try XCTUnwrap(catalog.entry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standard,
            at: iso("2026-07-25T12:00:00Z")
        ))
        let long = try XCTUnwrap(catalog.entry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standardLongContext,
            at: iso("2026-07-25T12:00:00Z")
        ))
        let priority = try XCTUnwrap(catalog.entry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "priority",
            variant: .priority,
            at: iso("2026-07-25T12:00:00Z")
        ))

        XCTAssertEqual(short.rates.cacheWriteUSDPerMillion, Decimal(string: "3.125"))
        XCTAssertEqual(long.rates.outputUSDPerMillion, Decimal(string: "22.5"))
        XCTAssertEqual(priority.rates.outputUSDPerMillion, Decimal(string: "30"))
        XCTAssertNil(catalog.entry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "priority",
            variant: .priorityLongContext,
            at: iso("2026-07-25T12:00:00Z")
        ))
    }

    func testCatalogDoesNotGuessUnknownModelFamily() {
        XCTAssertNil(APIPriceCatalog.current.entry(
            provider: .claude,
            model: "claude-opus-future",
            serviceTier: "standard",
            variant: .standard,
            at: Date()
        ))
    }

    func testClassificationDistinguishesUnknownModelTierAndVariant() {
        let catalog = APIPriceCatalog.current
        let at = iso("2026-07-25T12:00:00Z")

        XCTAssertEqual(catalog.classification(
            provider: .claude,
            model: "claude-opus-future",
            serviceTier: "standard",
            variant: .standard,
            at: at
        ), .unknownModel)
        XCTAssertEqual(catalog.classification(
            provider: .claude,
            model: "claude-opus-5",
            serviceTier: "priority",
            variant: .priority,
            at: at
        ), .unsupportedServiceTier)
        XCTAssertEqual(catalog.classification(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "priority",
            variant: .priorityLongContext,
            at: at
        ), .unknownPricingVariant)
    }

    func testExplicitClaudeDateSuffixAliasResolvesToBaseModel() throws {
        let entry = try XCTUnwrap(APIPriceCatalog.current.entry(
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            serviceTier: "standard",
            variant: .standard,
            at: iso("2026-07-25T12:00:00Z")
        ))

        XCTAssertEqual(entry.model, "claude-haiku-4-5")
    }

    func testCatalogRatesMatchSpecifiedModelsAndVariants() throws {
        let catalog = APIPriceCatalog.current
        let at = iso("2026-07-25T12:00:00Z")

        for expected in [
            ExpectedRate(.claude, "claude-fable-5", "standard", .standard, "10", "1", "12.5", "50"),
            ExpectedRate(.claude, "claude-opus-5", "standard", .standard, "5", "0.5", "6.25", "25"),
            ExpectedRate(.claude, "claude-opus-4-8", "standard", .standard, "5", "0.5", "6.25", "25"),
            ExpectedRate(.claude, "claude-opus-4-7", "standard", .standard, "5", "0.5", "6.25", "25"),
            ExpectedRate(.claude, "claude-opus-4-6", "standard", .standard, "5", "0.5", "6.25", "25"),
            ExpectedRate(.claude, "claude-opus-4-5", "standard", .standard, "5", "0.5", "6.25", "25"),
            ExpectedRate(.claude, "claude-sonnet-4-6", "standard", .standard, "3", "0.3", "3.75", "15"),
            ExpectedRate(.claude, "claude-sonnet-4-5", "standard", .standard, "3", "0.3", "3.75", "15"),
            ExpectedRate(.claude, "claude-haiku-4-5", "standard", .standard, "1", "0.1", "1.25", "5"),
            ExpectedRate(.openAI, "gpt-5.6-sol", "default", .standard, "5", "0.5", "6.25", "30"),
            ExpectedRate(.openAI, "gpt-5.6-sol", "default", .standardLongContext, "10", "1", "12.5", "45"),
            ExpectedRate(.openAI, "gpt-5.6-sol", "priority", .priority, "10", "1", "12.5", "60"),
            ExpectedRate(.openAI, "gpt-5.6-terra", "default", .standard, "2.5", "0.25", "3.125", "15"),
            ExpectedRate(.openAI, "gpt-5.6-terra", "default", .standardLongContext, "5", "0.5", "6.25", "22.5"),
            ExpectedRate(.openAI, "gpt-5.6-terra", "priority", .priority, "5", "0.5", "6.25", "30"),
            ExpectedRate(.openAI, "gpt-5.6-luna", "default", .standard, "1", "0.1", "1.25", "6"),
            ExpectedRate(.openAI, "gpt-5.6-luna", "default", .standardLongContext, "2", "0.2", "2.5", "9"),
            ExpectedRate(.openAI, "gpt-5.6-luna", "priority", .priority, "2", "0.2", "2.5", "12"),
            ExpectedRate(.openAI, "gpt-5.5", "default", .standard, "5", "0.5", nil, "30"),
            ExpectedRate(.openAI, "gpt-5.5", "default", .standardLongContext, "10", "1", nil, "45"),
            ExpectedRate(.openAI, "gpt-5.5", "priority", .priority, "12.5", "1.25", nil, "75"),
            ExpectedRate(.openAI, "gpt-5.5-pro", "default", .standard, "30", nil, nil, "180"),
            ExpectedRate(.openAI, "gpt-5.5-pro", "default", .standardLongContext, "60", nil, nil, "270"),
            ExpectedRate(.openAI, "gpt-5.4", "default", .standard, "2.5", "0.25", nil, "15"),
            ExpectedRate(.openAI, "gpt-5.4", "default", .standardLongContext, "5", "0.5", nil, "22.5"),
            ExpectedRate(.openAI, "gpt-5.4", "priority", .priority, "5", "0.5", nil, "30"),
            ExpectedRate(.openAI, "gpt-5.4-pro", "default", .standard, "30", nil, nil, "180"),
            ExpectedRate(.openAI, "gpt-5.4-pro", "default", .standardLongContext, "60", nil, nil, "270"),
            ExpectedRate(.openAI, "gpt-5.4-mini", "default", .standard, "0.75", "0.075", nil, "4.5"),
            ExpectedRate(.openAI, "gpt-5.4-mini", "priority", .priority, "1.5", "0.15", nil, "9"),
            ExpectedRate(.openAI, "gpt-5.4-nano", "default", .standard, "0.2", "0.02", nil, "1.25")
        ] {
            let entry = try XCTUnwrap(catalog.entry(
                provider: expected.provider,
                model: expected.model,
                serviceTier: expected.serviceTier,
                variant: expected.variant,
                at: at
            ), "Missing price for \(expected.model) \(expected.serviceTier) \(expected.variant)")
            XCTAssertEqual(entry.rates.uncachedInputUSDPerMillion, Decimal(string: expected.uncachedInput))
            XCTAssertEqual(entry.rates.cacheReadUSDPerMillion, decimal(expected.cacheRead))
            XCTAssertEqual(entry.rates.cacheWriteUSDPerMillion, decimal(expected.cacheWrite))
            XCTAssertEqual(entry.rates.outputUSDPerMillion, Decimal(string: expected.output))
        }
    }

    private func decimal(_ value: String?) -> Decimal? {
        value.flatMap { Decimal(string: $0) }
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private struct ExpectedRate {
    let provider: APIUsageProvider
    let model: String
    let serviceTier: String
    let variant: APIUsagePricingVariant
    let uncachedInput: String
    let cacheRead: String?
    let cacheWrite: String?
    let output: String

    init(
        _ provider: APIUsageProvider,
        _ model: String,
        _ serviceTier: String,
        _ variant: APIUsagePricingVariant,
        _ uncachedInput: String,
        _ cacheRead: String?,
        _ cacheWrite: String?,
        _ output: String
    ) {
        self.provider = provider
        self.model = model
        self.serviceTier = serviceTier
        self.variant = variant
        self.uncachedInput = uncachedInput
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }
}
