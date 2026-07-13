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

    func testDuplicateRowIDsKeepTheFirstRowWithoutCrashing() {
        let first = row("duplicate", detail: "first")
        let second = row("duplicate", detail: "second")

        let ordered = AccountOrdering.orderedRows(
            [first, second, row("other")],
            storedIDs: ["duplicate", "other"]
        )

        XCTAssertEqual(ordered.map(\.id.rawValue), ["duplicate", "other"])
        XCTAssertEqual(ordered.first?.connectionDetail, "first")
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

    func testMovingIDsSupportsLivePreviewAcrossMultiplePositions() {
        let ids: [ProviderRowState.ID] = ["a", "b", "c", "d"]

        XCTAssertEqual(
            AccountOrdering.moving(ids, id: "a", before: "d"),
            ["b", "c", "a", "d"]
        )
        XCTAssertEqual(
            AccountOrdering.moving(ids, id: "d", before: "a"),
            ["d", "a", "b", "c"]
        )
        XCTAssertEqual(
            AccountOrdering.moving(ids, id: "b", before: nil),
            ["a", "c", "d", "b"]
        )
    }

    func testInsertionIndexUsesEachRemainingCardMidpoint() {
        let ids: [ProviderRowState.ID] = ["a", "b", "c"]
        let frames: [ProviderRowState.ID: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 60),
            "b": CGRect(x: 0, y: 66, width: 300, height: 60),
            "c": CGRect(x: 0, y: 132, width: 300, height: 60)
        ]

        XCTAssertEqual(
            AccountOrdering.insertionIndex(for: 20, orderedIDs: ids, dragging: "b", frames: frames),
            0
        )
        XCTAssertEqual(
            AccountOrdering.insertionIndex(for: 30, orderedIDs: ids, dragging: "b", frames: frames),
            1
        )
        XCTAssertEqual(
            AccountOrdering.insertionIndex(for: 160, orderedIDs: ids, dragging: "b", frames: frames),
            1
        )
        XCTAssertEqual(
            AccountOrdering.insertionIndex(for: 162, orderedIDs: ids, dragging: "b", frames: frames),
            2
        )
    }

    func testInsertionIndexReturnsNilUntilEveryRemainingCardHasAFrame() {
        let ids: [ProviderRowState.ID] = ["a", "b", "c"]
        let frames: [ProviderRowState.ID: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 60)
        ]

        XCTAssertNil(
            AccountOrdering.insertionIndex(for: 20, orderedIDs: ids, dragging: "b", frames: frames)
        )
    }

    private func row(_ id: String, detail: String? = nil) -> ProviderRowState {
        ProviderRowState(
            id: ProviderRowState.ID(rawValue: id),
            name: id,
            nickname: "",
            functionName: id,
            connectionTitle: "Connected",
            connectionDetail: detail ?? id,
            isConnected: true
        )
    }
}
