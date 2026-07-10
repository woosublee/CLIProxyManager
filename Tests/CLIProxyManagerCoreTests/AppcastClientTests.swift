import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppcastClientTests: XCTestCase {
    func testFeedURLIsExactlyCommittedGitHubURL() {
        XCTAssertEqual(
            AppcastClient.feedURL.absoluteString,
            "https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml"
        )
    }

    func testFetchLatestSelectsOnlyAReleaseWithHigherBuild() async throws {
        let client = AppcastClient(httpClient: HTTPClientDouble(data: appcastXML(items: [
            item(build: 15, version: "0.1.13", url: "https://github.com/example/old.dmg"),
            item(build: 16, version: "0.1.13", url: "https://github.com/example/new.dmg")
        ]).data(using: .utf8)!))

        let update = try await client.fetchLatest(afterBuild: 15)

        XCTAssertEqual(update?.build, 16)
        XCTAssertEqual(update?.version, "0.1.13")
    }

    func testFetchLatestSelectsHighestBuildAmongMultipleCandidates() async throws {
        let client = AppcastClient(httpClient: HTTPClientDouble(data: appcastXML(items: [
            item(build: 17, version: "0.1.14", url: "https://github.com/example/17.dmg"),
            item(build: 16, version: "0.1.13", url: "https://github.com/example/16.dmg")
        ]).data(using: .utf8)!))

        let update = try await client.fetchLatest(afterBuild: 15)

        XCTAssertEqual(update?.build, 17)
    }

    func testFetchLatestReturnsNilWhenNoBuildIsHigher() async throws {
        let client = AppcastClient(httpClient: HTTPClientDouble(data: appcastXML(items: [
            item(build: 15, version: "0.1.13", url: "https://github.com/example/old.dmg")
        ]).data(using: .utf8)!))

        let update = try await client.fetchLatest(afterBuild: 15)

        XCTAssertNil(update)
    }

    func testFetchLatestRejectsNonHTTPSEnclosure() async {
        let client = AppcastClient(httpClient: HTTPClientDouble(data: appcastXML(items: [
            item(build: 16, version: "0.1.13", url: "http://example.invalid/update.dmg")
        ]).data(using: .utf8)!))

        do {
            _ = try await client.fetchLatest(afterBuild: 15)
            XCTFail("Expected error")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .operation("App update enclosure must use HTTPS."))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFetchLatestRejectsMissingSignatureOrLength() async {
        let xml = """
        <?xml version="1.0"?>
        <rss><channel><item>
            <enclosure url="https://example.com/app.dmg" sparkle:version="16" sparkle:shortVersionString="0.1.13"/>
        </item></channel></rss>
        """
        let client = AppcastClient(httpClient: HTTPClientDouble(data: xml.data(using: .utf8)!))

        let result = try? await client.fetchLatest(afterBuild: 15)
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func appcastXML(items: [String]) -> String {
        let itemsXML = items.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            \(itemsXML)
          </channel>
        </rss>
        """
    }

    private func item(build: Int, version: String, url: String) -> String {
        """
        <item>
            <enclosure url="\(url)"
                       sparkle:version="\(build)"
                       sparkle:shortVersionString="\(version)"
                       length="1048576"
                       sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                       type="application/octet-stream"/>
        </item>
        """
    }
}

private struct HTTPClientDouble: HTTPClient {
    let data: Data
    let error: Error?

    init(data: Data, error: Error? = nil) {
        self.data = data
        self.error = error
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        if let error { throw error }
        return data
    }
}
