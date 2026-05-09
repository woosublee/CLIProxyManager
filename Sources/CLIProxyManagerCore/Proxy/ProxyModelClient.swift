import Foundation

public struct ProxyModelClient: Sendable {
    private let httpClient: any HTTPClient
    private let localAPIKey: String

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), localAPIKey: String = "sk-dummy") {
        self.httpClient = httpClient
        self.localAPIKey = localAPIKey
    }

    public func models(port: Int) async throws -> [String] {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let data = try await httpClient.get(url, headers: ["Authorization": "Bearer \(localAPIKey)"])
        let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return response.data.map(\.id)
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
    }
}
