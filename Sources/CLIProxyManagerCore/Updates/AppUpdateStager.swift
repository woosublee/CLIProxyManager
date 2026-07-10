import CryptoKit
import Foundation

public protocol MountedDMGInspecting: Sendable {
    func inspect(release: AppUpdateRelease, artifact: Data) async throws -> MountedAppBundle
}

public struct MountedAppBundle: Sendable {
    public let appURL: URL
    public let cpmHelperURL: URL
    public let legacyHelperURL: URL
    public let version: String
    public let build: Int

    public init(appURL: URL, cpmHelperURL: URL, legacyHelperURL: URL, version: String, build: Int) {
        self.appURL = appURL
        self.cpmHelperURL = cpmHelperURL
        self.legacyHelperURL = legacyHelperURL
        self.version = version
        self.build = build
    }
}

public struct HdiutilMountedDMGInspector: MountedDMGInspecting, Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func inspect(release: AppUpdateRelease, artifact: Data) async throws -> MountedAppBundle {
        let fm = FileManager.default
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerDMGInspect-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        let dmgPath = tmpDir.appendingPathComponent("update.dmg")
        try artifact.write(to: dmgPath)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dmgPath.path)

        let mountPoint = tmpDir.appendingPathComponent("mount")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachResult = await runner.run(
            "/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, dmgPath.path]
        )
        guard attachResult.exitCode == 0 else {
            throw CLIProxyManagerCommandError.operation("Failed to mount app update DMG: \(attachResult.stderr)")
        }
        defer {
            Task { await runner.run("/usr/bin/hdiutil", ["detach", mountPoint.path]) }
        }

        let appURL = mountPoint.appendingPathComponent("CLIProxyManager.app")
        guard let bundle = Bundle(url: appURL),
              let identifier = bundle.bundleIdentifier,
              identifier == "com.woosublee.CLIProxyManager" else {
            throw CLIProxyManagerCommandError.operation("Mounted DMG has unexpected bundle identifier.")
        }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version == release.version else {
            throw CLIProxyManagerCommandError.operation("Mounted DMG version does not match release.")
        }
        guard let buildStr = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(buildStr), build == release.build else {
            throw CLIProxyManagerCommandError.operation("Mounted DMG build does not match release.")
        }

        let contents = appURL.appendingPathComponent("Contents")
        let cpmHelper = contents.appendingPathComponent("Helpers/cpm")
        let legacyHelper = contents.appendingPathComponent("Helpers/cliproxy-manager")
        guard fm.isExecutableFile(atPath: cpmHelper.path) else {
            throw CLIProxyManagerCommandError.operation("Mounted DMG is missing Helpers/cpm.")
        }
        guard fm.isExecutableFile(atPath: legacyHelper.path) else {
            throw CLIProxyManagerCommandError.operation("Mounted DMG is missing Helpers/cliproxy-manager.")
        }

        let codesignResult = await runner.run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", appURL.path]
        )
        guard codesignResult.exitCode == 0 else {
            throw CLIProxyManagerCommandError.operation("App update code signature is invalid: \(codesignResult.stderr)")
        }

        return MountedAppBundle(
            appURL: appURL,
            cpmHelperURL: cpmHelper,
            legacyHelperURL: legacyHelper,
            version: version,
            build: build
        )
    }
}

public struct AppUpdateStager: AppUpdateStaging, Sendable {
    private let paths: ManagedPaths
    private let mountedInspector: any MountedDMGInspecting
    private let now: @Sendable () -> String

    public init(
        paths: ManagedPaths = ManagedPaths(),
        mountedInspector: any MountedDMGInspecting = HdiutilMountedDMGInspector(),
        now: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.paths = paths
        self.mountedInspector = mountedInspector
        self.now = now
    }

    public func stage(release: AppUpdateRelease, artifact: Data) async throws -> StagedAppUpdate {
        let mounted = try await mountedInspector.inspect(release: release, artifact: artifact)
        let stageDir = paths.appUpdateDirectory(build: release.build)
        let tmpDir = paths.appUpdatesDirectory.appendingPathComponent(".\(release.build).tmp")
        let fm = FileManager.default

        try fm.createDirectory(at: paths.appUpdatesDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: tmpDir)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        do {
            let stagedApp = tmpDir.appendingPathComponent("CLIProxyManager.app")
            let dittoResult = Process()
            dittoResult.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            dittoResult.arguments = ["--norsrc", "--noextattr", mounted.appURL.path, stagedApp.path]
            try dittoResult.run()
            dittoResult.waitUntilExit()
            guard dittoResult.terminationStatus == 0 else {
                throw CLIProxyManagerCommandError.operation("Failed to copy staged app bundle.")
            }

            let stagedCPM = tmpDir.appendingPathComponent("cpm")
            let stagedLegacy = tmpDir.appendingPathComponent("cliproxy-manager")
            let stagedContentsHelpers = stagedApp.appendingPathComponent("Contents/Helpers")
            try fm.copyItem(at: stagedContentsHelpers.appendingPathComponent("cpm"), to: stagedCPM)
            try fm.copyItem(at: stagedContentsHelpers.appendingPathComponent("cliproxy-manager"), to: stagedLegacy)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedCPM.path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedLegacy.path)

            let sha256 = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
            let staged = StagedAppUpdate(
                version: release.version,
                build: release.build,
                sourceURL: release.enclosureURL.absoluteString,
                artifactSHA256: sha256,
                expectedLength: release.expectedLength,
                stagedAt: now()
            )
            let manifestData = try JSONEncoder().encode(staged)
            try manifestData.write(to: tmpDir.appendingPathComponent("manifest.json"))

            try? fm.removeItem(at: stageDir)
            try fm.moveItem(at: tmpDir, to: stageDir)
            return staged
        } catch {
            try? fm.removeItem(at: tmpDir)
            throw error
        }
    }

    public func stagedUpdate() throws -> StagedAppUpdate? {
        let fm = FileManager.default
        var foundUpdate: StagedAppUpdate?
        if let builds = try? fm.contentsOfDirectory(atPath: paths.appUpdatesDirectory.path) {
            for buildStr in builds where !buildStr.hasPrefix(".") {
                if let build = Int(buildStr) {
                    let manifestURL = paths.appUpdateManifest(build: build)
                    if let data = try? Data(contentsOf: manifestURL),
                       let update = try? JSONDecoder().decode(StagedAppUpdate.self, from: data) {
                        if foundUpdate == nil || update.build > foundUpdate!.build {
                            foundUpdate = update
                        }
                    }
                }
            }
        }
        return foundUpdate
    }
}
