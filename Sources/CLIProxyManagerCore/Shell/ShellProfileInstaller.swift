import Foundation

public enum ShellProfileInstallerError: LocalizedError, Equatable {
    case functionNameConflicts([String])

    public var errorDescription: String? {
        switch self {
        case .functionNameConflicts(let names):
            let list = names.map { "`\($0)`" }.joined(separator: ", ")
            return "Cannot install shell functions: \(list) is already defined as an alias or function in ~/.zshrc. Pick a different command name in account settings, or remove the existing definition from your shell profile."
        }
    }
}

public struct ShellProfileInstaller: @unchecked Sendable {
    private let paths: ManagedPaths
    private let zshrcFile: URL
    private let fileManager: FileManager

    private var beginMarkerLine: String { "# >>> CLIProxyAPI Manager >>>" }
    private var endMarkerLine: String { "# <<< CLIProxyAPI Manager <<<" }
    private var sourceLine: String { "source \(shellSingleQuoted(paths.functionsFile.path))" }
    private var managedBlock: String {
        beginMarkerLine + "\n" + sourceLine + "\n" + endMarkerLine + "\n"
    }

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
        try install(functionScript: functionScript, functionNames: [])
    }

    public func install(functionScript: String, functionNames: [String]) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)

        let currentProfile = try readProfileIfPresent()
        let conflicts = conflictingNames(functionNames, in: currentProfile)
        guard conflicts.isEmpty else {
            throw ShellProfileInstallerError.functionNameConflicts(conflicts)
        }

        try functionScript.write(to: paths.functionsFile, atomically: true, encoding: .utf8)

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
        return containsManagedBlock(in: profile)
    }

    private func readProfileIfPresent() throws -> String {
        guard fileManager.fileExists(atPath: zshrcFile.path) else { return "" }
        return try String(contentsOf: zshrcFile, encoding: .utf8)
    }

    private func conflictingNames(_ names: [String], in profile: String) -> [String] {
        let unmanagedProfile = profileByUninstalling(from: profile)
        let lines = unmanagedProfile.components(separatedBy: .newlines)
        return names.filter { name in
            lines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("alias \(name)=") ||
                    trimmed.hasPrefix("\(name)()") ||
                    trimmed == "function \(name)" ||
                    trimmed.hasPrefix("function \(name) ") ||
                    trimmed.hasPrefix("function \(name)()")
            }
        }
    }

    private func profileByInstalling(in profile: String) -> String {
        var updatedProfile = profileByUninstalling(from: profile)
        if !updatedProfile.isEmpty, !updatedProfile.hasSuffix("\n") {
            updatedProfile += "\n"
        }
        return updatedProfile + managedBlock
    }

    private func profileByUninstalling(from profile: String) -> String {
        var updatedProfile = ""
        var searchStart = profile.startIndex

        while let blockRange = nextManagedBlockRange(in: profile, from: searchStart) {
            updatedProfile += profile[searchStart..<blockRange.lowerBound]
            searchStart = blockRange.upperBound
        }

        updatedProfile += profile[searchStart...]
        return updatedProfile
    }

    private func containsManagedBlock(in profile: String) -> Bool {
        guard let blockRange = nextManagedBlockRange(in: profile, from: profile.startIndex) else { return false }
        return profile[blockRange].components(separatedBy: .newlines).contains(sourceLine)
    }

    private func nextManagedBlockRange(in profile: String, from startIndex: String.Index) -> Range<String.Index>? {
        var searchStart = startIndex

        while let beginRange = profile.range(of: beginMarkerLine, range: searchStart..<profile.endIndex) {
            let beginsAtLineStart = beginRange.lowerBound == profile.startIndex || profile[profile.index(before: beginRange.lowerBound)] == "\n"
            let beginLineEnd = profile[beginRange.upperBound...].firstIndex(of: "\n") ?? profile.endIndex
            let beginIsFullLine = beginLineEnd == beginRange.upperBound

            guard beginsAtLineStart, beginIsFullLine else {
                searchStart = beginRange.upperBound
                continue
            }

            let contentStart = beginLineEnd == profile.endIndex ? profile.endIndex : profile.index(after: beginLineEnd)
            guard let endRange = profile.range(of: endMarkerLine, range: contentStart..<profile.endIndex) else {
                return nil
            }

            let endStartsAtLineStart = endRange.lowerBound == profile.startIndex || profile[profile.index(before: endRange.lowerBound)] == "\n"
            let endLineEnd = profile[endRange.upperBound...].firstIndex(of: "\n") ?? profile.endIndex
            let endIsFullLine = endLineEnd == endRange.upperBound

            guard endStartsAtLineStart, endIsFullLine else {
                searchStart = endRange.upperBound
                continue
            }

            let blockEnd = endLineEnd == profile.endIndex ? profile.endIndex : profile.index(after: endLineEnd)
            return beginRange.lowerBound..<blockEnd
        }

        return nil
    }

    private func shellSingleQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
