import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPClientError: Error, Equatable {
    case badStatus(Int)
    case timedOut
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = URLSessionHTTPClient.makeDefaultSession()) {
        self.session = session
    }

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // Bypass any system HTTP proxies for loopback so the connection stays on lo0.
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw HTTPClientError.badStatus(httpResponse.statusCode)
        }
        return data
    }
}

public struct ProxyHealthClient: Sendable {
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval
    private let localAPIKey: String

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 2, localAPIKey: String = "sk-dummy") {
        self.httpClient = httpClient
        self.timeout = timeout
        self.localAPIKey = localAPIKey
    }

    public func status(port: Int) async -> DiagnosticStatus {
        guard isValidPort(port) else {
            return DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI Port Configuration Error",
                message: "Port must be between 1 and 65535."
            )
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!

        do {
            _ = try await getWithTimeout(url)
            return DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port \(port)."
            )
        } catch HTTPClientError.timedOut {
            return DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI Response Timed Out",
                message: "The server did not respond in time."
            )
        } catch HTTPClientError.badStatus(401) {
            return DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Authentication Needs Attention",
                message: "The server responded, but models could not be loaded with the sk-dummy local API key."
            )
        } catch HTTPClientError.badStatus(let statusCode) {
            return DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Response Error",
                message: "The server responded, but models could not be loaded. HTTP \(statusCode)"
            )
        } catch {
            return stoppedStatus
        }
    }

    private func getWithTimeout(_ url: URL) async throws -> Data {
        try await withTimeout(seconds: timeout) {
            try await httpClient.get(url, headers: authHeaders)
        }
    }

    private var authHeaders: [String: String] {
        ["Authorization": "Bearer \(localAPIKey)"]
    }

    private var stoppedStatus: DiagnosticStatus {
        DiagnosticStatus(
            severity: .warning,
            title: "CLIProxyAPI Stopped",
            message: ""
        )
    }
}

private func withTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds(seconds))
            throw HTTPClientError.timedOut
        }

        guard let value = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return value
    }
}

private func timeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(seconds, 0.001) * 1_000_000_000)
}

private func isValidPort(_ port: Int) -> Bool {
    (1...65_535).contains(port)
}
