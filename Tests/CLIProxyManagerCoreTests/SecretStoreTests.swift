import XCTest
@testable import CLIProxyManagerCore

final class SecretStoreTests: XCTestCase {
    func testInMemorySecretStoreRoundTrip() throws {
        let store = InMemorySecretStore()

        try store.set("abc123", for: .claudeAPIKey)

        XCTAssertEqual(try store.get(.claudeAPIKey), "abc123")
    }

    func testMissingSecretThrows() {
        let store = InMemorySecretStore()

        XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .missingSecret("claude-api-key"))
        }
    }

    func testInMemorySecretStoreDeleteRemovesSecret() throws {
        let store = InMemorySecretStore()
        try store.set("abc123", for: .claudeAPIKey)

        try store.delete(.claudeAPIKey)

        XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .missingSecret("claude-api-key"))
        }
    }

    func testSecretKeyRawValueInitializesClaudeAPIKey() {
        XCTAssertEqual(SecretKey(rawValue: "claude-api-key"), .claudeAPIKey)
    }

    func testSecretStoreErrorDescriptionIsDeterministic() {
        XCTAssertEqual(
            SecretStoreError.missingSecret("claude-api-key").description,
            "Missing secret: claude-api-key"
        )
        XCTAssertEqual(
            SecretStoreError.writeFailed("claude-api-key").description,
            "Failed to write secret: claude-api-key"
        )
        XCTAssertEqual(
            SecretStoreError.readFailed("claude-api-key").description,
            "Failed to read secret: claude-api-key"
        )
    }
}
