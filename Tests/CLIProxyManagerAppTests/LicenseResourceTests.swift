import XCTest
@testable import CLIProxyManagerApp

final class LicenseResourceTests: XCTestCase {
    func testCLIProxyAPILicenseResourceFallsBackToAppBundleResources() throws {
        let fixture = try makeAppBundleResourceFixture(
            subdirectory: "Licenses",
            fileName: "CLIProxyAPI-LICENSE.txt",
            contents: Data("Packaged MIT License".utf8)
        )

        let url = try XCTUnwrap(LicenseResource.cliProxyAPILicenseURL(bundle: Bundle(for: Self.self), appBundle: fixture.bundle))
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(text, "Packaged MIT License")
    }

    func testCLIProxyAPIBinaryResourceFallsBackToAppBundleResources() throws {
        let fixture = try makeAppBundleResourceFixture(
            subdirectory: "cliproxyapi",
            fileName: "cliproxyapi",
            contents: Data([0xCA, 0xFE])
        )

        let url = try XCTUnwrap(BundledProxyBinary.url(bundle: Bundle(for: Self.self), appBundle: fixture.bundle))

        XCTAssertEqual(try Data(contentsOf: url), Data([0xCA, 0xFE]))
    }

    func testCLIProxyAPILicenseResourceIsBundled() throws {
        let url = try XCTUnwrap(LicenseResource.cliProxyAPILicenseURL())
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("MIT License"))
        XCTAssertTrue(text.contains("Copyright (c) 2025 Luis Pater"))
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

    private func makeAppBundleResourceFixture(subdirectory: String, fileName: String, contents: Data) throws -> (root: URL, bundle: Bundle) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let targetDirectory = resourcesURL.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try contents.write(to: targetDirectory.appendingPathComponent(fileName))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (root, try XCTUnwrap(Bundle(url: appURL)))
    }
}
