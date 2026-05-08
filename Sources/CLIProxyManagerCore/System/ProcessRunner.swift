import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        await Task.detached(priority: .utility) {
            runBlocking(executable, arguments, timeout: timeout)
        }.value
    }
}

private func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return ProcessResult(exitCode: 127, stdout: "", stderr: String(describing: error))
    }

    let stdoutGroup = DispatchGroup()
    let stderrGroup = DispatchGroup()
    var stdoutData = Data()
    var stderrData = Data()

    stdoutGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutGroup.leave()
    }

    stderrGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stderrGroup.leave()
    }

    let deadline = DispatchTime.now() + timeout
    let timedOut = process.waitUntilExit(until: deadline) == false
    if timedOut {
        process.terminate()
        if process.waitUntilExit(until: DispatchTime.now() + 0.5) == false {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    stdoutGroup.wait()
    stderrGroup.wait()

    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    if timedOut {
        let timeoutMessage = String(format: "Process timed out after %.1f seconds", timeout)
        return ProcessResult(exitCode: 124, stdout: stdout, stderr: stderr.isEmpty ? timeoutMessage : stderr, timedOut: true)
    }

    return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private extension Process {
    func waitUntilExit(until deadline: DispatchTime) -> Bool {
        while isRunning {
            if DispatchTime.now() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
