import XCTest
@testable import CLIProxyManagerApp

final class LicenseResourceTests: XCTestCase {
    func testCLIProxyAPILicenseResourceIsBundled() throws {
        let url = try XCTUnwrap(LicenseResource.cliProxyAPILicenseURL())
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("MIT License"))
        XCTAssertTrue(text.contains("Copyright (c) 2025-2005.9 Luis Pater"))
        XCTAssertTrue(text.contains("Permission is hereby granted"))
        XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    func testCLIProxyAPIBinaryResourceIsBundled() throws {
        let url = try XCTUnwrap(BundledProxyBinary.url())

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testBundledProxyBinaryCreatesServiceManager() {
        _ = BundledProxyBinary.serviceManager()
    }
}
