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

    public func codexBaseModels(port: Int) async throws -> [String] {
        let models = try await sortedModels(port: port)
            .filter(isCodexModel)
            .map(\.id)
        return uniqueBaseModels(from: models)
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

    private func baseModelName(_ identifier: String) -> String {
        guard let parenIndex = identifier.firstIndex(of: "(") else { return identifier }
        return String(identifier[..<parenIndex])
    }

    private func isCodexModel(_ model: ModelsResponse.Model) -> Bool {
        if model.ownedBy?.lowercased() == "openai" {
            return true
        }

        let id = model.id.lowercased()
        return id.hasPrefix("gpt-")
            || id.hasPrefix("codex-")
            || id.hasPrefix("o1")
            || id.hasPrefix("o3")
            || id.hasPrefix("o4")
    }
}

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
