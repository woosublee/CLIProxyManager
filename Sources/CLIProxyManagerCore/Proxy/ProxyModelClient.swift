import Foundation

public struct ProxyModelClient: Sendable {
    private let httpClient: any HTTPClient
    private let localAPIKey: String

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), localAPIKey: String = "sk-dummy") {
        self.httpClient = httpClient
        self.localAPIKey = localAPIKey
    }

    public func models(port: Int) async throws -> [String] {
        try await sortedModels(port: port).map(\.id)
    }

    public func baseModels(port: Int) async throws -> [String] {
        uniqueBaseModels(from: try await models(port: port))
    }

    public func codexModelOptions(port: Int) async throws -> [CodexModelOption] {
        try await codexModelOptions(port: port, modelPrefix: nil)
    }

    public func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
        let prefix = modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await codexModelOptions(port: port, modelPrefix: prefix.isEmpty ? nil : prefix)
    }

    public func codexBaseModels(port: Int) async throws -> [String] {
        try await codexModelOptions(port: port).map(\.id)
    }

    public func codexBaseModels(port: Int, modelPrefix: String) async throws -> [String] {
        try await codexModelOptions(port: port, modelPrefix: modelPrefix).map(\.id)
    }

    public func claudeModelOptions(
        port: Int,
        modelPrefix: String
    ) async throws -> [ClaudeModelOption] {
        let prefix = modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw ClaudeModelDiscoveryError.emptyModelPrefix }

        var seen = Set<String>()
        var result: [ClaudeModelOption] = []
        for model in try await sortedModels(port: port) {
            guard let baseID = modelIdentifier(model.id, withoutRoutingPrefix: prefix),
                  baseID.lowercased().hasPrefix("claude-") else {
                continue
            }
            guard seen.insert(baseID).inserted else { continue }
            result.append(
                ClaudeModelOption(
                    id: baseID,
                    created: model.created.flatMap(Int.init(exactly:))
                )
            )
        }
        return result
    }

    private func codexModelOptions(port: Int, modelPrefix: String?) async throws -> [CodexModelOption] {
        let regularModels = try await sortedModels(port: port)
        let scopedIDs = uniqueCodexModelIDs(from: regularModels, modelPrefix: modelPrefix)

        let metadataByID: [String: CodexClientModelsResponse.Model]
        do {
            metadataByID = try await codexMetadata(port: port, modelPrefix: modelPrefix)
        } catch {
            metadataByID = [:]
        }

        return scopedIDs.map { id in
            guard let metadata = metadataByID[id.lowercased()] else { return CodexModelOption(id: id) }
            let supported = metadata.supportedReasoningLevels.compactMap { level -> AppConfig.CodexReasoning? in
                guard let reasoning = AppConfig.CodexReasoning(rawValue: level.effort), reasoning != .auto else {
                    return nil
                }
                return reasoning
            }.reduce(into: [AppConfig.CodexReasoning]()) { values, reasoning in
                if !values.contains(reasoning) {
                    values.append(reasoning)
                }
            }
            let defaultReasoning = metadata.defaultReasoningLevel.flatMap(AppConfig.CodexReasoning.init(rawValue:))
            let metadataSupportsFast = metadata.serviceTiers.contains { tier in
                tier.id?.caseInsensitiveCompare("priority") == .orderedSame
                    || tier.name?.caseInsensitiveCompare("Fast") == .orderedSame
            } || metadata.additionalSpeedTiers.contains { tier in
                tier.caseInsensitiveCompare("fast") == .orderedSame
            }
            return CodexModelOption(
                id: id,
                supportedReasoning: supported,
                defaultReasoning: defaultReasoning.flatMap { supported.contains($0) ? $0 : nil },
                supportsFastMode: metadataSupportsFast
                    || CodexModelOption.supportsFastModeFallback(for: id),
                contextWindow: metadata.contextWindow
            )
        }
    }

    private func sortedModels(port: Int) async throws -> [ModelsResponse.Model] {
        guard (1...65_535).contains(port) else {
            throw ProxyServiceError.invalidPort(port)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let data = try await httpClient.get(url, headers: ["Authorization": "Bearer \(localAPIKey)"])
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // Sort by `created` descending so callers naturally see newest first.
        return response.data.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
    }

    private func uniqueBaseModels(from identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for model in identifiers.map(baseModelName) {
            if seen.insert(model).inserted {
                result.append(model)
            }
        }

        return result
    }

    private func uniqueCodexModelIDs(
        from models: [ModelsResponse.Model],
        modelPrefix: String?
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for model in models {
            let identifier: String
            if let modelPrefix {
                guard let unprefixed = modelIdentifier(model.id, withoutRoutingPrefix: modelPrefix),
                      isCodexModelID(unprefixed, ownedBy: model.ownedBy),
                      !CodexFastMode.isManagedAlias(unprefixed) else {
                    continue
                }
                identifier = baseModelName(unprefixed)
            } else {
                guard isCodexModel(model), !CodexFastMode.isManagedAlias(model.id) else { continue }
                identifier = baseModelName(model.id)
            }
            let canonical = CodexFastMode.canonicalModel(from: identifier)
            if seen.insert(canonical).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    private func scopedModelID(_ identifier: String, modelPrefix: String?) -> String? {
        guard let modelPrefix else { return baseModelName(identifier) }
        guard let unprefixed = modelIdentifier(identifier, withoutRoutingPrefix: modelPrefix) else { return nil }
        return baseModelName(unprefixed)
    }

    private func codexMetadata(
        port: Int,
        modelPrefix: String?
    ) async throws -> [String: CodexClientModelsResponse.Model] {
        guard (1...65_535).contains(port) else {
            throw ProxyServiceError.invalidPort(port)
        }
        var components = URLComponents(string: "http://127.0.0.1:\(port)/v1/models")!
        components.queryItems = [URLQueryItem(name: "client_version", value: "0.144.0")]
        let data = try await httpClient.get(
            components.url!,
            headers: ["Authorization": "Bearer \(localAPIKey)"]
        )
        let response = try JSONDecoder().decode(CodexClientModelsResponse.self, from: data)
        var result: [String: CodexClientModelsResponse.Model] = [:]
        for model in response.models {
            guard !CodexFastMode.isManagedAlias(model.slug),
                  let id = scopedModelID(model.slug, modelPrefix: modelPrefix),
                  !CodexFastMode.isManagedAlias(id) else {
                continue
            }
            let lookupKey = id.lowercased()
            if result[lookupKey] == nil {
                result[lookupKey] = model
            }
        }
        return result
    }

    private func modelIdentifier(_ identifier: String, withoutRoutingPrefix prefix: String) -> String? {
        let routePrefix = "\(prefix)/"
        guard identifier.lowercased().hasPrefix(routePrefix.lowercased()) else { return nil }
        return String(identifier.dropFirst(routePrefix.count))
    }

    private func baseModelName(_ identifier: String) -> String {
        let baseName: String
        if let parenIndex = identifier.firstIndex(of: "(") {
            baseName = String(identifier[..<parenIndex])
        } else {
            baseName = identifier
        }
        return CodexFastMode.canonicalModel(from: baseName)
    }

    private func isCodexModel(_ model: ModelsResponse.Model) -> Bool {
        isCodexModelID(model.id, ownedBy: model.ownedBy)
    }

    private func isCodexModelID(_ id: String, ownedBy: String?) -> Bool {
        if let ownedBy = ownedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
           ownedBy.isEmpty == false {
            return ownedBy.caseInsensitiveCompare("openai") == .orderedSame
        }

        let id = id.lowercased()
        return id.hasPrefix("gpt-")
            || id.hasPrefix("codex-")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}

extension ProxyModelClient: ClaudeModelListing {}

private struct ModelsResponse: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
        var created: Int64?
        var ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case created
            case ownedBy = "owned_by"
        }
    }
}

private struct CodexClientModelsResponse: Decodable {
    var models: [Model]

    struct Model: Decodable {
        var slug: String
        var supportedReasoningLevels: [ReasoningLevel]
        var defaultReasoningLevel: String?
        var visibility: String?
        var serviceTiers: [ServiceTier]
        var additionalSpeedTiers: [String]
        var contextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case visibility
            case serviceTiers = "service_tiers"
            case additionalSpeedTiers = "additional_speed_tiers"
            case contextWindow = "context_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try container.decode(String.self, forKey: .slug)
            supportedReasoningLevels = try container.decodeIfPresent(
                [ReasoningLevel].self,
                forKey: .supportedReasoningLevels
            ) ?? []
            defaultReasoningLevel = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel)
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
            serviceTiers = try container.decodeIfPresent([ServiceTier].self, forKey: .serviceTiers) ?? []
            additionalSpeedTiers = try container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        }
    }

    struct ServiceTier: Decodable {
        var id: String?
        var name: String?
    }

    struct ReasoningLevel: Decodable {
        var effort: String
    }
}
