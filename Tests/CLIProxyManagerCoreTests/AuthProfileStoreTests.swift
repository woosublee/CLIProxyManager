import XCTest
@testable import CLIProxyManagerCore

final class AuthProfileStoreTests: XCTestCase {
    func testProfilesReadClaudeAndCodexMetadataWithoutTokens() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","email":"claude@example.com","expired":"2026-05-09T11:24:01+09:00","prefix":"team-claude","access_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("claude.json"))
        try Data(#"{"type":"codex","email":"codex@example.com","account_id":"acct_123","disabled":false,"refresh_token":"secret"}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("codex.json"))

        let store = AuthProfileStore(authDirectory: authDirectory)
        let profiles = try store.profiles()

        XCTAssertEqual(profiles, [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: false, prefix: "team-claude"),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
    }

    func testSetPrefixUpdatesOnlyTargetedAuthFileAndPreservesTokensAndUnknownFields() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let otherURL = authDirectory.appendingPathComponent("claude-personal.json")
        try Data(#"{"type":"claude","email":"work@example.com","prefix":"old","access_token":"access","refresh_token":"refresh","metadata":{"tier":"max"}}"#.utf8)
            .write(to: targetURL)
        try Data(#"{"type":"claude","email":"personal@example.com","prefix":"personal","access_token":"other"}"#.utf8)
            .write(to: otherURL)

        let store = AuthProfileStore(authDirectory: authDirectory)
        let didUpdate = try store.setPrefix(" team ", id: "claude-work.json")
        let targetJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any])
        let otherJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: otherURL)) as? [String: Any])
        let metadata = try XCTUnwrap(targetJSON["metadata"] as? [String: Any])

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(targetJSON["prefix"] as? String, "team")
        XCTAssertEqual(targetJSON["access_token"] as? String, "access")
        XCTAssertEqual(targetJSON["refresh_token"] as? String, "refresh")
        XCTAssertEqual(metadata["tier"] as? String, "max")
        XCTAssertEqual(otherJSON["prefix"] as? String, "personal")
        XCTAssertEqual(otherJSON["access_token"] as? String, "other")
    }

    func testSetDisabledByIDUpdatesOnlyTargetedAuthFileAndPreservesTokensAndUnknownFields() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let targetURL = authDirectory.appendingPathComponent("codex-work.json")
        let otherURL = authDirectory.appendingPathComponent("codex-personal.json")
        try Data(#"{"type":"codex","email":"work@example.com","disabled":false,"access_token":"access","refresh_token":"refresh","metadata":{"tier":"plus"}}"#.utf8)
            .write(to: targetURL)
        try Data(#"{"type":"codex","email":"personal@example.com","disabled":false,"access_token":"other","metadata":{"tier":"free"}}"#.utf8)
            .write(to: otherURL)

        let store = AuthProfileStore(authDirectory: authDirectory)
        let didUpdate = try store.setDisabled(true, id: "codex-work.json")
        let targetJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any])
        let otherJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: otherURL)) as? [String: Any])
        let targetMetadata = try XCTUnwrap(targetJSON["metadata"] as? [String: Any])
        let otherMetadata = try XCTUnwrap(otherJSON["metadata"] as? [String: Any])

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(targetJSON["disabled"] as? Bool, true)
        XCTAssertEqual(targetJSON["access_token"] as? String, "access")
        XCTAssertEqual(targetJSON["refresh_token"] as? String, "refresh")
        XCTAssertEqual(targetMetadata["tier"] as? String, "plus")
        XCTAssertEqual(otherJSON["disabled"] as? Bool, false)
        XCTAssertEqual(otherJSON["access_token"] as? String, "other")
        XCTAssertEqual(otherMetadata["tier"] as? String, "free")
    }

    func testDeleteByIDDeletesOnlyTargetedAuthFile() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let otherURL = authDirectory.appendingPathComponent("claude-personal.json")
        try Data(#"{"type":"claude","email":"work@example.com"}"#.utf8)
            .write(to: targetURL)
        try Data(#"{"type":"claude","email":"personal@example.com"}"#.utf8)
            .write(to: otherURL)

        let store = AuthProfileStore(authDirectory: authDirectory)
        let didDelete = try store.delete(id: "claude-work.json")

        XCTAssertTrue(didDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
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
