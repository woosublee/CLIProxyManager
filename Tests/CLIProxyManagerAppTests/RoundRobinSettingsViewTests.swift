import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class RoundRobinSettingsViewTests: XCTestCase {
    func testRoundRobinProviderTitleUsesProviderName() {
        XCTAssertEqual(roundRobinProviderTitle(.codex), "Codex round-robin")
        XCTAssertEqual(roundRobinProviderTitle(.claude), "Claude round-robin")
    }

    func testRoundRobinModelDescriptionExplainsFixedModelPolicy() {
        XCTAssertEqual(
            roundRobinModelDescription(provider: .codex),
            "These model settings belong to the round-robin command. Only the account prefix changes between sessions."
        )
        XCTAssertEqual(
            roundRobinModelDescription(provider: .claude),
            "Claude OAuth round-robin uses the default Claude OAuth model mappings. Only the account prefix changes between sessions."
        )
    }

    func testRoundRobinConfigurationDetailsOnlyShowWhenEnabled() {
        XCTAssertFalse(roundRobinShowsConfigurationDetails(isEnabled: false))
        XCTAssertTrue(roundRobinShowsConfigurationDetails(isEnabled: true))
    }

    func testRoundRobinToggleOffSavesImmediately() {
        XCTAssertTrue(roundRobinSavesImmediatelyAfterToggle(previousIsEnabled: true, newIsEnabled: false))
        XCTAssertFalse(roundRobinSavesImmediatelyAfterToggle(previousIsEnabled: false, newIsEnabled: true))
        XCTAssertFalse(roundRobinSavesImmediatelyAfterToggle(previousIsEnabled: true, newIsEnabled: true))
    }
}
