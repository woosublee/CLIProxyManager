import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class AccountOrderingTests: XCTestCase {
    func testStoredOrderPlacesKnownAccountsFirstAndAppendsNewAccounts() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        let ordered = AccountOrdering.orderedRows(
            rows,
            storedIDs: ["codex-work", "claude-work"]
        )

        XCTAssertEqual(ordered.map(\.id.rawValue), ["codex-work", "claude-work", "claude-api"])
    }

    func testStoredOrderDropsDuplicatesAndMissingAccounts() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        let ordered = AccountOrdering.orderedRows(
            rows,
            storedIDs: ["missing", "codex-work", "codex-work", "claude-work"]
        )

        XCTAssertEqual(ordered.map(\.id.rawValue), ["codex-work", "claude-work", "claude-api"])
    }

    func testEmptyStoredOrderKeepsSourceOrder() {
        let rows = [row("claude-work"), row("codex-work"), row("claude-api")]

        XCTAssertEqual(
            AccountOrdering.orderedRows(rows, storedIDs: []).map(\.id.rawValue),
            ["claude-work", "codex-work", "claude-api"]
        )
    }

    func testMoveBeforePlacesSourceImmediatelyBeforeTarget() {
        let rows = [row("a"), row("b"), row("c"), row("d")]

        let moved = AccountOrdering.moving(
            rows,
            id: ProviderRowState.ID(rawValue: "d"),
            before: ProviderRowState.ID(rawValue: "b")
        )

        XCTAssertEqual(moved.map(\.id.rawValue), ["a", "d", "b", "c"])
    }

    func testMoveBeforeAccountsForRemovingAnEarlierSource() {
        let rows = [row("a"), row("b"), row("c"), row("d")]

        let moved = AccountOrdering.moving(
            rows,
            id: ProviderRowState.ID(rawValue: "a"),
            before: ProviderRowState.ID(rawValue: "d")
        )

        XCTAssertEqual(moved.map(\.id.rawValue), ["b", "c", "a", "d"])
    }

    func testMoveWithNilTargetAppendsToEnd() {
        let rows = [row("a"), row("b"), row("c")]

        let moved = AccountOrdering.moving(
            rows,
            id: ProviderRowState.ID(rawValue: "a"),
            before: nil
        )

        XCTAssertEqual(moved.map(\.id.rawValue), ["b", "c", "a"])
    }

    func testInvalidAndSelfMovesAreNoOps() {
        let rows = [row("a"), row("b")]

        XCTAssertEqual(
            AccountOrdering.moving(rows, id: "missing", before: "a"),
            rows
        )
        XCTAssertEqual(
            AccountOrdering.moving(rows, id: "a", before: "a"),
            rows
        )
    }

    private func row(_ id: String) -> ProviderRowState {
        ProviderRowState(
            id: ProviderRowState.ID(rawValue: id),
            name: id,
            nickname: "",
            functionName: id,
            connectionTitle: "Connected",
            connectionDetail: id,
            isConnected: true
        )
    }
}
