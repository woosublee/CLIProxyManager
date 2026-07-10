import Darwin
import Foundation

public enum CLICommandExitCode: Int32, Sendable {
    case success = 0
    case failure = 1
    case usage = 2
    case prerequisite = 3
}

public protocol CLICommandOutputWriting: Sendable {
    var isInteractive: Bool { get }
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
    func confirm(_ prompt: String) -> Bool
}

public struct TerminalCommandOutput: CLICommandOutputWriting {
    public init() {}

    public var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }

    public func writeStdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func confirm(_ prompt: String) -> Bool {
        writeStderr("\(prompt) [y/N] ")
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.lowercased())
    }
}
