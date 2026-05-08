import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPClientError: Error, Equatable {
    case badStatus(Int)
    case timedOut
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
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

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 2) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func status(port: Int) async -> DiagnosticStatus {
        guard isValidPort(port) else {
            return DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI 포트 설정 오류",
                message: "포트는 1부터 65535 사이여야 합니다."
            )
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!

        do {
            _ = try await getWithTimeout(url)
            return DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI 실행 중",
                message: "포트 \(port)에서 모델 목록을 불러올 수 있습니다."
            )
        } catch HTTPClientError.timedOut {
            return DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI 응답 시간 초과",
                message: "서버가 시간 내에 응답하지 않았습니다."
            )
        } catch HTTPClientError.badStatus(let statusCode) {
            return DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI 응답 오류",
                message: "서버가 응답했지만 모델 목록을 불러오지 못했습니다. HTTP \(statusCode)"
            )
        } catch {
            return stoppedStatus
        }
    }

    private func getWithTimeout(_ url: URL) async throws -> Data {
        try await withTimeout(seconds: timeout) {
            try await httpClient.get(url)
        }
    }

    private var stoppedStatus: DiagnosticStatus {
        DiagnosticStatus(
            severity: .error,
            title: "CLIProxyAPI 중지됨",
            message: "앱에서 서버를 시작하세요."
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
