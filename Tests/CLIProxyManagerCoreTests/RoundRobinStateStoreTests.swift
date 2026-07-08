import XCTest
@testable import CLIProxyManagerCore

final class RoundRobinStateStoreTests: XCTestCase {
    func testNoPreviousStateSelectsFirstCandidateAndPersists() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        let selected = try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"])

        XCTAssertEqual(selected, "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
    }

    func testLastCandidateWrapsToFirstCandidate() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
    }

    func testMissingLastCandidateFallsBackToFirstCandidate() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["c.json", "d.json"]), "c.json")
    }

    func testGroupStatesAreIndependent() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "a.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "claude-default", candidates: ["x.json", "y.json"]), "x.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: ["a.json", "b.json"]), "b.json")
        XCTAssertEqual(try store.nextSelectedAuthProfileID(groupID: "claude-default", candidates: ["x.json", "y.json"]), "y.json")
    }

    func testEmptyCandidatesThrow() throws {
        let sandbox = try makeSandbox()
        let store = RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try store.nextSelectedAuthProfileID(groupID: "codex-default", candidates: [])) { error in
            XCTAssertEqual(error as? RoundRobinStateStoreError, .emptyCandidates("codex-default"))
        }
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
