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
    var stdoutPipe: [Int32] = [0, 0]
    var stderrPipe: [Int32] = [0, 0]
    guard pipe(&stdoutPipe) == 0 else {
        return ProcessResult(exitCode: 127, stdout: "", stderr: String(cString: strerror(errno)))
    }
    guard pipe(&stderrPipe) == 0 else {
        close(stdoutPipe[0])
        close(stdoutPipe[1])
        return ProcessResult(exitCode: 127, stdout: "", stderr: String(cString: strerror(errno)))
    }

    let stdoutReader = PipeDrain(fileDescriptor: stdoutPipe[0])
    let stderrReader = PipeDrain(fileDescriptor: stderrPipe[0])
    stdoutReader.start()
    stderrReader.start()

    var writeEndsAreClosed = false
    func closeWriteEnds() {
        guard writeEndsAreClosed == false else { return }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        writeEndsAreClosed = true
    }

    func setupFailure(_ errorCode: Int32) -> ProcessResult {
        closeWriteEnds()
        let stdout = String(data: stdoutReader.finish(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrReader.finish(), encoding: .utf8) ?? ""
        let message = String(cString: strerror(errorCode))
        return ProcessResult(exitCode: 127, stdout: stdout, stderr: stderr.isEmpty ? message : "\(message)\n\(stderr)")
    }

    var actions: posix_spawn_file_actions_t?
    let actionsInit = posix_spawn_file_actions_init(&actions)
    guard actionsInit == 0 else { return setupFailure(actionsInit) }
    defer { posix_spawn_file_actions_destroy(&actions) }

    let actionResults = [
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
        posix_spawn_file_actions_addclose(&actions, stderrPipe[1])
    ]
    if let errorCode = actionResults.first(where: { $0 != 0 }) {
        return setupFailure(errorCode)
    }

    var attributes: posix_spawnattr_t?
    let attributesInit = posix_spawnattr_init(&attributes)
    guard attributesInit == 0 else { return setupFailure(attributesInit) }
    defer { posix_spawnattr_destroy(&attributes) }

    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    let attributeResults = [
        posix_spawnattr_setflags(&attributes, flags),
        posix_spawnattr_setpgroup(&attributes, 0)
    ]
    if let errorCode = attributeResults.first(where: { $0 != 0 }) {
        return setupFailure(errorCode)
    }

    var pid = pid_t()
    let environment = ProcessInfo.processInfo.environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    let spawnError = withCStringArray([executable] + arguments) { argv in
        withCStringArray(environment) { envp in
            posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        }
    }

    closeWriteEnds()

    guard spawnError == 0 else {
        return setupFailure(spawnError)
    }

    let deadline = DispatchTime.now() + timeout
    var exitCode = waitForProcess(pid, until: deadline)
    let timedOut = exitCode == nil

    if timedOut {
        terminateProcessGroup(pid, signal: SIGTERM)
        exitCode = waitForProcess(pid, until: DispatchTime.now() + 0.5)
        if exitCode == nil {
            terminateProcessGroup(pid, signal: SIGKILL)
            exitCode = waitForProcess(pid, until: DispatchTime.now() + 0.5)
        }
    }

    let stdout = String(data: stdoutReader.finish(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrReader.finish(), encoding: .utf8) ?? ""

    if timedOut {
        let timeoutMessage = String(format: "Process timed out after %.1f seconds", timeout)
        return ProcessResult(exitCode: 124, stdout: stdout, stderr: stderr.isEmpty ? timeoutMessage : stderr, timedOut: true)
    }

    return ProcessResult(exitCode: exitCode ?? 127, stdout: stdout, stderr: stderr)
}

private final class PipeDrain: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue = DispatchQueue(label: "io.woosublee.CLIProxyManager.ProcessRunner.PipeDrain")
    private let source: DispatchSourceRead
    private var data = Data()
    private var isCancelled = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setCancelHandler { close(fileDescriptor) }
    }

    func start() {
        source.setEventHandler { [weak self] in
            self?.drainAvailable()
        }
        source.resume()
    }

    func finish() -> Data {
        queue.sync {
            drainAvailable()
            if isCancelled == false {
                isCancelled = true
                source.cancel()
            }
            return data
        }
    }

    private func drainAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                if isCancelled == false {
                    isCancelled = true
                    source.cancel()
                }
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                if isCancelled == false {
                    isCancelled = true
                    source.cancel()
                }
                return
            }
        }
    }
}

private func waitForProcess(_ pid: pid_t, until deadline: DispatchTime) -> Int32? {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return exitCode(fromWaitStatus: status)
        }
        if result == -1 {
            return 127
        }
        if DispatchTime.now() >= deadline {
            return nil
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func exitCode(fromWaitStatus status: Int32) -> Int32 {
    let statusByte = status & 0x7f
    if statusByte == 0 {
        return (status >> 8) & 0xff
    }
    if statusByte != 0x7f {
        return 128 + statusByte
    }
    return status
}

private func terminateProcessGroup(_ pid: pid_t, signal: Int32) {
    if kill(-pid, signal) != 0 {
        kill(pid, signal)
    }
}

private func withCStringArray<Result>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
    var cStrings = strings.map { strdup($0) }
    cStrings.append(nil)
    defer {
        for pointer in cStrings where pointer != nil {
            free(pointer)
        }
    }
    return cStrings.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
