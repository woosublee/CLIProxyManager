import Darwin
import XCTest
@testable import CLIProxyManagerCore

final class FileSecretStoreTests: XCTestCase {
    func testRoundTripStoresEachAPIKeyInPrivateFiles() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))
        let store = FileSecretStore(paths: paths)

        try store.set("claude-secret", for: .claudeAPIKey)
        try store.set("codex-secret", for: .codexAPIKey)

        XCTAssertEqual(try store.get(.claudeAPIKey), "claude-secret")
        XCTAssertEqual(try store.get(.codexAPIKey), "codex-secret")
        XCTAssertEqual(fileMode(paths.apiKeysDirectory), 0o700)
        XCTAssertEqual(fileMode(paths.apiKeyFile(for: .claudeAPIKey)), 0o600)
        XCTAssertEqual(fileMode(paths.apiKeyFile(for: .codexAPIKey)), 0o600)
    }

    func testGetRejectsSecretFileWithWrongPermissions() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))
        let store = FileSecretStore(paths: paths)
        try store.set("secret", for: .claudeAPIKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.apiKeyFile(for: .claudeAPIKey).path)

        XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .readFailed("claude-api-key"))
        }
    }

    func testGetRejectsSecretFileSymlink() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))
        let store = FileSecretStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.apiKeysDirectory, withIntermediateDirectories: true)
        let target = paths.apiKeysDirectory.appendingPathComponent("target.json")
        try Data(#"{"version":1,"value":"secret"}"#.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: paths.apiKeyFile(for: .claudeAPIKey), withDestinationURL: target)

        XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .readFailed("claude-api-key"))
        }
    }

    func testSetRejectsAPIKeyDirectorySymlinkWithoutChangingTargetPermissions() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed", isDirectory: true))
        let target = sandbox.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.apiKeysDirectory, withDestinationURL: target)

        XCTAssertThrowsError(try FileSecretStore(paths: paths).set("secret", for: .claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .writeFailed("api-keys"))
        }
        XCTAssertEqual(fileMode(target), 0o755)
    }

    func testDeleteRemovesExistingSecretAndAllowsMissingSecret() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))
        let store = FileSecretStore(paths: paths)
        try store.set("secret", for: .claudeAPIKey)

        try store.delete(.claudeAPIKey)
        try store.delete(.claudeAPIKey)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.apiKeyFile(for: .claudeAPIKey).path))
    }

    func testSetRejectsEmptySecret() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))

        XCTAssertThrowsError(try FileSecretStore(paths: paths).set(" \n", for: .claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .writeFailed("claude-api-key"))
        }
    }

    func testMultipleProfilesUseIndependentPrivateFiles() throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox().appendingPathComponent("managed", isDirectory: true))
        let store = FileSecretStore(paths: paths)
        let first = try XCTUnwrap(SecretReference(rawValue: "claude-api-first-key"))
        let second = try XCTUnwrap(SecretReference(rawValue: "claude-api-second-key"))

        try store.set("first-secret", for: first)
        try store.set("second-secret", for: second)

        XCTAssertEqual(try store.get(first), "first-secret")
        XCTAssertEqual(try store.get(second), "second-secret")
        XCTAssertNotEqual(paths.apiKeyFile(for: first), paths.apiKeyFile(for: second))
        XCTAssertEqual(fileMode(paths.apiKeyFile(for: first)), 0o600)
        XCTAssertEqual(fileMode(paths.apiKeyFile(for: second)), 0o600)
    }

    func testSecretReferenceRejectsUnsafeFileNames() {
        XCTAssertNil(SecretReference(rawValue: "../claude-key"))
        XCTAssertNil(SecretReference(rawValue: "claude/key"))
        XCTAssertNil(SecretReference(rawValue: "Claude-Key"))
        XCTAssertNil(SecretReference(rawValue: "-claude-key"))
        XCTAssertNotNil(SecretReference(rawValue: "claude-api-profile-key"))
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func fileMode(_ url: URL) -> Int {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return Int(status.st_mode) & 0o777
    }
}
