import CLIProxyManagerCore
import CryptoKit
import Foundation

enum CPMCompatibility {
    static let currentRevision = 1
}

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
    case installationFailed
    case removalFailed

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            "The bundled cpm helper is unavailable."
        case .unmanagedTarget:
            "The existing /usr/local/bin/cpm was not installed by CLIProxyManager."
        case .authorizationCancelled:
            "cpm operation was cancelled."
        case .installationFailed:
            "cpm installation failed."
        case .removalFailed:
            "cpm removal failed."
        }
    }
}

protocol CPMInstallationManaging {
    func status() -> CPMInstallationStatus
    func installOrUpdate() async throws
    func remove() async throws
}

protocol PrivilegedCPMCommandRunning: Sendable {
    func run(action: CPMInstallationAction, source: URL?, target: URL) async throws
}

struct AppleScriptPrivilegedCPMCommandRunner: PrivilegedCPMCommandRunning {
    func run(action: CPMInstallationAction, source: URL?, target: URL) async throws {
        try await Task.detached(priority: .utility) {
            try runBlocking(action: action, source: source)
        }.value
    }

    private func runBlocking(action: CPMInstallationAction, source: URL?) throws {
        let script = """
        on run argv
            set actionName to item 1 of argv
            set sourcePath to item 2 of argv
            if actionName is "install" then
                set quotedSource to quoted form of sourcePath
                do shell script "/bin/mkdir -p /usr/local/bin && /bin/rm -f /usr/local/bin/.cpm-install && /usr/bin/install -m 755 " & quotedSource & " /usr/local/bin/.cpm-install && /bin/mv -f /usr/local/bin/.cpm-install /usr/local/bin/cpm" with administrator privileges
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
            throw failure(for: action)
        }

        guard process.terminationStatus == 0 else {
            let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if output.contains("User canceled") || output.contains("-128") {
                throw CPMInstallationError.authorizationCancelled
            }
            throw failure(for: action)
        }
    }

    private func failure(for action: CPMInstallationAction) -> CPMInstallationError {
        action == .install ? .installationFailed : .removalFailed
    }
}

final class CPMInstallationService: CPMInstallationManaging {
    private struct InstallationRecord: Codable {
        let digest: String
        let appVersion: String
        let cpmRevision: Int?

        private enum CodingKeys: String, CodingKey {
            case digest
            case appVersion
            case cpmRevision
            case version
        }

        init(digest: String, appVersion: String, cpmRevision: Int) {
            self.digest = digest
            self.appVersion = appVersion
            self.cpmRevision = cpmRevision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            digest = try container.decode(String.self, forKey: .digest)
            appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
                ?? container.decode(String.self, forKey: .version)
            cpmRevision = try container.decodeIfPresent(Int.self, forKey: .cpmRevision)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(digest, forKey: .digest)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encodeIfPresent(cpmRevision, forKey: .cpmRevision)
        }
    }

    private let sourceURL: URL
    private let targetURL: URL
    private let bundledVersion: String
    private let availableVersion: () -> String
    private let currentRevision: Int
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
        self.currentRevision = CPMCompatibility.currentRevision
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    init(
        sourceURL: URL,
        targetURL: URL,
        bundledVersion: String,
        availableVersion: @escaping () -> String,
        currentRevision: Int,
        paths: ManagedPaths,
        runner: any PrivilegedCPMCommandRunning,
        fileManager: FileManager = .default
    ) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.bundledVersion = bundledVersion
        self.availableVersion = availableVersion
        self.currentRevision = currentRevision
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    func status() -> CPMInstallationStatus {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return .notInstalled
        }
        guard let record = readRecord(),
              let targetDigest = try? digest(of: targetURL),
              targetDigest == record.digest else {
            return .unmanaged
        }
        guard let installedRevision = record.cpmRevision,
              installedRevision >= 0 else {
            return .installedOutdated(
                installedVersion: record.appVersion,
                availableVersion: availableVersion()
            )
        }
        if installedRevision < currentRevision {
            return .installedOutdated(
                installedVersion: record.appVersion,
                availableVersion: availableVersion()
            )
        }
        return .installedCurrent(version: record.appVersion)
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

        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try await runner.run(action: .install, source: sourceURL, target: targetURL)
        guard let sourceDigest = try? digest(of: sourceURL),
              let targetDigest = try? digest(of: targetURL),
              sourceDigest == targetDigest else {
            throw CPMInstallationError.installationFailed
        }

        let record = InstallationRecord(
            digest: targetDigest,
            appVersion: bundledVersion,
            cpmRevision: currentRevision
        )
        try JSONEncoder().encode(record).write(to: paths.cpmInstallationRecordFile, options: .atomic)
    }

    func remove() async throws {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            try? fileManager.removeItem(at: paths.cpmInstallationRecordFile)
            return
        }
        guard status() != .unmanaged else {
            throw CPMInstallationError.unmanagedTarget
        }

        try await runner.run(action: .remove, source: nil, target: targetURL)
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            throw CPMInstallationError.removalFailed
        }
        try? fileManager.removeItem(at: paths.cpmInstallationRecordFile)
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
