import Foundation

public struct APIPriceRates: Equatable, Sendable {
    public let uncachedInputUSDPerMillion: Decimal
    public let cacheReadUSDPerMillion: Decimal?
    public let cacheWriteUSDPerMillion: Decimal?
    public let outputUSDPerMillion: Decimal

    public init(
        uncachedInputUSDPerMillion: Decimal,
        cacheReadUSDPerMillion: Decimal?,
        cacheWriteUSDPerMillion: Decimal?,
        outputUSDPerMillion: Decimal
    ) {
        self.uncachedInputUSDPerMillion = uncachedInputUSDPerMillion
        self.cacheReadUSDPerMillion = cacheReadUSDPerMillion
        self.cacheWriteUSDPerMillion = cacheWriteUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
    }
}

public struct APIPriceEntry: Equatable, Sendable {
    public let provider: APIUsageProvider
    public let model: String
    public let serviceTier: String
    public let variant: APIUsagePricingVariant
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let rates: APIPriceRates

    public init(
        provider: APIUsageProvider,
        model: String,
        serviceTier: String,
        variant: APIUsagePricingVariant,
        effectiveFrom: Date,
        effectiveUntil: Date?,
        rates: APIPriceRates
    ) {
        self.provider = provider
        self.model = model
        self.serviceTier = serviceTier
        self.variant = variant
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.rates = rates
    }
}

public enum APIPriceClassification: Equatable, Sendable {
    case priced(APIPriceEntry)
    case unknownModel
    case unsupportedServiceTier
    case unknownPricingVariant
}

public struct APIPriceCatalog: Equatable, Sendable {
    public let version: Int
    public let entries: [APIPriceEntry]

    public init(version: Int, entries: [APIPriceEntry]) {
        self.version = version
        self.entries = entries
    }

    public func entry(
        provider: APIUsageProvider,
        model: String,
        serviceTier: String,
        variant: APIUsagePricingVariant,
        at: Date
    ) -> APIPriceEntry? {
        let canonicalModel = canonicalModel(model, provider: provider)
        let normalizedTier = normalized(serviceTier)

        return entries
            .filter {
                $0.provider == provider
                    && $0.model == canonicalModel
                    && $0.serviceTier == normalizedTier
                    && $0.variant == variant
                    && $0.effectiveFrom <= at
                    && ($0.effectiveUntil.map { at < $0 } ?? true)
            }
            .max { $0.effectiveFrom < $1.effectiveFrom }
    }

    public func classification(
        provider: APIUsageProvider,
        model: String,
        serviceTier: String,
        variant: APIUsagePricingVariant,
        at: Date
    ) -> APIPriceClassification {
        let canonicalModel = canonicalModel(model, provider: provider)
        let modelEntries = entries.filter { $0.provider == provider && $0.model == canonicalModel }
        guard !modelEntries.isEmpty else { return .unknownModel }

        let normalizedTier = normalized(serviceTier)
        let tierEntries = modelEntries.filter { $0.serviceTier == normalizedTier }
        guard !tierEntries.isEmpty else { return .unsupportedServiceTier }

        let variantEntries = tierEntries.filter { $0.variant == variant }
        guard !variantEntries.isEmpty else { return .unknownPricingVariant }

        if let entry = entry(provider: provider, model: model, serviceTier: serviceTier, variant: variant, at: at) {
            return .priced(entry)
        }
        return .unknownPricingVariant
    }

