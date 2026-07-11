import CLIProxyManagerCore
import CryptoKit
import Foundation

enum CPMInstallationStatus: Equatable {
    case notInstalled
    case installedCurrent(version: String)
    case installedOutdated(installedVersion: String, availableVersion: String)
    case unmanaged
}

enum CPMInstallationAction: String, Sendable {
    case install
    case remove
}

enum CPMInstallationError: Error, Equatable, LocalizedError {
    case bundledHelperMissing
    case unmanagedTarget
    case authorizationCancelled
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            "The bundled cpm helper is unavailable."
        case .unmanagedTarget:
            "The existing /usr/local/bin/cpm was not installed by CLIProxyManager."
        case .authorizationCancelled:
            "cpm installation was cancelled."
        case .operationFailed:
            "cpm installation failed."
        }
    }
}

protocol CPMInstallationManaging {
    func status() -> CPMInstallationStatus
    func installOrUpdate() async throws
    func remove() async throws
}

protocol PrivilegedCPMCommandRunning: Sendable {
    func run(action: CPMInstallationAction, source: URL?, target: URL) throws
}

struct AppleScriptPrivilegedCPMCommandRunner: PrivilegedCPMCommandRunning {
    func run(action: CPMInstallationAction, source: URL?, target: URL) throws {
        let script = """
        on run argv
            set actionName to item 1 of argv
            set sourcePath to item 2 of argv
            if actionName is "install" then
                set quotedSource to quoted form of sourcePath
                do shell script "/bin/rm -f /usr/local/bin/.cpm-install && /usr/bin/install -m 755 " & quotedSource & " /usr/local/bin/.cpm-install && /bin/mv -f /usr/local/bin/.cpm-install /usr/local/bin/cpm" with administrator privileges
            else if actionName is "remove" then
                do shell script "/bin/rm -f /usr/local/bin/cpm" with administrator privileges
            else
                error "Unsupported cpm installation action"
            end if
        end run
        """

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, action.rawValue, source?.path ?? ""]
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CPMInstallationError.operationFailed
        }

        guard process.terminationStatus == 0 else {
            let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if output.contains("User canceled") || output.contains("-128") {
                throw CPMInstallationError.authorizationCancelled
            }
            throw CPMInstallationError.operationFailed
        }
    }
}

final class CPMInstallationService: CPMInstallationManaging {
    private struct InstallationRecord: Codable {
        let digest: String
        let version: String
    }

    private let sourceURL: URL
    private let targetURL: URL
    private let bundledVersion: String
    private let availableVersion: () -> String
    private let paths: ManagedPaths
    private let runner: any PrivilegedCPMCommandRunning
    private let fileManager: FileManager

    init(
        bundle: Bundle = .main,
        paths: ManagedPaths = ManagedPaths(),
        runner: any PrivilegedCPMCommandRunning = AppleScriptPrivilegedCPMCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.sourceURL = bundle.bundleURL.appendingPathComponent("Contents/Helpers/cpm")
        self.targetURL = URL(fileURLWithPath: "/usr/local/bin/cpm")
        self.bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        self.availableVersion = { bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    init(
        sourceURL: URL,
        targetURL: URL,
        bundledVersion: String,
        availableVersion: @escaping () -> String,
        paths: ManagedPaths,
        runner: any PrivilegedCPMCommandRunning,
        fileManager: FileManager = .default
    ) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.bundledVersion = bundledVersion
        self.availableVersion = availableVersion
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    func status() -> CPMInstallationStatus {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return .notInstalled
        }
        guard let record = readRecord(), let targetDigest = try? digest(of: targetURL), targetDigest == record.digest else {
            return .unmanaged
        }
        guard let sourceDigest = try? digest(of: sourceURL) else {
            return .installedOutdated(installedVersion: record.version, availableVersion: availableVersion())
        }
        if sourceDigest == targetDigest {
            return .installedCurrent(version: record.version)
        }
        return .installedOutdated(installedVersion: record.version, availableVersion: availableVersion())
    }

    func installOrUpdate() async throws {
        switch status() {
        case .unmanaged:
            throw CPMInstallationError.unmanagedTarget
        case .notInstalled, .installedCurrent, .installedOutdated:
            break
        }

        guard fileManager.isExecutableFile(atPath: sourceURL.path) else {
            throw CPMInstallationError.bundledHelperMissing
        }

        try runner.run(action: .install, source: sourceURL, target: targetURL)
        guard let sourceDigest = try? digest(of: sourceURL),
              let targetDigest = try? digest(of: targetURL),
              sourceDigest == targetDigest else {
            throw CPMInstallationError.operationFailed
        }

        let record = InstallationRecord(digest: targetDigest, version: bundledVersion)
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: paths.cpmInstallationRecordFile, options: .atomic)
    }

    func remove() async throws {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            try? fileManager.removeItem(at: paths.cpmInstallationRecordFile)
            return
        }
        guard case .unmanaged = status() else {
            try runner.run(action: .remove, source: nil, target: targetURL)
            guard !fileManager.fileExists(atPath: targetURL.path) else {
                throw CPMInstallationError.operationFailed
            }
            try? fileManager.removeItem(at: paths.cpmInstallationRecordFile)
            return
        }
        throw CPMInstallationError.unmanagedTarget
    }

    private func readRecord() -> InstallationRecord? {
        guard let data = try? Data(contentsOf: paths.cpmInstallationRecordFile) else { return nil }
        return try? JSONDecoder().decode(InstallationRecord.self, from: data)
    }

    private func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
