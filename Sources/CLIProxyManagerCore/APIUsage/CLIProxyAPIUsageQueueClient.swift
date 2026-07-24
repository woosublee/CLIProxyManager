import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CLIProxyAPIUsageQueueClient: APIUsageQueueFetching {
    private let keyStore: any SubscriptionUsageManagementKeyProviding
    private let transport: any ManagementAPIHTTPTransport

    public init() {
        self.init(
            keyStore: SubscriptionUsageManagementKeyFileStore(),
            transport: URLSessionManagementAPIHTTPTransport()
        )
    }

    init(
        keyStore: any SubscriptionUsageManagementKeyProviding,
        transport: any ManagementAPIHTTPTransport
    ) {
        self.keyStore = keyStore
        self.transport = transport
    }

    public func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        guard (1...65_535).contains(port) else {
            throw APIUsageQueueClientError.invalidPort
        }
        guard count > 0 else {
            throw APIUsageQueueClientError.invalidCount
        }
        guard keyStore.isConfigured(),
              let managementKey = try? keyStore.managementKey(),
              !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIUsageQueueClientError.managementKeyNotConfigured
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/v0/management/usage-queue"
        components.queryItems = [URLQueryItem(name: "count", value: String(count))]
        guard let url = components.url else {
            throw APIUsageQueueClientError.proxyUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw APIUsageQueueClientError.proxyUnavailable
        }

        guard (200..<300).contains(response.statusCode) else {
            throw error(forManagementStatus: response.statusCode)
        }

        do {
            return try makeDecoder().decode([APIUsageQueueRecord].self, from: data)
        } catch is DecodingError {
            throw APIUsageQueueClientError.schemaMismatch
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid usage timestamp")
            }
            return date
        }
        return decoder
    }

    private func error(forManagementStatus statusCode: Int) -> APIUsageQueueClientError {
        switch statusCode {
        case 401, 403:
            .managementKeyRejected
        case 404, 405, 501:
            .managementAPINotSupported
        case 429, 500...599:
            .transientFailure
        default:
            .proxyUnavailable
        }
    }
}
