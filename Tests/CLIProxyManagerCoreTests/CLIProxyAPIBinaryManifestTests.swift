import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIBinaryManifestTests: XCTestCase {
    func testManifestWithoutTargetRemainsDecodable() throws {
        let json = Data("""
        {
          "name": "cliproxyapi",
          "version": "7.2.41",
          "commit": "65f2288a",
          "builtAt": "2026-06-25T17:56:53Z",
          "source": "https://example.com/archive.tar.gz",
          "upstreamRepository": "router-for-me/CLIProxyAPI",
          "upstreamTag": "v7.2.41",
          "upstreamAsset": "CLIProxyAPI_7.2.41_darwin_aarch64.tar.gz",
          "upstreamAssetSha256": "archive-sha",
          "vendoredBinaryName": "cliproxyapi",
          "vendoredBinarySha256": "binary-sha",
          "vendoredBinarySizeBytes": 123,
          "vendoredFromArchivePath": "cli-proxy-api"
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: json)

        XCTAssertEqual(manifest.version, "7.2.41")
        XCTAssertEqual(manifest.sourceKind, .bundled)
        XCTAssertNil(manifest.target)
        XCTAssertEqual(manifest.parsedVersion?.description, "7.2.41")
    }

    func testEncodesUserUpdatedManifestWithSourceKindAndDates() throws {
        let manifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: "7.2.42",
            commit: "abcdef12",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: .userUpdated,
            source: "https://example.com/archive.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v7.2.42",
            upstreamAsset: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive-sha",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: "binary-sha",
            vendoredBinarySizeBytes: 456,
            vendoredFromArchivePath: "cli-proxy-api",
            downloadedAt: "2026-07-01T00:05:00Z",
            appliedAt: "2026-07-01T00:06:00Z",
            target: .darwinArm64
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.sourceKind, .userUpdated)
    }
}
