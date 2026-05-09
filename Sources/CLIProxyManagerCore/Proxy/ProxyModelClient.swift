import Foundation

public struct ProxyModelClient: Sendable {
    private let httpClient: any HTTPClient
    private let localAPIKey: String

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), localAPIKey: String = "sk-dummy") {
        self.httpClient = httpClient
        self.localAPIKey = localAPIKey
    }

    public func models(port: Int) async throws -> [String] {
        guard (1...65_535).contains(port) else {
            throw ProxyServiceError.invalidPort(port)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let data = try await httpClient.get(url, headers: ["Authorization": "Bearer \(localAPIKey)"])
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // Sort by `created` descending so callers naturally see newest first.
        let sorted = response.data.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        return sorted.map(\.id)
    }

    public func baseModels(port: Int) async throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for model in try await models(port: port).map(baseModelName) {
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
}

private struct ModelsResponse: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
        var created: Int64?
    }
}
