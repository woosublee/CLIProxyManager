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

    public var apiKeysDirectory: URL {
        rootDirectory.appendingPathComponent("api-keys", isDirectory: true)
    }

    public func apiKeyFile(for reference: SecretReference) -> URL {
        apiKeysDirectory.appendingPathComponent("\(reference.rawValue).json")
    }

    public var apiUsageDirectory: URL {
        rootDirectory.appendingPathComponent("api-usage", isDirectory: true)
    }

    public var apiUsageMetadataFile: URL {
        apiUsageDirectory.appendingPathComponent("metadata.json")
    }

    public func apiUsageMonthlyLedgerFile(month: String) -> URL {
        apiUsageDirectory.appendingPathComponent("\(month).json")
    }

    public var roundRobinStateFile: URL {
        rootDirectory.appendingPathComponent("round-robin-state.json")
    }

    public var subscriptionUsageManagementKeyFile: URL {
        rootDirectory.appendingPathComponent("subscription-usage-management-key.json")
    }

    public var subscriptionUsageSnapshotCacheFile: URL {
        rootDirectory.appendingPathComponent("subscription-usage-snapshots.json")
    }

    public var claudeModelOptionsCacheFile: URL {
        rootDirectory.appendingPathComponent("claude-model-options.json")
    }

    public var cpmInstallationRecordFile: URL {
        rootDirectory.appendingPathComponent("cpm-installation.json")
    }

    public var logsDirectory: URL {
        rootDirectory.appendingPathComponent("logs")
    }

    public var backupsDirectory: URL {
        rootDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public var credentialMigrationBackupsDirectory: URL {
        backupsDirectory.appendingPathComponent("credential-migrations", isDirectory: true)
    }

    public var clipProxyDirectory: URL {
        rootDirectory.appendingPathComponent("cliproxyapi")
    }

    public var authDirectory: URL {
        rootDirectory.appendingPathComponent("auth", isDirectory: true)
    }

    public var proxyLogsDirectory: URL {
        authDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public var clipProxyConfigFile: URL {
        clipProxyDirectory.appendingPathComponent("config.yaml")
    }

    public var clipProxyBinary: URL {
        clipProxyDirectory.appendingPathComponent("cliproxyapi")
    }

    public var activeClipProxyManifest: URL {
        clipProxyDirectory.appendingPathComponent("active-manifest.json")
    }

    public var pendingClipProxyDirectory: URL {
        clipProxyDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    public var pendingClipProxyBinary: URL {
        pendingClipProxyDirectory.appendingPathComponent("cliproxyapi")
    }

    public var pendingClipProxyManifest: URL {
        pendingClipProxyDirectory.appendingPathComponent("manifest.json")
    }

    public var pendingClipProxyApplyOnNextStartMarker: URL {
        pendingClipProxyDirectory.appendingPathComponent("apply-on-next-start")
    }

    public var clipProxyUpdateStateFile: URL {
        clipProxyDirectory.appendingPathComponent("update-state.json")
    }

    public var appUpdatesDirectory: URL {
        rootDirectory.appendingPathComponent("updates/app", isDirectory: true)
    }

    public func appUpdateDirectory(build: Int) -> URL {
        appUpdatesDirectory.appendingPathComponent(String(build), isDirectory: true)
    }

    public func appUpdateManifest(build: Int) -> URL {
        appUpdateDirectory(build: build).appendingPathComponent("manifest.json")
    }

    public static func defaultRootDirectory() -> URL {
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cliproxy-manager", isDirectory: true)
        #if DEBUG
        return productionRoot.appendingPathComponent("dev", isDirectory: true)
        #else
        return productionRoot
        #endif
    }
}
