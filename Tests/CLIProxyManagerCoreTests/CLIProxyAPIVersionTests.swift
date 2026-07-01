import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedStableVersions() {
        XCTAssertEqual(CLIProxyAPIVersion("7.2.41")?.description, "7.2.41")
        XCTAssertEqual(CLIProxyAPIVersion("v7.2.41")?.description, "7.2.41")
    }

    func testComparesSemanticVersionsNumerically() throws {
        let old = try XCTUnwrap(CLIProxyAPIVersion("7.2.9"))
        let new = try XCTUnwrap(CLIProxyAPIVersion("7.2.10"))
        XCTAssertLessThan(old, new)
    }

    func testRejectsPrereleaseAndMalformedVersions() {
        XCTAssertNil(CLIProxyAPIVersion("7.2.41-beta.1"))
        XCTAssertNil(CLIProxyAPIVersion("latest"))
        XCTAssertNil(CLIProxyAPIVersion("7.2"))
    }
}
