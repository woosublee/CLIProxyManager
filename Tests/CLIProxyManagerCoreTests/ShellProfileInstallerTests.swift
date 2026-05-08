import XCTest
@testable import CLIProxyManagerCore

final class ShellProfileInstallerTests: XCTestCase {
    func testInstallWritesFunctionsAndAddsSingleSourceLine() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        try "# existing\n".write(to: zshrcFile, atomically: true, encoding: .utf8)
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)
        let script = "cc() {\n  claude \"$@\"\n}\n"

        try installer.install(functionScript: script)

        let functions = try String(contentsOf: paths.functionsFile, encoding: .utf8)
        let profile = try String(contentsOf: zshrcFile, encoding: .utf8)
        let sourceLine = "source \(paths.functionsFile.path)"
        XCTAssertTrue(functions.contains("cc() {"))
        XCTAssertEqual(profile.components(separatedBy: sourceLine).count - 1, 1)
        XCTAssertTrue(profile.contains("# existing\n"))
    }

    func testInstallIsIdempotent() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)
        let script = "cc() {\n  claude \"$@\"\n}\n"

        try installer.install(functionScript: script)
        try installer.install(functionScript: script)

        let profile = try String(contentsOf: zshrcFile, encoding: .utf8)
        XCTAssertEqual(profile.components(separatedBy: "source \(paths.functionsFile.path)").count - 1, 1)
        XCTAssertEqual(profile.components(separatedBy: "# CLIProxyAPI Manager").count - 1, 1)
    }

    func testInstallCreatesBackupBeforeChangingZshrc() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        try "original\n".write(to: zshrcFile, atomically: true, encoding: .utf8)
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)

        try installer.install(functionScript: "cc() {}\n")

        let backups = try backupFiles(in: sandbox)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "original\n")
    }

    func testInstallDoesNotCreateBackupWhenAlreadyInstalledAndUnchanged() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)
        let script = "cc() {\n  claude \"$@\"\n}\n"

        try installer.install(functionScript: script)
        for backup in try backupFiles(in: sandbox) {
            try FileManager.default.removeItem(at: backup)
        }

        try installer.install(functionScript: script)

        XCTAssertEqual(try backupFiles(in: sandbox).count, 0)
    }

    func testUninstallRemovesSourceLineButKeepsFunctionsFile() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        try "# unrelated\n".write(to: zshrcFile, atomically: true, encoding: .utf8)
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)

        try installer.install(functionScript: "cc() {}\n")
        try installer.uninstall()

        let profile = try String(contentsOf: zshrcFile, encoding: .utf8)
        XCTAssertFalse(profile.contains("source \(paths.functionsFile.path)"))
        XCTAssertFalse(profile.contains("# CLIProxyAPI Manager"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.functionsFile.path))
        XCTAssertTrue(profile.contains("# unrelated\n"))
    }

    func testIsInstalledReflectsSourceLine() throws {
        let sandbox = try makeSandbox()
        let zshrcFile = sandbox.appendingPathComponent(".zshrc")
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrcFile)

        XCTAssertFalse(installer.isInstalled())
        try installer.install(functionScript: "cc() {}\n")
        XCTAssertTrue(installer.isInstalled())
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func backupFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".zshrc.cliproxy-manager.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
