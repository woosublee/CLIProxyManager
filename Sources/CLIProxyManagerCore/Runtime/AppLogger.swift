import Darwin
import Foundation
import OSLog

public enum AppLogResult: Equatable, Sendable {
    case started
    case succeeded
    case degraded(AppLogFailureKind)
    case failed(AppLogFailureKind)
    case cancelled
}

public enum AppLogFailureKind: String, Equatable, Sendable {
    case configuration
    case fileSystem = "file-system"
    case network
    case process
    case readiness
    case updateVerification = "update-verification"
    case unknown
}

public enum AppServerAction: String, Equatable, Sendable {
    case start
    case stop
    case restart
}

public enum AppUpdateTarget: String, Equatable, Sendable {
    case app
    case proxy
}

public enum AppUpdateAction: String, Equatable, Sendable {
    case check
    case download
    case stage
    case apply
}

public enum AppLogDebugContext: String, Equatable, Sendable {
    case configurationMigrationApplied = "configuration-migration-applied"
    case proxyRestartQueued = "proxy-restart-queued"
    case proxyRestartApplied = "proxy-restart-applied"
    case proxyRestartRolledBack = "proxy-restart-rolled-back"
    case updatePending = "update-pending"
}

public enum AppLogEvent: Equatable, Sendable {
    case applicationLaunch(AppLogResult)
    case configurationSave(AppLogResult)
    case server(action: AppServerAction, result: AppLogResult, port: Int)
    case update(target: AppUpdateTarget, action: AppUpdateAction, result: AppLogResult)
    case diagnostics(AppLogResult)
    case debug(AppLogDebugContext)

    fileprivate var minimumLevel: LogLevel {
        if case .debug = self { return .debug }
        return .info
    }

    fileprivate var isFailure: Bool {
        switch result {
        case .degraded, .failed:
            return true
        case .started, .succeeded, .cancelled, .none:
            return false
        }
    }

    fileprivate var result: AppLogResult? {
        switch self {
        case .applicationLaunch(let result), .configurationSave(let result), .diagnostics(let result):
            return result
        case .server(_, let result, _), .update(_, _, let result):
            return result
        case .debug:
            return nil
        }
    }

    fileprivate var fields: [String] {
        switch self {
        case .applicationLaunch(let result):
            return ["category=application", "event=launch", resultField(result)]
        case .configurationSave(let result):
            return ["category=configuration", "event=save", resultField(result)]
        case .server(let action, let result, let port):
            return [
                "category=server",
                "event=\(action.rawValue)",
                resultField(result),
                "port=\(port)"
            ]
        case .update(let target, let action, let result):
            return [
                "category=update",
                "target=\(target.rawValue)",
                "event=\(action.rawValue)",
                resultField(result)
            ]
        case .diagnostics(let result):
            return ["category=diagnostics", "event=file-sink", resultField(result)]
        case .debug(let context):
            return ["category=debug", "event=\(context.rawValue)"]
        }
    }

    private func resultField(_ result: AppLogResult) -> String {
        switch result {
        case .started:
            return "result=started"
        case .succeeded:
            return "result=succeeded"
        case .degraded(let failure):
            return "result=degraded failure=\(failure.rawValue)"
        case .failed(let failure):
            return "result=failed failure=\(failure.rawValue)"
        case .cancelled:
            return "result=cancelled"
        }
    }
}

public struct AppLogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let event: AppLogEvent

    public init(timestamp: Date, level: LogLevel, event: AppLogEvent) {
        self.timestamp = timestamp
        self.level = level
        self.event = event
    }

    public var line: String {
        let timestamp = ISO8601DateFormatter().string(from: timestamp)
        return ([timestamp, "level=\(level.rawValue)"] + event.fields).joined(separator: " ") + "\n"
    }
}

public enum AppLogDiagnosticsReason: String, Equatable, Sendable {
    case notConfigured = "not-configured"
    case unsafeDirectory = "unsafe-directory"
    case unsafeFile = "unsafe-file"
    case directoryUnavailable = "directory-unavailable"
    case writeFailed = "write-failed"
    case rotationFailed = "rotation-failed"
}

