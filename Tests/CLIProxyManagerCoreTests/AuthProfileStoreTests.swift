import XCTest
@testable import CLIProxyManagerCore

final class AuthProfileStoreTests: XCTestCase {
    func testProfilesReadClaudeAndCodexMetadataWithoutTokens() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","email":"woosub@classting.com","expired":"2026-05-09T11:24:01+09:00","access_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("claude.json"))
        try Data(#"{"type":"codex","email":"codex@example.com","account_id":"acct_123","disabled":false,"refresh_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("codex.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)
        let profiles = try store.profiles()

        XCTAssertEqual(profiles, [
            AuthProfile(fileName: "claude.json", type: .claude, email: "woosub@classting.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
    }

    func testProfilesIgnoreUnsupportedTypesAndInvalidJson() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"gemini","email":"gemini@example.com"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("gemini.json"))
        try Data("not json".utf8)
            .write(to: authDirectory.appendingPathComponent("broken.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)

        XCTAssertEqual(try store.profiles(), [])
    }

    func testProfileReturnsFirstEnabledProfileForType() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","email":"disabled@example.com","disabled":true}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("a-disabled.json"))
        try Data(#"{"type":"codex","email":"enabled@example.com","disabled":false}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("b-enabled.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)

        XCTAssertEqual(try store.profile(type: .codex)?.email, "enabled@example.com")
    }

    func testMissingDirectoryReturnsEmptyProfiles() throws {
        let sandbox = try makeSandbox()
        let store = AuthProfileStore(authDirectory: sandbox.appendingPathComponent("missing", isDirectory: true))

        XCTAssertEqual(try store.profiles(), [])
    }

    func testSetDisabledPreservesTokensAndUnknownFields() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let authFileURL = authDirectory.appendingPathComponent("codex.json")
        try Data(#"{"type":"codex","email":"codex@example.com","disabled":false,"access_token":"access","refresh_token":"refresh","metadata":{"tier":"plus"}}"#.utf8)
            .write(to: authFileURL)

        let store = AuthProfileStore(authDirectory: authDirectory)
        let updatedCount = try store.setDisabled(true, for: .codex)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: authFileURL)) as? [String: Any])
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])

        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(json["disabled"] as? Bool, true)
        XCTAssertEqual(json["access_token"] as? String, "access")
        XCTAssertEqual(json["refresh_token"] as? String, "refresh")
        XCTAssertEqual(metadata["tier"] as? String, "plus")
    }

    func testSetDisabledOnlyUpdatesMatchingProviderType() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let claudeURL = authDirectory.appendingPathComponent("claude.json")
        let codexURL = authDirectory.appendingPathComponent("codex.json")
        try Data(#"{"type":"claude","email":"claude@example.com","disabled":false}"#.utf8).write(to: claudeURL)
        try Data(#"{"type":"codex","email":"codex@example.com","disabled":false}"#.utf8).write(to: codexURL)

        let store = AuthProfileStore(authDirectory: authDirectory)
        let updatedCount = try store.setDisabled(true, for: .codex)
        let claudeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        let codexJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: codexURL)) as? [String: Any])

        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(claudeJSON["disabled"] as? Bool, false)
        XCTAssertEqual(codexJSON["disabled"] as? Bool, true)
    }

    func testSetDisabledReturnsZeroForMissingDirectory() throws {
        let sandbox = try makeSandbox()
        let store = AuthProfileStore(authDirectory: sandbox.appendingPathComponent("missing", isDirectory: true))

        XCTAssertEqual(try store.setDisabled(true, for: .claude), 0)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }
}
