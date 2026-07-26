import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class AppConfigMigrationTests: XCTestCase {
    func testReconcilePrunesProfilesWithoutAuthFilesAndRewritesConfig() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "stale-codex",
                provider: .codex,
                authProfileID: "missing.json",
                commandName: "stale-command",
                codex: .default,
                modelPrefix: "codex-stale"
            )
        ]
        let loaded = AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: nil,
            requiresCanonicalRewrite: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [])

        XCTAssertEqual(result.config.oauthCommandProfiles, [])
        XCTAssertTrue(result.shouldPersist)
    }

    func testReconcileAttachesLegacyDefaultsToFirstMatchingAuthProfile() {
        let loaded = AppConfigLoadResult(
            config: .default,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: nil,
                codex: LegacyOAuthProviderDefaults(
                    commandName: "codex-work",
                    nickname: "Work",
                    accountDetailHidden: false,
                    dangerousPermissionsEnabled: true,
                    claude: nil,
                    codex: .default
                )
            ),
            requiresCanonicalRewrite: true
        )
        let authProfile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "account@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [authProfile])

        XCTAssertEqual(result.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].authProfileID, authProfile.id)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].commandName, "codex-work")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].nickname, "Work")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].accountDetailHidden, false)
        XCTAssertTrue(result.config.oauthCommandProfiles[0].dangerousPermissionsEnabled)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].codex, .default)
        XCTAssertTrue(result.shouldPersist)
    }

    func testCanonicalProfileWinsOverLegacyDefaults() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "canonical-command",
                nickname: "Canonical",
                codex: .default
            )
        ]
        let loaded = AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: nil,
                codex: LegacyOAuthProviderDefaults(
                    commandName: "legacy-command",
                    nickname: "Legacy",
                    accountDetailHidden: true,
                    dangerousPermissionsEnabled: false,
                    claude: nil,
                    codex: .default
                )
            ),
            requiresCanonicalRewrite: true
        )
        let authProfile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "account@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [authProfile])

        XCTAssertEqual(result.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].commandName, "canonical-command")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].nickname, "Canonical")
    }

    func testReconcileDiscardsLegacyOAuthDefaultsWhenNoAuthProfileExists() {
        let loaded = AppConfigLoadResult(
            config: .default,
            legacyOAuthDefaults: LegacyOAuthDefaults(
                claude: LegacyOAuthProviderDefaults(
                    commandName: "claude-work",
                    nickname: "Work",
                    accountDetailHidden: false,
                    dangerousPermissionsEnabled: false,
                    claude: .automatic,
                    codex: nil
                ),
                codex: nil
            ),
            requiresCanonicalRewrite: true
        )

        let result = AppConfigMigration.reconcile(loadResult: loaded, authProfiles: [])

        XCTAssertTrue(result.config.oauthCommandProfiles.isEmpty)
        XCTAssertTrue(result.shouldPersist)
    }

    func testReconcileCreatesEmptyCanonicalProfileForNewAuthFile() {
        let authProfile = AuthProfile(
            fileName: "claude-work.json",
            type: .claude,
            email: "account@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )

        let result = AppConfigMigration.reconcile(
            loadResult: .canonical(.default),
            authProfiles: [authProfile]
        )

        XCTAssertEqual(result.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].commandName, "")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].nickname, "")
        XCTAssertEqual(result.config.oauthCommandProfiles[0].claude, .automatic)
        XCTAssertEqual(result.config.oauthCommandProfiles[0].modelPrefix, "claude-work")
        XCTAssertTrue(result.shouldPersist)
    }
}