    // Sources:
    // https://platform.claude.com/docs/en/about-claude/pricing
    // https://openai.com/api/pricing/
    public static let current: APIPriceCatalog = {
        let baseline = utcDate("2026-07-25T00:00:00Z")
        let sonnetStandard = utcDate("2026-09-01T00:00:00Z")

        return APIPriceCatalog(version: 1, entries: [
            price(.claude, "claude-fable-5", "standard", .standard, from: baseline, input: "10", cacheRead: "1", cacheWrite: "12.5", output: "50"),
            price(.claude, "claude-opus-5", "standard", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "25"),
            price(.claude, "claude-opus-4-8", "standard", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "25"),
            price(.claude, "claude-opus-4-7", "standard", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "25"),
            price(.claude, "claude-opus-4-6", "standard", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "25"),
            price(.claude, "claude-opus-4-5", "standard", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "25"),
            price(.claude, "claude-sonnet-5", "standard", .standard, from: baseline, until: sonnetStandard, input: "2", cacheRead: "0.2", cacheWrite: "2.5", output: "10"),
            price(.claude, "claude-sonnet-5", "standard", .standard, from: sonnetStandard, input: "3", cacheRead: "0.3", cacheWrite: "3.75", output: "15"),
            price(.claude, "claude-sonnet-4-6", "standard", .standard, from: baseline, input: "3", cacheRead: "0.3", cacheWrite: "3.75", output: "15"),
            price(.claude, "claude-sonnet-4-5", "standard", .standard, from: baseline, input: "3", cacheRead: "0.3", cacheWrite: "3.75", output: "15"),
            price(.claude, "claude-haiku-4-5", "standard", .standard, from: baseline, input: "1", cacheRead: "0.1", cacheWrite: "1.25", output: "5"),

            price(.openAI, "gpt-5.6-sol", "default", .standard, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "30"),
            price(.openAI, "gpt-5.6-sol", "default", .standardLongContext, from: baseline, input: "10", cacheRead: "1", cacheWrite: "12.5", output: "45"),
            price(.openAI, "gpt-5.6-sol", "priority", .priority, from: baseline, input: "10", cacheRead: "1", cacheWrite: "12.5", output: "60"),
            price(.openAI, "gpt-5.6-terra", "default", .standard, from: baseline, input: "2.5", cacheRead: "0.25", cacheWrite: "3.125", output: "15"),
            price(.openAI, "gpt-5.6-terra", "default", .standardLongContext, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "22.5"),
            price(.openAI, "gpt-5.6-terra", "priority", .priority, from: baseline, input: "5", cacheRead: "0.5", cacheWrite: "6.25", output: "30"),
            price(.openAI, "gpt-5.6-luna", "default", .standard, from: baseline, input: "1", cacheRead: "0.1", cacheWrite: "1.25", output: "6"),
            price(.openAI, "gpt-5.6-luna", "default", .standardLongContext, from: baseline, input: "2", cacheRead: "0.2", cacheWrite: "2.5", output: "9"),
            price(.openAI, "gpt-5.6-luna", "priority", .priority, from: baseline, input: "2", cacheRead: "0.2", cacheWrite: "2.5", output: "12"),
            price(.openAI, "gpt-5.5", "default", .standard, from: baseline, input: "5", cacheRead: "0.5", output: "30"),
            price(.openAI, "gpt-5.5", "default", .standardLongContext, from: baseline, input: "10", cacheRead: "1", output: "45"),
            price(.openAI, "gpt-5.5", "priority", .priority, from: baseline, input: "12.5", cacheRead: "1.25", output: "75"),
            price(.openAI, "gpt-5.5-pro", "default", .standard, from: baseline, input: "30", output: "180"),
            price(.openAI, "gpt-5.5-pro", "default", .standardLongContext, from: baseline, input: "60", output: "270"),
            price(.openAI, "gpt-5.4", "default", .standard, from: baseline, input: "2.5", cacheRead: "0.25", output: "15"),
            price(.openAI, "gpt-5.4", "default", .standardLongContext, from: baseline, input: "5", cacheRead: "0.5", output: "22.5"),
            price(.openAI, "gpt-5.4", "priority", .priority, from: baseline, input: "5", cacheRead: "0.5", output: "30"),
            price(.openAI, "gpt-5.4-pro", "default", .standard, from: baseline, input: "30", output: "180"),
            price(.openAI, "gpt-5.4-pro", "default", .standardLongContext, from: baseline, input: "60", output: "270"),
            price(.openAI, "gpt-5.4-mini", "default", .standard, from: baseline, input: "0.75", cacheRead: "0.075", output: "4.5"),
            price(.openAI, "gpt-5.4-mini", "priority", .priority, from: baseline, input: "1.5", cacheRead: "0.15", output: "9"),
            price(.openAI, "gpt-5.4-nano", "default", .standard, from: baseline, input: "0.2", cacheRead: "0.02", output: "1.25")
        ])
    }()

    private static let claudeAliases = [
        "claude-haiku-4-5-20251001": "claude-haiku-4-5"
    ]

    private func canonicalModel(_ model: String, provider: APIUsageProvider) -> String {
        let normalizedModel = normalized(model)
        guard provider == .claude else { return normalizedModel }
        return Self.claudeAliases[normalizedModel] ?? normalizedModel
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func price(
        _ provider: APIUsageProvider,
        _ model: String,
        _ serviceTier: String,
        _ variant: APIUsagePricingVariant,
        from effectiveFrom: Date,
        until effectiveUntil: Date? = nil,
        input: String,
        cacheRead: String? = nil,
        cacheWrite: String? = nil,
        output: String
    ) -> APIPriceEntry {
        APIPriceEntry(
            provider: provider,
            model: model,
            serviceTier: serviceTier,
            variant: variant,
            effectiveFrom: effectiveFrom,
            effectiveUntil: effectiveUntil,
            rates: APIPriceRates(
                uncachedInputUSDPerMillion: decimal(input),
                cacheReadUSDPerMillion: cacheRead.map(decimal),
                cacheWriteUSDPerMillion: cacheWrite.map(decimal),
                outputUSDPerMillion: decimal(output)
            )
        )
    }

    private static func decimal(_ value: String) -> Decimal {
        Decimal(string: value)!
    }

    private static func utcDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
