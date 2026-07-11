import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol SubscriptionUsageHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSubscriptionUsageHTTPTransport: SubscriptionUsageHTTPTransport {
    private let session: URLSession

    init(session: URLSession = Self.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SubscriptionUsageTransportError.invalidResponse
        }
        return (data, response)
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum SubscriptionUsageTransportError: Error {
    case invalidResponse
}

public struct CLIProxyAPISubscriptionQuotaClient: SubscriptionQuotaFetching {
    private let keyStore: any SubscriptionUsageManagementKeyProviding
    private let transport: any SubscriptionUsageHTTPTransport
    private let now: @Sendable () -> Date

    public init() {
        self.init(
            keyStore: SubscriptionUsageManagementKeyFileStore(),
            transport: URLSessionSubscriptionUsageHTTPTransport(),
            now: { Date() }
        )
    }

    init(
        keyStore: any SubscriptionUsageManagementKeyProviding,
        transport: any SubscriptionUsageHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.transport = transport
        self.now = now
    }

    public func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        let fetchedAt = now()
        guard (1...65_535).contains(port) else {
            return report(for: profiles, state: .unavailable(.proxyUnavailable), fetchedAt: fetchedAt)
        }
        guard keyStore.isConfigured(), let managementKey = try? keyStore.managementKey() else {
            return report(for: profiles, state: .managementKeyNotConfigured, fetchedAt: fetchedAt)
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)/v0/management")!
        let authFilesResponse: (data: Data, statusCode: Int)
        do {
            authFilesResponse = try await sendManagementRequest(
                url: baseURL.appendingPathComponent("auth-files"),
                method: "GET",
                managementKey: managementKey,
                body: nil
            )
        } catch {
            return report(for: profiles, state: .unavailable(.proxyUnavailable), fetchedAt: fetchedAt)
        }
        guard (200..<300).contains(authFilesResponse.statusCode) else {
            return report(for: profiles, state: .unavailable(issue(forManagementStatus: authFilesResponse.statusCode)), fetchedAt: fetchedAt)
        }

        let credentialRecords: [ManagedCredential]
        do {
            credentialRecords = try decodeCredentialRecords(authFilesResponse.data)
        } catch {
            return report(for: profiles, state: .unavailable(.schemaMismatch), fetchedAt: fetchedAt)
        }

        var states: [String: AccountSubscriptionUsageState] = [:]
        for profile in profiles {
            if profile.disabled {
                states[profile.id] = .unavailable(.credentialDisabled)
                continue
            }
            if isExpired(profile) {
                states[profile.id] = .unavailable(.credentialExpired)
                continue
            }
            guard let credential = credentialRecords.first(where: {
                $0.name == profile.fileName && $0.provider == profile.type.rawValue
            }) else {
                states[profile.id] = .unavailable(.authFileNotMatched)
                continue
            }
            if credential.disabled || credential.status == "disabled" {
                states[profile.id] = .unavailable(.credentialDisabled)
                continue
            }
            if credential.status == "expired" || credential.status == "error" {
                states[profile.id] = .unavailable(.credentialExpired)
                continue
            }
            guard !credential.authIndex.isEmpty else {
                states[profile.id] = .unavailable(.authFileNotMatched)
                continue
            }

            states[profile.id] = await fetchUsage(
                for: profile,
                credential: credential,
                managementBaseURL: baseURL,
                managementKey: managementKey,
                fetchedAt: fetchedAt
            )
        }

        return SubscriptionUsageReport(statesByProfileID: states, fetchedAt: fetchedAt)
    }

    private func fetchUsage(
        for profile: AuthProfile,
        credential: ManagedCredential,
        managementBaseURL: URL,
        managementKey: String,
        fetchedAt: Date
    ) async -> AccountSubscriptionUsageState {
        let requestBody: Data
        do {
            requestBody = try apiCallRequest(for: profile.type, authIndex: credential.authIndex)
        } catch {
            return .unavailable(.providerContractUnsupported)
        }

        do {
            let response = try await sendManagementRequest(
                url: managementBaseURL.appendingPathComponent("api-call"),
                method: "POST",
                managementKey: managementKey,
                body: requestBody
            )
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(issue(forManagementStatus: response.statusCode))
            }
            let apiResponse: APICallResponse
            do {
                apiResponse = try decodeAPICallResponse(response.data)
            } catch {
                return .unavailable(.schemaMismatch)
            }
            if apiResponse.statusCode == 401 || apiResponse.statusCode == 403 {
                return .unavailable(.credentialExpired)
            }
            if apiResponse.statusCode == 404 || apiResponse.statusCode == 405 || apiResponse.statusCode == 501 {
                return .unavailable(.providerContractUnsupported)
            }
            if apiResponse.statusCode == 429 || apiResponse.statusCode >= 500 {
                return .unavailable(.transientFailure)
            }
            guard (200..<300).contains(apiResponse.statusCode) else {
                return .unavailable(.transientFailure)
            }

            do {
                let windows = try decodeWindows(from: apiResponse.body, provider: profile.type)
                return .available(SubscriptionUsageSnapshot(
                    profileID: profile.id,
                    provider: profile.type,
                    windows: windows,
                    fetchedAt: fetchedAt
                ))
            } catch {
                return .unavailable(.schemaMismatch)
            }
        } catch {
            return .unavailable(.transientFailure)
        }
    }

    private func report(
        for profiles: [AuthProfile],
        state: AccountSubscriptionUsageState,
        fetchedAt: Date
    ) -> SubscriptionUsageReport {
        SubscriptionUsageReport(
            statesByProfileID: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, state) }),
            fetchedAt: fetchedAt
        )
    }

    private func sendManagementRequest(
        url: URL,
        method: String,
        managementKey: String,
        body: Data?
    ) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        return (data, response.statusCode)
    }

    private func apiCallRequest(for provider: AuthProfileType, authIndex: String) throws -> Data {
        let details: (url: String, method: String, header: [String: String])
        switch provider {
        case .claude:
            details = (
                "https://api.anthropic.com/api/oauth/usage",
                "GET",
                [
                    "Authorization": "Bearer $TOKEN$",
                    "Accept": "application/json",
                    "anthropic-version": "2023-06-01",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/1.0"
                ]
            )
        case .codex:
            details = (
                "https://chatgpt.com/backend-api/wham/usage",
                "GET",
                [
                    "Authorization": "Bearer $TOKEN$",
                    "Accept": "application/json",
                    "User-Agent": "codex-cli/1.0"
                ]
            )
        }
        return try JSONSerialization.data(withJSONObject: [
            "auth_index": authIndex,
            "method": details.method,
            "url": details.url,
            "header": details.header
        ], options: [.sortedKeys])
    }

    private func decodeCredentialRecords(_ data: Data) throws -> [ManagedCredential] {
        try JSONDecoder().decode(AuthFilesResponse.self, from: data).files.map(ManagedCredential.init)
    }

    private func decodeAPICallResponse(_ data: Data) throws -> APICallResponse {
        let response = try JSONDecoder().decode(APICallResponsePayload.self, from: data)
        guard let bodyData = response.body.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid body"))
        }
        return APICallResponse(statusCode: response.statusCode, body: bodyData)
    }

    private func decodeWindows(from data: Data, provider: AuthProfileType) throws -> [UsageWindow] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid quota object")) }
        switch provider {
        case .claude:
            return try decodeClaudeWindows(object)
        case .codex:
            return try decodeCodexWindows(object)
        }
    }

    private func decodeClaudeWindows(_ object: [String: Any]) throws -> [UsageWindow] {
        let specs: [(String, String)] = [
            ("five_hour", "5h"),
            ("seven_day", "7d"),
            ("seven_day_sonnet", "7d Sonnet"),
            ("seven_day_opus", "7d Opus"),
            ("extra_usage", "Extra usage")
        ]
        let windows = try specs.compactMap { key, label -> UsageWindow? in
            guard let raw = object[key] as? [String: Any] else { return nil }
            if key == "extra_usage" {
                if let enabled = raw["is_enabled"] as? Bool, !enabled { return nil }
                guard let utilization = number(raw["utilization"]), (0...100).contains(utilization) else {
                    return nil
                }
                return UsageWindow(id: key, label: label, usedPercent: utilization, resetAt: try resetDate(raw["resets_at"]))
            }
            guard let utilization = number(raw["utilization"]), (0...100).contains(utilization) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid utilization"))
            }
            return UsageWindow(id: key, label: label, usedPercent: utilization, resetAt: try resetDate(raw["resets_at"]))
        }
        guard !windows.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No Claude windows")) }
        return windows
    }

    private func decodeCodexWindows(_ object: [String: Any]) throws -> [UsageWindow] {
        guard let rateLimit = object["rate_limit"] as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing rate limit"))
        }
        let specs: [(String, String, String)] = [
            ("primary_window", "Primary", "primary"),
            ("secondary_window", "Secondary", "secondary")
        ]
        let windows = try specs.compactMap { key, label, id -> UsageWindow? in
            guard let raw = rateLimit[key] as? [String: Any] else { return nil }
            guard let usage = number(raw["used_percent"]), (0...100).contains(usage) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Codex usage"))
            }
            return UsageWindow(
                id: id,
                label: label,
                usedPercent: usage,
                resetAt: try resetDate(raw["reset_at"]),
                limitWindowSeconds: number(raw["limit_window_seconds"])
            )
        }
        guard !windows.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No Codex windows")) }
        return windows
    }

    private func resetDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) {
                return date
            }
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractionalFormatter.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid reset date"))
            }
            return date
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid reset type"))
    }

    private func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private func issue(forManagementStatus statusCode: Int) -> SubscriptionUsageIssue {
        switch statusCode {
        case 401, 403: .managementKeyRejected
        case 404, 405, 501: .managementAPINotSupported
        case 429, 500...599: .transientFailure
        default: .proxyUnavailable
        }
    }

    private func isExpired(_ profile: AuthProfile) -> Bool {
        guard let expiration = profile.expired,
              let date = ISO8601DateFormatter().date(from: expiration) else { return false }
        return date <= now()
    }
}

private struct AuthFilesResponse: Decodable {
    let files: [AuthFileRecord]
}

private struct AuthFileRecord: Decodable {
    let name: String
    let provider: String
    let authIndex: String
    let status: String?
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, provider, status, disabled
        case authIndex = "auth_index"
    }
}

private struct ManagedCredential {
    let name: String
    let provider: String
    let authIndex: String
    let status: String
    let disabled: Bool

    init(_ record: AuthFileRecord) {
        name = record.name
        provider = record.provider.lowercased()
        authIndex = record.authIndex
        status = record.status?.lowercased() ?? "ready"
        disabled = record.disabled
    }
}

private struct APICallResponsePayload: Decodable {
    let statusCode: Int
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case body
    }
}

private struct APICallResponse {
    let statusCode: Int
    let body: Data
}
