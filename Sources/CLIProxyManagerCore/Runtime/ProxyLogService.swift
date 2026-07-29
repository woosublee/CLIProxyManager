import Foundation

public struct TailProcessFollower: LogFollowing, Sendable {
    public init() {}

    public func follow(fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "0", "-F", fileURL.path]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
    }
}

public struct ProxyLogService: ProxyLogServicing, Sendable {
    private let paths: ManagedPaths
    private let follower: any LogFollowing

    public init(paths: ManagedPaths = ManagedPaths(), follower: any LogFollowing = TailProcessFollower()) {
        self.paths = paths
        self.follower = follower
    }

    public func selectedLogFile() throws -> URL {
        try selectLogFile()
    }

    public func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot {
        let fileURL = try selectLogFile()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let trailingNewline = text.hasSuffix("\n")
        // components(separatedBy:) with omittingEmptySubsequences: false gives us all splits
        // The last element is "" when text ends in \n
        let contentLines = trailingNewline ? Array(lines.dropLast()) : lines
        let selected = contentLines.suffix(max(0, lineCount))
        let result = selected.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return ProxyLogSnapshot(fileURL: fileURL, text: result)
    }

    public func follow() throws {
        let fileURL = try selectLogFile()
        try follower.follow(fileURL: fileURL)
    }

    private func selectLogFile() throws -> URL {
        let logsDir = paths.proxyLogsDirectory
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

        let contents = (try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []

        var candidates: [(url: URL, modDate: Date)] = []
        for url in contents {
            guard url.pathExtension == "log" else { continue }
            let res = try url.resourceValues(forKeys: Set(keys))
            guard res.isRegularFile == true, res.isSymbolicLink != true else {
                if res.isSymbolicLink == true {
                    throw CLIProxyManagerCommandError.operation("Log file is a symlink outside managed logs directory: \(url.path)")
                }
                continue
            }
            // Confirm resolved path stays inside proxyLogsDirectory
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(logsDir.resolvingSymlinksInPath().path) else {
                throw CLIProxyManagerCommandError.operation("Log file resolves outside managed logs directory: \(url.path)")
            }
            let modDate = res.contentModificationDate ?? .distantPast
            candidates.append((url: url, modDate: modDate))
        }

        if let main = candidates.first(where: { $0.url.lastPathComponent == "main.log" }) {
            return main.url
        }
        guard let best = candidates.sorted(by: { $0.modDate > $1.modDate }).first else {
            throw CLIProxyManagerCommandError.operation("No proxy log files found in \(logsDir.path).")
        }
        return best.url
    }
}
