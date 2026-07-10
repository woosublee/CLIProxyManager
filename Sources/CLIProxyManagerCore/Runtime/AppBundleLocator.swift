import Foundation

public struct ManagedAppBundle: Equatable, Sendable {
    public let appURL: URL
    public let proxyBinaryURL: URL
    public let proxyManifestURL: URL
    public let version: String
    public let build: String
    public let cpmHelperURL: URL?
    public let legacyHelperURL: URL?

    public init(
        appURL: URL,
        proxyBinaryURL: URL,
        proxyManifestURL: URL,
        version: String,
        build: String,
        cpmHelperURL: URL? = nil,
        legacyHelperURL: URL? = nil
    ) {
        self.appURL = appURL
        self.proxyBinaryURL = proxyBinaryURL
        self.proxyManifestURL = proxyManifestURL
        self.version = version
        self.build = build
        self.cpmHelperURL = cpmHelperURL
        self.legacyHelperURL = legacyHelperURL
    }
}

public protocol AppBundleLocating: Sendable {
    func locateInstalledApp() throws -> ManagedAppBundle
}

public struct AppBundleLocator: AppBundleLocating, Sendable {
    static let expectedBundleIdentifier = "com.woosublee.CLIProxyManager"

    private let executableURL: URL
    private let standardAppURL: URL

    public init(
        executableURL: URL = (Bundle.main.executableURL ?? URL(fileURLWithPath: "/usr/local/bin/cpm")),
        standardAppURL: URL = URL(fileURLWithPath: "/Applications/CLIProxyManager.app")
    ) {
        self.executableURL = executableURL
        self.standardAppURL = standardAppURL
    }

    public func locateInstalledApp() throws -> ManagedAppBundle {
        return try loadBundle(at: resolvedAppURL())
    }

    private func resolvedAppURL() -> URL {
        // If running from inside an app bundle's Helpers directory, derive the app URL from it.
        var url = executableURL
        url.deleteLastPathComponent()
        if url.lastPathComponent == "Helpers" {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "Contents" {
                url.deleteLastPathComponent()
                if url.pathExtension == "app" {
                    var path = url.path
                    if path.hasSuffix("/") { path.removeLast() }
                    return URL(fileURLWithPath: path, isDirectory: false)
                }
            }
        }
        return standardAppURL
    }

    private func loadBundle(at appURL: URL) throws -> ManagedAppBundle {
        guard let bundle = Bundle(url: appURL) else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is not installed.")
        }
        guard let identifier = bundle.bundleIdentifier, identifier == Self.expectedBundleIdentifier else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app has an unexpected bundle identifier.")
        }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is missing version information.")
        }
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is missing build information.")
        }

        let contents = appURL.appendingPathComponent("Contents")
        let proxyBinary = contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi")
        let proxyManifest = contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi.manifest.json")
        let cpmHelper = contents.appendingPathComponent("Helpers/cpm")
        let legacyHelper = contents.appendingPathComponent("Helpers/cliproxy-manager")
        let fm = FileManager.default

        guard fm.fileExists(atPath: proxyBinary.path) else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is missing the proxy binary.")
        }
        guard fm.fileExists(atPath: proxyManifest.path) else {
            throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is missing the proxy manifest.")
        }

        return ManagedAppBundle(
            appURL: appURL,
            proxyBinaryURL: proxyBinary,
            proxyManifestURL: proxyManifest,
            version: version,
            build: build,
            cpmHelperURL: fm.fileExists(atPath: cpmHelper.path) ? cpmHelper : nil,
            legacyHelperURL: fm.fileExists(atPath: legacyHelper.path) ? legacyHelper : nil
        )
    }
}
