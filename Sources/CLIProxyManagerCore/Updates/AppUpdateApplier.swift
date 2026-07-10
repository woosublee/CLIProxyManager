import Foundation

public struct AppInstallTargets: Equatable, Sendable {
    public let app: URL
    public let cpm: URL
    public let legacyHelper: URL

    public static let standard = AppInstallTargets(
        app: URL(fileURLWithPath: "/Applications/CLIProxyManager.app"),
        cpm: URL(fileURLWithPath: "/usr/local/bin/cpm"),
        legacyHelper: URL(fileURLWithPath: "/usr/local/bin/cliproxy-manager")
    )

    public init(app: URL, cpm: URL, legacyHelper: URL) {
        self.app = app
        self.cpm = cpm
        self.legacyHelper = legacyHelper
    }
}

public protocol PermissionChecking: Sendable {
    func canWrite(to url: URL) -> Bool
}

public struct FileSystemPermissionChecker: PermissionChecking, Sendable {
    public init() {}
    public func canWrite(to url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return fm.isWritableFile(atPath: url.path)
        }
        return fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}

public struct AppUpdateApplier: Sendable {
    private let targets: AppInstallTargets
    private let lifecycle: any AppLifecycleControlling
    private let currentUID: @Sendable () -> uid_t

    public init(
        targets: AppInstallTargets = .standard,
        lifecycle: any AppLifecycleControlling = AppLifecycleService(),
        currentUID: @escaping @Sendable () -> uid_t = { Darwin.geteuid() }
    ) {
        self.targets = targets
        self.lifecycle = lifecycle
        self.currentUID = currentUID
    }

    init(
        targets: AppInstallTargets,
        lifecycle: any AppLifecycleControlling,
        currentUID: @escaping @Sendable () -> uid_t,
        permissionChecker: any PermissionChecking = FileSystemPermissionChecker()
    ) {
        self.targets = targets
        self.lifecycle = lifecycle
        self.currentUID = currentUID
        self.permissionChecker = permissionChecker
    }

    private var permissionChecker: any PermissionChecking = FileSystemPermissionChecker()

    public func apply(staged: StagedAppUpdate, stageDir: URL) async throws -> AppUpdateApplyResult {
        guard currentUID() != 0 else {
            throw CLIProxyManagerCommandError.prerequisite(
                "cpm must run as the macOS user that owns ~/.cliproxy-manager; do not use sudo."
            )
        }

        try verifyPreflight(staged: staged, stageDir: stageDir)

        let wasRunning = (try? await lifecycle.status())?.running ?? false
        if wasRunning {
            _ = try await lifecycle.stop()
        }

        let stagedApp = stageDir.appendingPathComponent("CLIProxyManager.app")
        let stagedCPM = stageDir.appendingPathComponent("cpm")
        let stagedLegacy = stageDir.appendingPathComponent("cliproxy-manager")

        let appPrevious = targets.app.deletingLastPathComponent()
            .appendingPathComponent(".CLIProxyManager.app.cpm-previous")
        let cpmPrevious = targets.cpm.deletingLastPathComponent()
            .appendingPathComponent(".cpm.cpm-previous")
        let legacyPrevious = targets.legacyHelper.deletingLastPathComponent()
            .appendingPathComponent(".cliproxy-manager.cpm-previous")

        let appStaging = targets.app.deletingLastPathComponent()
            .appendingPathComponent(".CLIProxyManager.app.cpm-stage")
        let cpmStaging = targets.cpm.deletingLastPathComponent()
            .appendingPathComponent(".cpm.cpm-stage")
        let legacyStaging = targets.legacyHelper.deletingLastPathComponent()
            .appendingPathComponent(".cliproxy-manager.cpm-stage")

        let fm = FileManager.default

        // Copy staged sources to local temporaries
        try? fm.removeItem(at: appStaging)
        try? fm.removeItem(at: cpmStaging)
        try? fm.removeItem(at: legacyStaging)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--norsrc", "--noextattr", stagedApp.path, appStaging.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CLIProxyManagerCommandError.operation("Failed to copy staged app to local temporary.")
        }
        try fm.copyItem(at: stagedCPM, to: cpmStaging)
        try fm.copyItem(at: stagedLegacy, to: legacyStaging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cpmStaging.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyStaging.path)

