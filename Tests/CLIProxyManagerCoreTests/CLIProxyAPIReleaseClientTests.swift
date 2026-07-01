import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIReleaseClientTests: XCTestCase {
    func testParsesLatestReleaseAndChecksumForDarwinArm64Asset() async throws {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let checksumURL = URL(string: "https://downloads.example/checksums.txt")!
        let archiveURL = URL(string: "https://downloads.example/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            {
              "tag_name": "v7.2.42",
              "prerelease": false,
              "assets": [
                { "name": "checksums.txt", "browser_download_url": "\(checksumURL.absoluteString)" },
                { "name": "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz", "browser_download_url": "\(archiveURL.absoluteString)" }
              ]
            }
            """.utf8),
            checksumURL: Data("archive-sha  CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz\n".utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        let release = try await client.latestRelease()

        XCTAssertEqual(release.version.description, "7.2.42")
        XCTAssertEqual(release.tagName, "v7.2.42")
        XCTAssertEqual(release.assetName, "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")
        XCTAssertEqual(release.assetURL, archiveURL)
        XCTAssertEqual(release.assetSha256, "archive-sha")
        XCTAssertEqual(http.requestedURLs, [latestURL, checksumURL])
    }

    func testRejectsPrereleaseLatestRelease() async {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            { "tag_name": "v7.2.42", "prerelease": true, "assets": [] }
            """.utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        await XCTAssertThrowsErrorAsync(try await client.latestRelease()) { error in
            XCTAssertEqual(error as? CLIProxyAPIReleaseClientError, .prereleaseUnsupported("v7.2.42"))
        }
    }

    func testReportsMissingDarwinArm64Asset() async {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            { "tag_name": "v7.2.42", "prerelease": false, "assets": [{ "name": "checksums.txt", "browser_download_url": "https://downloads.example/checksums.txt" }] }
            """.utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        await XCTAssertThrowsErrorAsync(try await client.latestRelease()) { error in
            XCTAssertEqual(error as? CLIProxyAPIReleaseClientError, .missingAsset("CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz"))
        }
    }

    func testDownloadsArchiveDataFromReleaseAssetURL() async throws {
        let archiveURL = URL(string: "https://downloads.example/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")!
        let data = Data("archive".utf8)
        let http = StubReleaseHTTPClient(responses: [archiveURL: data])
        let client = CLIProxyAPIReleaseClient(httpClient: http)
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: archiveURL,
            assetSha256: data.sha256HexDigest()
        )

        let downloaded = try await client.downloadArchive(for: release)

        XCTAssertEqual(downloaded, data)
    }
}

private final class StubReleaseHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [URL: Data]
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] { lock.withLock { _requestedURLs } }

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _requestedURLs.append(url) }
        guard let data = responses[url] else { throw HTTPClientError.badStatus(404) }
        return data
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ assertion: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        assertion(error)
    }
}
