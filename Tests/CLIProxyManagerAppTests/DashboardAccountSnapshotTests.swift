import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class DashboardAccountSnapshotTests: XCTestCase {
    func testConnectedProviderRowMapsToAccountCard() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.title, "Claude OAuth")
        XCTAssertEqual(snapshot.commandName, "ccm")
        XCTAssertEqual(snapshot.commandSlug, "$ ccm")
        XCTAssertEqual(snapshot.headerCommandSlug, "$ ccm")
        XCTAssertEqual(snapshot.detail, "claude@example.com")
        XCTAssertEqual(snapshot.status, DashboardAccountSnapshot.Status.connected)
        XCTAssertEqual(snapshot.primaryActionTitle, "Settings")
        XCTAssertTrue(snapshot.showsMoreMenu)
    }

    func testDisconnectedProviderRowMapsToConnectAction() {
        let row = ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            nickname: "",
            functionName: "ccmcodex",
            connectionTitle: "Needs connection",
            connectionDetail: "Connect the bundled CLIProxyAPI Codex OAuth profile.",
            isConnected: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.title, "Codex OAuth")
        XCTAssertEqual(snapshot.commandName, "ccmcodex")
        XCTAssertEqual(snapshot.commandSlug, "$ ccmcodex")
        XCTAssertEqual(snapshot.status, DashboardAccountSnapshot.Status.disconnected)
        XCTAssertEqual(snapshot.primaryActionTitle, "Connect")
        XCTAssertFalse(snapshot.showsMoreMenu)
    }

    func testConnectedProviderShowsPrivacyToggleAndHiddenState() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertTrue(snapshot.isAccountDetailHidden)
        XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
    }

    func testHiddenProviderPrivacyToggleAccessibilityLabelShowsAction() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.accountPrivacyToggleAccessibilityLabel, "Show account detail")
    }

    func testVisibleProviderPrivacyToggleAccessibilityLabelShowsAction() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.accountPrivacyToggleAccessibilityLabel, "Hide account detail")
    }

    func testConnectedProviderPreservesVisiblePrivacyState() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertFalse(snapshot.isAccountDetailHidden)
        XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
    }

    func testDisconnectedProviderDoesNotShowPrivacyToggle() {
        let row = ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            nickname: "",
            functionName: "ccmcodex",
            connectionTitle: "Needs connection",
            connectionDetail: "Connect the bundled CLIProxyAPI Codex OAuth profile.",
            isConnected: false,
            accountDetailHidden: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertTrue(snapshot.isAccountDetailHidden)
        XCTAssertFalse(snapshot.showsAccountPrivacyToggle)
    }

    func testDisabledProviderRowMapsToDisabledAccountActions() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Disabled",
            connectionDetail: "claude@example.com",
            isConnected: false,
            isDisabled: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.status, DashboardAccountSnapshot.Status.disabled)
        XCTAssertEqual(snapshot.primaryActionTitle, "Settings")
        XCTAssertTrue(snapshot.showsMoreMenu)
        XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
    }

    func testWhitespaceOnlyNicknameFallsBackToProviderName() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "  \n  ",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        XCTAssertEqual(row.displayTitle, "Claude OAuth")
    }

    func testDisplayTitleUsesTrimmedNickname() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "  Work  \n",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        XCTAssertEqual(row.displayTitle, "Work")
    }

    func testAccountSnapshotPreservesUsageOverlayVisibility() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "cc",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            showsInUsageOverlay: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertFalse(snapshot.showsInUsageOverlay)
        XCTAssertEqual(snapshot.usageOverlayButtonPresentation.symbolName, "macwindow")
        XCTAssertEqual(snapshot.usageOverlayButtonPresentation.accessibilityLabel, "Show in Usage HUD")
        XCTAssertFalse(snapshot.usageOverlayButtonPresentation.isHighlighted)
    }

    func testCooldownPresentationDistinguishesObservationSupportAndFailure() {
        let observedAt = Date(timeIntervalSince1970: 1_789_776_000)
        let cooldown = AccountCooldown(
            scope: "model", modelKey: "gpt-6-astra", reason: "quota",
            retryAt: observedAt.addingTimeInterval(3600), remainingSeconds: 3600
        )
        let blocked = cooldownAccount(.observed(.init(cooldowns: [cooldown], observedAt: observedAt)))
        XCTAssertEqual(blocked.cooldownSummary, "Local cooldown · 1 restriction")
        XCTAssertTrue(blocked.cooldownDetail?.contains("gpt-6-astra") == true)
        XCTAssertTrue(blocked.cooldownDetail?.contains("Quota") == true)
        XCTAssertTrue(blocked.cooldownDetail?.contains("Retry") == true)
        XCTAssertFalse(blocked.cooldownDetail?.contains("fixture@example.com") == true)
        XCTAssertTrue(blocked.isAccountDetailHidden)
        XCTAssertEqual(cooldownAccount(.observed(.init(cooldowns: [], observedAt: observedAt))).cooldownSummary, "No local cooldown observed")
        XCTAssertEqual(cooldownAccount(.unsupported).cooldownSummary, "Cooldown status unsupported")
        XCTAssertEqual(cooldownAccount(.unavailable(.schemaMismatch)).cooldownSummary, "Cooldown status unavailable")
        XCTAssertNil(cooldownAccount(nil).cooldownSummary)
    }

    func testQuotaRecoveryOnlyAppearsForEnabledConnectedOAuthAccounts() {
        XCTAssertTrue(cooldownAccount(nil).showsQuotaRecoveryAction)
        XCTAssertFalse(cooldownAccount(nil, kind: .apiKey).showsQuotaRecoveryAction)
        XCTAssertFalse(cooldownAccount(nil, connected: false).showsQuotaRecoveryAction)
        XCTAssertFalse(cooldownAccount(nil, disabled: true).showsQuotaRecoveryAction)
        XCTAssertNil(cooldownAccount(.unsupported, kind: .apiKey).cooldownSummary)
        XCTAssertNil(cooldownAccount(.unsupported, disabled: true).cooldownSummary)
    }

    private func cooldownAccount(
        _ state: AccountCooldownState?, kind: ProviderCredentialKind = .oauth,
        connected: Bool = true, disabled: Bool = false
    ) -> DashboardAccountSnapshot {
        DashboardAccountSnapshot(provider: ProviderRowState(
            id: .codex, credentialKind: kind, name: "Codex OAuth", nickname: "",
            functionName: "ccmcodex", connectionTitle: "Connected",
            connectionDetail: "fixture@example.com", isConnected: connected,
            isDisabled: disabled, accountDetailHidden: true, cooldownState: state
        ))
    }

    func testVisibleHUDAccountButtonPresentationOffersHideAction() {
        let presentation = UsageOverlayAccountButtonPresentation(showsInUsageOverlay: true)

        XCTAssertEqual(presentation.symbolName, "macwindow")
        XCTAssertEqual(presentation.accessibilityLabel, "Hide from Usage HUD")
        XCTAssertTrue(presentation.isHighlighted)
    }
}