public enum AppLogDiagnostics: Equatable, Sendable {
    case available(fileURL: URL)
    case degraded(fileURL: URL, reason: AppLogDiagnosticsReason)
    case unavailable(reason: AppLogDiagnosticsReason)
}

public protocol AppLogSinking: Sendable {
    func write(_ entry: AppLogEntry) throws
}

public protocol AppLogFileWriting: AppLogSinking {
    var fileURL: URL { get }
    func prepare() throws
}

public protocol AppLogging: Sendable {
    var minimumLevel: LogLevel { get }
    var diagnostics: AppLogDiagnostics { get }
    func configure(minimumLevel: LogLevel)
    func record(_ event: AppLogEvent)
}

public struct DisabledAppLogger: AppLogging {
    public init() {}

    public var minimumLevel: LogLevel { .info }
    public var diagnostics: AppLogDiagnostics { .unavailable(reason: .notConfigured) }

    public func configure(minimumLevel _: LogLevel) {}
    public func record(_: AppLogEvent) {}
}

public struct UnifiedAppLogSink: AppLogSinking {
    private let logger: Logger

    public init(
        subsystem: String = "com.woosublee.CLIProxyManager",
        category: String = "runtime"
    ) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func write(_ entry: AppLogEntry) {
        let line = entry.line.trimmingCharacters(in: .newlines)
        if entry.event.isFailure {
            logger.error("\(line, privacy: .public)")
        } else if entry.level == .debug {
            logger.debug("\(line, privacy: .public)")
        } else {
            logger.info("\(line, privacy: .public)")
        }
    }
}

public final class AppLogger: AppLogging, @unchecked Sendable {
    private let lock = NSLock()
    private let fileWriter: (any AppLogFileWriting)?
    private let fallbackSink: any AppLogSinking
    private let now: @Sendable () -> Date
    private var configuredMinimumLevel: LogLevel
    private var diagnosticsState: AppLogDiagnostics

    public init(
        minimumLevel: LogLevel = .info,
        fileWriter: (any AppLogFileWriting)? = AppLogFileStore(),
        fallbackSink: any AppLogSinking = UnifiedAppLogSink(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        configuredMinimumLevel = minimumLevel
        self.fileWriter = fileWriter
        self.fallbackSink = fallbackSink
        self.now = now

        if let fileWriter {
            do {
                try fileWriter.prepare()
                diagnosticsState = .available(fileURL: fileWriter.fileURL)
            } catch {
                diagnosticsState = .degraded(
                    fileURL: fileWriter.fileURL,
                    reason: Self.diagnosticsReason(for: error)
                )
            }
        } else {
            diagnosticsState = .unavailable(reason: .notConfigured)
        }
    }

    public var minimumLevel: LogLevel {
        lock.withLock { configuredMinimumLevel }
    }

    public var diagnostics: AppLogDiagnostics {
        lock.withLock { diagnosticsState }
    }

    public func configure(minimumLevel: LogLevel) {
        lock.withLock {
            configuredMinimumLevel = minimumLevel
        }
    }

    public func record(_ event: AppLogEvent) {
        lock.withLock {
            guard shouldRecord(event) else { return }
            let entry = AppLogEntry(timestamp: now(), level: event.minimumLevel, event: event)
            try? fallbackSink.write(entry)
            guard let fileWriter else { return }
            do {
                try fileWriter.write(entry)
                diagnosticsState = .available(fileURL: fileWriter.fileURL)
            } catch {
                diagnosticsState = .degraded(
                    fileURL: fileWriter.fileURL,
                    reason: Self.diagnosticsReason(for: error)
                )
            }
        }
    }

    private func shouldRecord(_ event: AppLogEvent) -> Bool {
        configuredMinimumLevel == .debug || event.minimumLevel == .info
    }

    private static func diagnosticsReason(for error: Error) -> AppLogDiagnosticsReason {
        (error as? AppLogFileError)?.diagnosticsReason ?? .writeFailed
    }
}

public enum AppLogFileError: Error, Equatable {
    case unsafeDirectory
    case unsafeFile
    case directoryUnavailable
    case writeFailed
    case rotationFailed

