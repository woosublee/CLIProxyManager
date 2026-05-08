import Foundation

public struct ManagedPaths: Equatable, Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL = ManagedPaths.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    public var functionsFile: URL {
        rootDirectory.appendingPathComponent("functions.zsh")
    }

    public var configFile: URL {
        rootDirectory.appendingPathComponent("config.json")
    }

    public var logsDirectory: URL {
        rootDirectory.appendingPathComponent("logs")
    }

    public var clipProxyDirectory: URL {
        rootDirectory.appendingPathComponent("cliproxyapi")
    }

    public var clipProxyConfigFile: URL {
        clipProxyDirectory.appendingPathComponent("config.yaml")
    }

    public var clipProxyBinary: URL {
        clipProxyDirectory.appendingPathComponent("cliproxyapi")
    }

    public static func defaultRootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cliproxy-manager", isDirectory: true)
    }
}
