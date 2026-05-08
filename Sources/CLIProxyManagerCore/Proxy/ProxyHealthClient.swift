import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct ProxyHealthClient: Sendable {
    private let httpClient: any HTTPClient

    public init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func status(port: Int) async -> DiagnosticStatus {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return stoppedStatus
        }

        do {
            _ = try await httpClient.get(url)
            return DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI 실행 중",
                message: "포트 \(port)에서 모델 목록을 불러올 수 있습니다."
            )
        } catch {
            return stoppedStatus
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