    var diagnosticsReason: AppLogDiagnosticsReason {
        switch self {
        case .unsafeDirectory: .unsafeDirectory
        case .unsafeFile: .unsafeFile
        case .directoryUnavailable: .directoryUnavailable
        case .writeFailed: .writeFailed
        case .rotationFailed: .rotationFailed
        }
    }
}

public struct AppLogFileStore: AppLogFileWriting, @unchecked Sendable {
    public static let defaultMaximumFileSize = 1_048_576

    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let maximumFileSize: Int

    public init(
        paths: ManagedPaths = ManagedPaths(),
        fileManager: FileManager = .default,
        maximumFileSize: Int = AppLogFileStore.defaultMaximumFileSize
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.maximumFileSize = max(1, maximumFileSize)
    }

    public var fileURL: URL { paths.appLogFile }

    public static func validatedExistingLogFile(at fileURL: URL) throws -> URL {
        let directoryURL = fileURL.deletingLastPathComponent()
        var directoryStatus = stat()
        guard lstat(directoryURL.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == getuid(),
              Int(directoryStatus.st_mode) & 0o777 == 0o700 else {
            throw AppLogFileError.unsafeDirectory
        }

        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AppLogFileError.unsafeFile }
        defer { close(descriptor) }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == getuid(),
              Int(fileStatus.st_mode) & 0o777 == 0o600 else {
            throw AppLogFileError.unsafeFile
        }
        return fileURL
    }

    public func prepare() throws {
        try prepareLogsDirectory()
        let descriptor = try openValidatedLogFile()
        close(descriptor)
    }

    public func write(_ entry: AppLogEntry) throws {
        try prepareLogsDirectory()
        let data = Data(entry.line.utf8)
        var descriptor = try openValidatedLogFile()
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw AppLogFileError.writeFailed
        }

        if Int(status.st_size) + data.count > maximumFileSize {
            close(descriptor)
            try rotateLogFile()
            descriptor = try openValidatedLogFile()
        }
        defer { close(descriptor) }
        try writeAll(data, to: descriptor)
    }

    private func prepareLogsDirectory() throws {
        do {
            try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        } catch {
            throw AppLogFileError.directoryUnavailable
        }

        var status = stat()
        guard lstat(paths.logsDirectory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid() else {
            throw AppLogFileError.unsafeDirectory
        }
        guard chmod(paths.logsDirectory.path, S_IRWXU) == 0,
              lstat(paths.logsDirectory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              Int(status.st_mode) & 0o777 == 0o700 else {
            throw AppLogFileError.unsafeDirectory
        }
    }

    private func openValidatedLogFile() throws -> Int32 {
        let descriptor = open(
            paths.appLogFile.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            var status = stat()
            if lstat(paths.appLogFile.path, &status) == 0 {
                throw AppLogFileError.unsafeFile
            }
            throw AppLogFileError.writeFailed
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fstat(descriptor, &status) == 0,
              Int(status.st_mode) & 0o777 == 0o600 else {
            close(descriptor)
            throw AppLogFileError.unsafeFile
        }
        return descriptor
    }

    private func rotateLogFile() throws {
        var sourceStatus = stat()
        guard lstat(paths.appLogFile.path, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG,
              sourceStatus.st_uid == getuid() else {
            throw AppLogFileError.unsafeFile
        }

        var backupStatus = stat()
        if lstat(paths.rotatedAppLogFile.path, &backupStatus) == 0 {
            guard backupStatus.st_mode & S_IFMT == S_IFREG,
                  backupStatus.st_uid == getuid(),
                  unlink(paths.rotatedAppLogFile.path) == 0 else {
                throw AppLogFileError.rotationFailed
            }
        } else if errno != ENOENT {
            throw AppLogFileError.rotationFailed
        }

        guard rename(paths.appLogFile.path, paths.rotatedAppLogFile.path) == 0 else {
            throw AppLogFileError.rotationFailed
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var writtenBytes = 0
            while writtenBytes < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenBytes),
                    buffer.count - writtenBytes
                )
                guard result > 0 else { throw AppLogFileError.writeFailed }
                writtenBytes += result
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
