import Foundation
import XCTest

final class RuntimeTestSafetyTests: XCTestCase {
    func testTestsDoNotUseProductionPortLiterals() throws {
        let testsDirectory = repositoryRoot().appendingPathComponent("Tests", isDirectory: true)
        let forbiddenCompactPort = "18" + "317"
        let forbiddenSwiftPort = "18_" + "317"

        for fileURL in try swiftFiles(in: testsDirectory) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains(forbiddenCompactPort),
                "Production port literal found in test source: \(fileURL.path)"
            )
            XCTAssertFalse(
                source.contains(forbiddenSwiftPort),
                "Production port literal found in test source: \(fileURL.path)"
            )
        }
    }

    func testProxyServiceTestsNeverConstructRealLaunchctlRunner() throws {
        let fileURL = repositoryRoot().appendingPathComponent(
            "Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift"
        )
        let source = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(source.contains("LaunchctlRunner" + "()"))
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try (enumerator?.allObjects as? [URL] ?? []).filter { url in
            guard url.pathExtension == "swift" else { return false }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