        // Rename existing targets to previous paths, then rename staged to canonical
        func restoreAndThrow(_ error: Error) throws -> Never {
            try? fm.removeItem(at: targets.app)
            if fm.fileExists(atPath: appPrevious.path) { try? fm.moveItem(at: appPrevious, to: targets.app) }
            try? fm.removeItem(at: targets.cpm)
            if fm.fileExists(atPath: cpmPrevious.path) { try? fm.moveItem(at: cpmPrevious, to: targets.cpm) }
            try? fm.removeItem(at: targets.legacyHelper)
            if fm.fileExists(atPath: legacyPrevious.path) { try? fm.moveItem(at: legacyPrevious, to: targets.legacyHelper) }
            try? fm.removeItem(at: appStaging)
            try? fm.removeItem(at: cpmStaging)
            try? fm.removeItem(at: legacyStaging)
            throw CLIProxyManagerCommandError.operation("Installation failed: \((error as? CLIProxyManagerCommandError)?.description ?? error.localizedDescription). Automatic restoration attempted.")
        }

        try? fm.removeItem(at: appPrevious)
        try? fm.removeItem(at: cpmPrevious)
        try? fm.removeItem(at: legacyPrevious)

        if fm.fileExists(atPath: targets.app.path) { try? fm.moveItem(at: targets.app, to: appPrevious) }
        if fm.fileExists(atPath: targets.cpm.path) { try? fm.moveItem(at: targets.cpm, to: cpmPrevious) }
        if fm.fileExists(atPath: targets.legacyHelper.path) { try? fm.moveItem(at: targets.legacyHelper, to: legacyPrevious) }

        do {
            try fm.moveItem(at: appStaging, to: targets.app)
            try fm.moveItem(at: cpmStaging, to: targets.cpm)
            try fm.moveItem(at: legacyStaging, to: targets.legacyHelper)
        } catch {
            try restoreAndThrow(error)
        }

        // Success: remove previous and staged directory
        try? fm.removeItem(at: appPrevious)
        try? fm.removeItem(at: cpmPrevious)
        try? fm.removeItem(at: legacyPrevious)
        try? fm.removeItem(at: stageDir)

        if wasRunning {
            do {
                _ = try await lifecycle.start()
                return AppUpdateApplyResult(version: staged.version, appRestarted: true, appRestartWarning: nil)
            } catch {
                return AppUpdateApplyResult(version: staged.version, appRestarted: false, appRestartWarning: "App was installed but could not restart: \(error.localizedDescription)")
            }
        }
        return AppUpdateApplyResult(version: staged.version, appRestarted: false, appRestartWarning: nil)
    }

    private func verifyPreflight(staged: StagedAppUpdate, stageDir: URL) throws {
        let fm = FileManager.default
        for url in [targets.app, targets.cpm, targets.legacyHelper] {
            guard permissionChecker.canWrite(to: url) else {
                throw CLIProxyManagerCommandError.prerequisite("Current user cannot update all app and helper installation paths.")
            }
        }
        let stagedApp = stageDir.appendingPathComponent("CLIProxyManager.app")
        let stagedCPM = stageDir.appendingPathComponent("cpm")
        let stagedLegacy = stageDir.appendingPathComponent("cliproxy-manager")
        guard fm.fileExists(atPath: stagedApp.path),
              fm.isExecutableFile(atPath: stagedCPM.path),
              fm.isExecutableFile(atPath: stagedLegacy.path) else {
            throw CLIProxyManagerCommandError.operation("Staged app update is incomplete or corrupted.")
        }
    }
}
