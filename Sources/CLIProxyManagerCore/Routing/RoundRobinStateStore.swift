import Darwin
import Foundation

public protocol RoundRobinStateSelecting: Sendable {
    func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String
}

public enum RoundRobinStateStoreError: Error, Equatable, LocalizedError {
    case emptyCandidates(String)
    case lockFailed(String)
    case stateReadFailed(String)
    case stateWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCandidates(let groupID):
            "Round-robin group `\(groupID)` has no candidates."
        case .lockFailed(let path):
            "Failed to lock round-robin state file `\(path)`."
        case .stateReadFailed(let path):
            "Failed to read round-robin state file `\(path)`."
        case .stateWriteFailed(let path):
            "Failed to write round-robin state file `\(path)`."
        }
    }
}

public struct RoundRobinStateStore: RoundRobinStateSelecting, @unchecked Sendable {
    private struct State: Codable, Equatable {
        var groups: [String: GroupState] = [:]
    }

    private struct GroupState: Codable, Equatable {
        var lastSelectedAuthProfileID: String
    }

    private let stateFile: URL
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.init(stateFile: paths.roundRobinStateFile, fileManager: fileManager)
    }

    public init(stateFile: URL, fileManager: FileManager = .default) {
        self.stateFile = stateFile
        self.fileManager = fileManager
    }

    public func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String {
        guard !candidates.isEmpty else { throw RoundRobinStateStoreError.emptyCandidates(groupID) }
        try fileManager.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        return try withExclusiveLock {
            var state = try readState()
            let selected = Self.nextCandidate(after: state.groups[groupID]?.lastSelectedAuthProfileID, candidates: candidates)
            state.groups[groupID] = GroupState(lastSelectedAuthProfileID: selected)
            try writeState(state)
            return selected
        }
    }

    private static func nextCandidate(after previous: String?, candidates: [String]) -> String {
        guard let previous, let index = candidates.firstIndex(of: previous) else {
            return candidates[0]
        }
        let nextIndex = candidates.index(after: index)
        return nextIndex == candidates.endIndex ? candidates[0] : candidates[nextIndex]
    }

    private func readState() throws -> State {
        guard fileManager.fileExists(atPath: stateFile.path) else { return State() }

        do {
            let data = try Data(contentsOf: stateFile)
            guard !data.isEmpty else { return State() }
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            throw RoundRobinStateStoreError.stateReadFailed(stateFile.path)
        }
    }

    private func writeState(_ state: State) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            throw RoundRobinStateStoreError.stateWriteFailed(stateFile.path)
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockFile = stateFile.appendingPathExtension("lock")
        let fileDescriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { throw RoundRobinStateStoreError.lockFailed(lockFile.path) }
        defer { close(fileDescriptor) }

        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            throw RoundRobinStateStoreError.lockFailed(lockFile.path)
        }
        defer { _ = flock(fileDescriptor, LOCK_UN) }

        return try body()
    }
}
