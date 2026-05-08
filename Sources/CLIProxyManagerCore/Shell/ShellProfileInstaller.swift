import Foundation

public struct ShellProfileInstaller: @unchecked Sendable {
    private let paths: ManagedPaths
    private let zshrcFile: URL
    private let fileManager: FileManager

    private var markerLine: String { "# CLIProxyAPI Manager" }
    private var sourceLine: String { "source \(paths.functionsFile.path)" }

    public init(
        paths: ManagedPaths,
        zshrcFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc"),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.zshrcFile = zshrcFile
        self.fileManager = fileManager
    }

    public func install(functionScript: String) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try functionScript.write(to: paths.functionsFile, atomically: true, encoding: .utf8)

        let currentProfile = try readProfileIfPresent()
        let updatedProfile = profileByInstalling(in: currentProfile)
        guard updatedProfile != currentProfile else { return }

        try backupProfileIfPresent()
        try updatedProfile.write(to: zshrcFile, atomically: true, encoding: .utf8)
    }

    public func uninstall() throws {
        let currentProfile = try readProfileIfPresent()
        let updatedProfile = profileByUninstalling(from: currentProfile)
        guard updatedProfile != currentProfile else { return }

        try backupProfileIfPresent()
        try updatedProfile.write(to: zshrcFile, atomically: true, encoding: .utf8)
    }

    public func isInstalled() -> Bool {
        guard let profile = try? readProfileIfPresent() else { return false }
        return profile.components(separatedBy: .newlines).contains(sourceLine)
    }

    private func readProfileIfPresent() throws -> String {
        guard fileManager.fileExists(atPath: zshrcFile.path) else { return "" }
        return try String(contentsOf: zshrcFile, encoding: .utf8)
    }

    private func profileByInstalling(in profile: String) -> String {
        var updatedProfile = profileByUninstalling(from: profile)
        if !updatedProfile.isEmpty, !updatedProfile.hasSuffix("\n") {
            updatedProfile += "\n"
        }
        return updatedProfile + markerLine + "\n" + sourceLine + "\n"
    }

    private func profileByUninstalling(from profile: String) -> String {
        let hadTrailingNewline = profile.hasSuffix("\n")
        let lines = profile.components(separatedBy: .newlines)
        var keptLines: [String] = []
        keptLines.reserveCapacity(lines.count)

        for line in lines {
            if line == markerLine || line == sourceLine { continue }
            keptLines.append(line)
        }
        if hadTrailingNewline, keptLines.last == "" {
            keptLines.removeLast()
        }

        var updatedProfile = keptLines.joined(separator: "\n")
        if hadTrailingNewline, !updatedProfile.isEmpty, !updatedProfile.hasSuffix("\n") {
            updatedProfile += "\n"
        }
        return updatedProfile
    }

    private func backupProfileIfPresent() throws {
        guard fileManager.fileExists(atPath: zshrcFile.path) else { return }
        let backupURL = zshrcFile.deletingLastPathComponent()
            .appendingPathComponent(".zshrc.cliproxy-manager.\(backupStamp())")
        try fileManager.copyItem(at: zshrcFile, to: backupURL)
    }

    private func backupStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()) + "." + UUID().uuidString
    }
}
