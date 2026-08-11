import CryptoKit
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

    func testPrepareAndFinalizeCodexCredentialMigrationPreservesCredentialData() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        let backupsDirectory = sandbox.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let sourceURL = authDirectory.appendingPathComponent("codex-user@example.com-pro.json")
        let token = codexIDToken(planType: "Pro")
        let source = #"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)","access_token":"access","refresh_token":"refresh","prefix":"personal","disabled":true,"metadata":{"custom":"value"}}"#
        try Data(source.utf8).write(to: sourceURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sourceURL.path)
        let expectedName = "codex-\(accountHash("acct_123"))-user@example.com-pro.json"
        let targetURL = authDirectory.appendingPathComponent(expectedName)
        let store = AuthProfileStore(
            authDirectory: authDirectory,
            migrationBackupsDirectory: backupsDirectory
        )

        let migrations = try store.prepareCodexCredentialMigrations()

        XCTAssertEqual(migrations.map(\.oldID), [sourceURL.lastPathComponent])
        XCTAssertEqual(migrations.map(\.newID), [expectedName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), try Data(contentsOf: sourceURL))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: targetURL.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o640)
        )
        let repeated = try store.prepareCodexCredentialMigrations()
        XCTAssertEqual(repeated.map(\.oldID), migrations.map(\.oldID))
        XCTAssertEqual(repeated.map(\.newID), migrations.map(\.newID))

        try store.finalizeCodexCredentialMigrations(migrations)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)
        XCTAssertEqual(backups, ["codex-user@example.com-pro.json.migrated"])
    }

    func testRollbackCodexCredentialMigrationRemovesOnlyPreparedCanonicalCopy() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let sourceURL = authDirectory.appendingPathComponent("codex-user@example.com-plus.json")
        let token = codexIDToken(planType: "plus")
        try Data(#"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)"}"#.utf8)
            .write(to: sourceURL)
        let store = AuthProfileStore(authDirectory: authDirectory)
        let migrations = try store.prepareCodexCredentialMigrations()
        let targetURL = authDirectory.appendingPathComponent(try XCTUnwrap(migrations.first?.newID))

        store.rollbackCodexCredentialMigrations(migrations)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testPrepareCodexCredentialMigrationReusesMatchingCanonicalTargetWithoutOverwritingIt() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let token = codexIDToken(planType: "pro")
        let sourceURL = authDirectory.appendingPathComponent("codex-user@example.com-pro.json")
        let targetURL = authDirectory.appendingPathComponent("codex-\(accountHash("acct_123"))-user@example.com-pro.json")
        try Data(#"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)","access_token":"legacy"}"#.utf8)
            .write(to: sourceURL)
        let targetData = Data(#"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)","access_token":"current"}"#.utf8)
        try targetData.write(to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        let migrations = try store.prepareCodexCredentialMigrations()
        store.rollbackCodexCredentialMigrations(migrations)

        XCTAssertEqual(migrations, [AuthProfileMigration(oldID: sourceURL.lastPathComponent, newID: targetURL.lastPathComponent)])
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testPrepareCodexCredentialMigrationSkipsUnsafeOrUnrelatedFiles() throws {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let token = codexIDToken(planType: "pro")
        let fixtures: [(String, String)] = [
            ("claude-user.json", #"{"type":"claude","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)"}"#),
            ("codex-no-account.json", #"{"type":"codex","email":"user@example.com","id_token":"\#(token)"}"#),
            ("custom-codex.json", #"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"\#(token)"}"#),
            ("codex-user@example.com-pro.json", #"{"type":"codex","email":"user@example.com","account_id":"acct_123","id_token":"invalid"}"#),
            ("codex-\(accountHash("acct_456"))-other@example.com-pro.json", #"{"type":"codex","email":"other@example.com","account_id":"acct_456","id_token":"\#(token)"}"#)
        ]
        for (name, contents) in fixtures {
            try Data(contents.utf8).write(to: authDirectory.appendingPathComponent(name))
        }
        let store = AuthProfileStore(authDirectory: authDirectory)

        XCTAssertEqual(try store.prepareCodexCredentialMigrations(), [])
    }

    func testReauthenticateUpdatesTargetInPlaceAndRestoresTargetMetadata() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        try write(#"{"type":"claude","email":"work@example.com","disabled":true,"prefix":"work","access_token":"old"}"#, to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        let profile = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
            try write(#"{"type":"claude","email":"replacement@example.com","disabled":false,"prefix":"temporary","access_token":"replacement-access","refresh_token":"replacement-refresh"}"#, to: targetURL)
        }

        let json = try json(at: targetURL)
        XCTAssertEqual(profile.email, "replacement@example.com")
        XCTAssertEqual(json["access_token"] as? String, "replacement-access")
        XCTAssertEqual(json["disabled"] as? Bool, true)
        XCTAssertEqual(json["prefix"] as? String, "work")
    }

    func testReauthenticateMovesSingleNewCredentialIntoTargetAndDeletesSource() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("codex-work.json")
        let sourceURL = authDirectory.appendingPathComponent("codex-login-output.json")
        try write(#"{"type":"codex","email":"work@example.com","disabled":false,"prefix":"work","access_token":"old"}"#, to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        _ = try await store.reauthenticate(targetID: "codex-work.json", provider: .codex) {
            try write(#"{"type":"codex","email":"replacement@example.com","disabled":false,"prefix":"generated","access_token":"replacement-access"}"#, to: sourceURL)
        }

        XCTAssertEqual(try json(at: targetURL)["access_token"] as? String, "replacement-access")
        XCTAssertEqual(try json(at: targetURL)["prefix"] as? String, "work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testReauthenticateRestoresChangedNonTargetSourceAfterCopyingItsCredential() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let sourceURL = authDirectory.appendingPathComponent("claude-personal.json")
        let originalSource = #"{"type":"claude","email":"personal@example.com","access_token":"personal-old"}"#
        try write(#"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#, to: targetURL)
        try write(originalSource, to: sourceURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
            try write(#"{"type":"claude","email":"replacement@example.com","access_token":"replacement-access"}"#, to: sourceURL)
        }

        XCTAssertEqual(try json(at: targetURL)["access_token"] as? String, "replacement-access")
        XCTAssertEqual(try fileDigest(at: sourceURL), digest(of: Data(originalSource.utf8)))
    }

    func testReauthenticateRollsBackWhenMultipleCredentialsChange() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let firstNewURL = authDirectory.appendingPathComponent("claude-new-one.json")
        let secondNewURL = authDirectory.appendingPathComponent("claude-new-two.json")
        let originalTarget = #"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#
        try write(originalTarget, to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
                try write(#"{"type":"claude","email":"one@example.com","access_token":"one"}"#, to: firstNewURL)
                try write(#"{"type":"claude","email":"two@example.com","access_token":"two"}"#, to: secondNewURL)
            }
        } verify: { error in
            XCTAssertEqual(error as? AuthProfileReauthenticationError, .ambiguousChangedCredentials)
        }

        XCTAssertEqual(try fileDigest(at: targetURL), digest(of: Data(originalTarget.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstNewURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondNewURL.path))
    }

    func testReauthenticateRollsBackPartialLoginWhenLoginClosureThrows() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let originalTarget = #"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#
        try write(originalTarget, to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
                try write(#"{"type":"claude","email":"replacement@example.com","access_token":"replacement-access"}"#, to: targetURL)
                throw CancellationError()
            }
        } verify: { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try fileDigest(at: targetURL), digest(of: Data(originalTarget.utf8)))
    }

    func testReauthenticateRollsBackWhenLoginTaskIsCancelledAfterWritingCredential() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let originalTarget = #"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#
        try write(originalTarget, to: targetURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
                try write(#"{"type":"claude","email":"replacement@example.com","access_token":"replacement-access"}"#, to: targetURL)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        } verify: { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try fileDigest(at: targetURL), digest(of: Data(originalTarget.utf8)))
    }

    func testReauthenticateRollsBackWhenExistingCredentialIsDeletedAlongsideNewSource() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let deletedURL = authDirectory.appendingPathComponent("claude-personal.json")
        let sourceURL = authDirectory.appendingPathComponent("claude-login-output.json")
        let originalTarget = #"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#
        let originalDeleted = #"{"type":"claude","email":"personal@example.com","access_token":"personal-old"}"#
        try write(originalTarget, to: targetURL)
        try write(originalDeleted, to: deletedURL)
        let store = AuthProfileStore(authDirectory: authDirectory)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
                try FileManager.default.removeItem(at: deletedURL)
                try write(#"{"type":"claude","email":"replacement@example.com","access_token":"replacement-access"}"#, to: sourceURL)
            }
        } verify: { error in
            XCTAssertEqual(error as? AuthProfileReauthenticationError, .ambiguousChangedCredentials)
        }

        XCTAssertEqual(try fileDigest(at: targetURL), digest(of: Data(originalTarget.utf8)))
        XCTAssertEqual(try fileDigest(at: deletedURL), digest(of: Data(originalDeleted.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testReauthenticateContinuesRollbackAfterNewCredentialRemovalFails() async throws {
        let authDirectory = try makeAuthDirectory()
        let targetURL = authDirectory.appendingPathComponent("claude-work.json")
        let firstNewURL = authDirectory.appendingPathComponent("claude-new-one.json")
        let secondNewURL = authDirectory.appendingPathComponent("claude-new-two.json")
        let originalTarget = #"{"type":"claude","email":"work@example.com","access_token":"work-old"}"#
        try write(originalTarget, to: targetURL)
        let fileManager = FailFirstNewCredentialRemovalFileManager(
            fileNames: [firstNewURL.lastPathComponent, secondNewURL.lastPathComponent]
        )
        let store = AuthProfileStore(authDirectory: authDirectory, fileManager: fileManager)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.reauthenticate(targetID: "claude-work.json", provider: .claude) {
                try write(#"{"type":"claude","email":"replacement@example.com","access_token":"replacement-access"}"#, to: targetURL)
                try write(#"{"type":"claude","email":"one@example.com","access_token":"one"}"#, to: firstNewURL)
                try write(#"{"type":"claude","email":"two@example.com","access_token":"two"}"#, to: secondNewURL)
                throw CancellationError()
            }
        } verify: { error in
            XCTAssertEqual(error as? AuthProfileReauthenticationError, .rollbackFailed)
        }

        let failedFileName = try XCTUnwrap(fileManager.failedFileName)
        let otherNewURL = try XCTUnwrap(
            [firstNewURL, secondNewURL].first { $0.lastPathComponent != failedFileName }
        )
        XCTAssertEqual(try fileDigest(at: targetURL), digest(of: Data(originalTarget.utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: authDirectory.appendingPathComponent(failedFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherNewURL.path))
    }

    func testReauthenticationErrorsProvideRecoveryDescriptions() {
        XCTAssertEqual(
            AuthProfileReauthenticationError.noChangedCredential.localizedDescription,
            "No new credential was detected after login. Retry the login in your browser."
        )
        XCTAssertEqual(
            AuthProfileReauthenticationError.ambiguousChangedCredentials.localizedDescription,
            "Multiple credentials changed during login, so the target account could not be identified. Retry with a single login."
        )
        XCTAssertEqual(
            AuthProfileReauthenticationError.targetProfileNotFound("claude-work.json").localizedDescription,
            "The selected account credential could not be found."
        )
        XCTAssertEqual(
            AuthProfileReauthenticationError.rollbackFailed.localizedDescription,
            "The previous credentials could not be fully restored. Check the account credentials and retry."
        )
    }

    private func makeAuthDirectory() throws -> URL {
        let sandbox = try makeSandbox()
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        return authDirectory
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func fileDigest(at url: URL) throws -> String {
        digest(of: try Data(contentsOf: url))
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        verify: (Error) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error to be thrown", file: file, line: line)
        } catch {
            verify(error)
        }
    }

    private func codexIDToken(planType: String) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let payload = try! JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_plan_type": planType]
        ]).base64URLEncodedString()
        return "\(header).\(payload).signature"
    }

    private func accountHash(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
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

private final class FailFirstNewCredentialRemovalFileManager: FileManager {
    private let fileNames: Set<String>
    private let lock = NSLock()
    private var failedFileNameStorage: String?

    init(fileNames: Set<String>) {
        self.fileNames = fileNames
        super.init()
    }

    var failedFileName: String? {
        lock.withLock { failedFileNameStorage }
    }

    override func removeItem(at URL: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard fileNames.contains(URL.lastPathComponent), failedFileNameStorage == nil else {
                return false
            }
            failedFileNameStorage = URL.lastPathComponent
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: URL)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
