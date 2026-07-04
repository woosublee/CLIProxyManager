import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIBinaryStoreTests: XCTestCase {
    func testPrepareInstallsBundledBinaryAndWritesBundledActiveManifestWhenMissing() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        let active = try XCTUnwrap(store.activeManifest())
        XCTAssertEqual(active.version, "7.2.41")
        XCTAssertEqual(active.sourceKind, .bundled)
    }

    func testPreparePromotesValidPendingBeforeUsingBundledBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
    }

    func testPrepareKeepsUserUpdatedActiveWhenBundledIsOlder() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho active\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
    }

    func testPrepareReplacesUserUpdatedActiveWhenBundledIsNewer() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.41", sourceKind: .userUpdated, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.42", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.sourceKind, .bundled)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
    }

    func testInvalidPendingChecksumIsNotApplied() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let badManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: "bad-sha", size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: badManifest, validate: false)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
    }

    func testPartialPendingManifestDoesNotBlockBundledInstall() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeManifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: "missing", size: 7, to: paths.pendingClipProxyManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
    }

    func testPrepareDoesNotLetOlderPendingDowngradeNewerBundledBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.43", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.43")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
    }

    func testPrepareDoesNotLetOlderPendingDowngradeNewerUserUpdatedActiveBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.50", sourceKind: .userUpdated, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho active\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.50")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
    }

    func testPrepareReplacesCorruptUserUpdatedActiveWithBundledBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho original active\n", to: activeBinary)
        try writeManifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try Data("tampered".utf8).write(to: activeBinary)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.sourceKind, .bundled)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
    }

    func testPrepareReplacesCorruptActiveManifestWithBundledBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try FileManager.default.createDirectory(at: paths.activeClipProxyManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not valid json".utf8).write(to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.sourceKind, .bundled)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
    }

    func testPrepareRestoresExecutablePermissionForValidBundledActiveBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.42", sourceKind: .bundled, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: activeBinary.path)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        let mode = try FileManager.default.attributesOfItem(atPath: activeBinary.path)[.posixPermissions] as? Int
        XCTAssertEqual((try XCTUnwrap(mode)) & 0o777, 0o755)
    }

    func testApplyPendingRestoresActiveAndPendingBinaryWhenManifestWriteFails() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.41", sourceKind: .userUpdated, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)
        try FileManager.default.removeItem(at: paths.activeClipProxyManifest)
        try FileManager.default.createDirectory(at: paths.activeClipProxyManifest, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.applyPending())

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho active\n")
        XCTAssertEqual(try String(contentsOf: paths.pendingClipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.42")
    }

    func testApplyPendingRestoresPendingBinaryWhenManifestWriteFailsWithoutBackup() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)
        try FileManager.default.createDirectory(at: paths.activeClipProxyManifest, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.applyPending())

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertEqual(try String(contentsOf: paths.pendingClipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.42")
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerBinaryStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeManifest(version: String, sourceKind: CLIProxyAPIBinarySourceKind, binarySha: String, size: Int, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest(version: version, sourceKind: sourceKind, binarySha: binarySha, size: size))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func manifest(version: String, sourceKind: CLIProxyAPIBinarySourceKind, binarySha: String, size: Int) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: version,
            commit: "commit-\(version)",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: sourceKind,
            source: "https://example.com/CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v\(version)",
            upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive-sha-\(version)",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: binarySha,
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api"
        )
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return data.sha256HexDigest()
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }
}
