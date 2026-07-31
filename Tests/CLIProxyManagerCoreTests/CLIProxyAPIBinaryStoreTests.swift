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
        let store = makeStore(paths: paths)

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
        let store = makeStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)
        try store.schedulePendingForNextStart()

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
    }

    func testPrepareKeepsValidUnscheduledPendingWithoutApplyingIt() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let activeBinary = paths.clipProxyBinary
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pendingBinary = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("#!/bin/sh\necho active\n", to: activeBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(activeBinary), size: fileSize(activeBinary), to: paths.activeClipProxyManifest)
        try writeExecutable("#!/bin/sh\necho bundled\n", to: bundledBinary)
        try writeManifest(version: "7.2.41", sourceKind: .bundled, binarySha: sha256(bundledBinary), size: fileSize(bundledBinary), to: bundledManifest)
        try writeExecutable("#!/bin/sh\necho pending\n", to: pendingBinary)
        let pendingManifest = try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = makeStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
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
        let store = makeStore(paths: paths)

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
        let store = makeStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.sourceKind, .bundled)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
    }

    func testReconcileBundledInstallsNewerBundleWithoutApplyingNewerPending() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = paths.clipProxyBinary
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pending = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("active", to: active)
        try writeManifest(version: "7.2.72", sourceKind: .bundled, binarySha: sha256(active), size: fileSize(active), to: paths.activeClipProxyManifest)
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: sha256(bundled), size: fileSize(bundled), to: bundledManifest)
        try writeExecutable("pending", to: pending)
        let store = makeStore(paths: paths)
        try store.savePending(
            binaryURL: pending,
            manifest: try manifest(version: "7.2.92", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending))
        )

        let result = try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)

        XCTAssertEqual(
            result,
            .installed(previousVersion: CLIProxyAPIVersion("7.2.72"), newVersion: CLIProxyAPIVersion("7.2.91")!)
        )
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.91")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.92")
    }

    func testReconcileBundledKeepsNewerActive() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = paths.clipProxyBinary
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("active", to: active)
        try writeManifest(version: "7.2.92", sourceKind: .userUpdated, binarySha: sha256(active), size: fileSize(active), to: paths.activeClipProxyManifest)
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: sha256(bundled), size: fileSize(bundled), to: bundledManifest)
        let store = makeStore(paths: paths)

        XCTAssertEqual(
            try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest),
            .unchanged(version: CLIProxyAPIVersion("7.2.92")!)
        )
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.92")
    }

    func testReconcileBundledRecoversMissingActive() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: sha256(bundled), size: fileSize(bundled), to: bundledManifest)
        let store = makeStore(paths: paths)

        XCTAssertEqual(
            try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest),
            .recoveredInvalidActive(newVersion: CLIProxyAPIVersion("7.2.91")!)
        )
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.91")
    }

    func testReconcileBundledRejectsChecksumMismatchWithoutChangingActive() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = paths.clipProxyBinary
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("active", to: active)
        try writeManifest(version: "7.2.72", sourceKind: .bundled, binarySha: sha256(active), size: fileSize(active), to: paths.activeClipProxyManifest)
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: "invalid-sha", size: fileSize(bundled), to: bundledManifest)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(
            try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)
        ) { error in
            XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .binaryChecksumMismatch)
        }
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.72")
    }

    func testReconcileBundledRemovesPendingThatIsNotNewerThanFinalActive() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = paths.clipProxyBinary
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pending = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("active", to: active)
        try writeManifest(version: "7.2.72", sourceKind: .bundled, binarySha: sha256(active), size: fileSize(active), to: paths.activeClipProxyManifest)
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: sha256(bundled), size: fileSize(bundled), to: bundledManifest)
        try writeExecutable("pending", to: pending)
        let store = makeStore(paths: paths)
        try store.savePending(
            binaryURL: pending,
            manifest: try manifest(version: "7.2.80", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending))
        )
        try store.schedulePendingForNextStart()

        _ = try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
    }

    func testReconcileBundledPreservesScheduledPendingWhenItIsNewer() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = paths.clipProxyBinary
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let pending = sandbox.appendingPathComponent("download/cliproxyapi")
        try writeExecutable("active", to: active)
        try writeManifest(version: "7.2.72", sourceKind: .bundled, binarySha: sha256(active), size: fileSize(active), to: paths.activeClipProxyManifest)
        try writeExecutable("bundled", to: bundled)
        try writeManifest(version: "7.2.91", sourceKind: .bundled, binarySha: sha256(bundled), size: fileSize(bundled), to: bundledManifest)
        try writeExecutable("pending", to: pending)
        let store = makeStore(paths: paths)
        try store.savePending(
            binaryURL: pending,
            manifest: try manifest(version: "7.2.92", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending))
        )
        try store.schedulePendingForNextStart()

        _ = try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try store.activeManifest()?.version, "7.2.91")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.92")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
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
        let store = makeStore(paths: paths)
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
        let store = makeStore(paths: paths)

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
        let store = makeStore(paths: paths)
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
        let store = makeStore(paths: paths)
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
        let store = makeStore(paths: paths)

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
        let store = makeStore(paths: paths)

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
        let store = makeStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        let mode = try FileManager.default.attributesOfItem(atPath: activeBinary.path)[.posixPermissions] as? Int
        XCTAssertEqual((try XCTUnwrap(mode)) & 0o777, 0o755)
    }

    func testSavePendingClearsApplyOnNextStartMarkerFromPreviousPending() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let first = sandbox.appendingPathComponent("download/first")
        let second = sandbox.appendingPathComponent("download/second")
        try writeExecutable("first", to: first)
        try writeExecutable("second", to: second)
        let store = makeStore(paths: paths)
        try store.savePending(
            binaryURL: first,
            manifest: try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(first), size: fileSize(first))
        )
        try store.schedulePendingForNextStart()

        try store.savePending(
            binaryURL: second,
            manifest: try manifest(version: "7.2.43", sourceKind: .userUpdated, binarySha: sha256(second), size: fileSize(second))
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.43")
    }

    func testSchedulePendingForNextStartRejectsMissingPendingBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.schedulePendingForNextStart()) { error in
            XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .missingPendingBinary)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
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
        let store = makeStore(paths: paths)
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
        let store = makeStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)
        try FileManager.default.createDirectory(at: paths.activeClipProxyManifest, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.applyPending())

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertEqual(try String(contentsOf: paths.pendingClipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.pendingManifest()?.version, "7.2.42")
    }


    func testSavePendingRejectsMismatchedTargetWithoutChangingPendingArtifacts() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let existingPending = sandbox.appendingPathComponent("download/existing")
        let candidate = sandbox.appendingPathComponent("download/candidate")
        try writeExecutable("existing pending", to: existingPending)
        try writeExecutable("mismatched candidate", to: candidate)
        let store = makeStore(paths: paths)
        try store.savePending(
            binaryURL: existingPending,
            manifest: try manifest(
                version: "7.2.41",
                sourceKind: .userUpdated,
                binarySha: sha256(existingPending),
                size: fileSize(existingPending),
                target: .darwinArm64
            )
        )
        try store.schedulePendingForNextStart()
        let pendingBefore = try Data(contentsOf: paths.pendingClipProxyBinary)
        let manifestBefore = try Data(contentsOf: paths.pendingClipProxyManifest)

        XCTAssertThrowsError(
            try store.savePending(
                binaryURL: candidate,
                manifest: try manifest(
                    version: "7.2.42",
                    sourceKind: .userUpdated,
                    binarySha: sha256(candidate),
                    size: fileSize(candidate),
                    target: .init(operatingSystem: .darwin, architecture: .x86_64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .unsupportedArtifactTarget)
        }

        XCTAssertEqual(try Data(contentsOf: paths.pendingClipProxyBinary), pendingBefore)
        XCTAssertEqual(try Data(contentsOf: paths.pendingClipProxyManifest), manifestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testSavePendingRejectsUnknownLegacyTargetWithoutCreatingArtifacts() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let candidate = sandbox.appendingPathComponent("download/candidate")
        try writeExecutable("unknown legacy candidate", to: candidate)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(
            try store.savePending(
                binaryURL: candidate,
                manifest: try manifest(
                    version: "7.2.42",
                    sourceKind: .userUpdated,
                    binarySha: sha256(candidate),
                    size: fileSize(candidate),
                    upstreamAsset: "CLIProxyAPI_7.2.42_darwin_x86_64.tar.gz"
                )
            )
        ) { error in
            XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .unsupportedArtifactTarget)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testSavePendingInfersExactLegacyProductionAssetAfterValidation() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let candidate = sandbox.appendingPathComponent("download/candidate")
        try writeExecutable("legacy candidate", to: candidate)
        let store = makeStore(paths: paths)

        try store.savePending(
            binaryURL: candidate,
            manifest: try manifest(
                version: "7.2.42",
                sourceKind: .userUpdated,
                binarySha: sha256(candidate),
                size: fileSize(candidate)
            )
        )

        XCTAssertEqual(try store.pendingManifest()?.target, .darwinArm64)
    }

    func testSavePendingAuthorizesExactLegacyProductionAssetAsLegacyArtifact() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let candidate = sandbox.appendingPathComponent("download/candidate")
        let authorizer = ArtifactRecordingAuthorizer()
        try writeExecutable("legacy candidate", to: candidate)
        let store = CLIProxyAPIBinaryStore(paths: paths, compatibilityAuthorizer: authorizer)

        try store.savePending(
            binaryURL: candidate,
            manifest: try manifest(
                version: "7.2.42",
                sourceKind: .userUpdated,
                binarySha: sha256(candidate),
                size: fileSize(candidate)
            )
        )

        XCTAssertEqual(
            authorizer.staticArtifacts,
            [.init(bundled: nil, active: nil, pending: .legacy)]
        )
        XCTAssertEqual(try store.pendingManifest()?.target, .darwinArm64)
    }

    func testSchedulePendingRejectsMismatchedTargetWithoutCreatingMarker() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeExecutable("mismatched pending", to: paths.pendingClipProxyBinary)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .userUpdated,
            binarySha: sha256(paths.pendingClipProxyBinary),
            size: fileSize(paths.pendingClipProxyBinary),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: paths.pendingClipProxyManifest
        )
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.schedulePendingForNextStart())

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testApplyPendingRejectsMismatchedTargetWithoutChangingActiveBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeExecutable("active", to: paths.clipProxyBinary)
        try writeManifest(
            version: "7.2.41",
            sourceKind: .userUpdated,
            binarySha: sha256(paths.clipProxyBinary),
            size: fileSize(paths.clipProxyBinary),
            target: .darwinArm64,
            to: paths.activeClipProxyManifest
        )
        try writeExecutable("mismatched pending", to: paths.pendingClipProxyBinary)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .userUpdated,
            binarySha: sha256(paths.pendingClipProxyBinary),
            size: fileSize(paths.pendingClipProxyBinary),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: paths.pendingClipProxyManifest
        )
        let activeBefore = try Data(contentsOf: paths.clipProxyBinary)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.applyPending())

        XCTAssertEqual(try Data(contentsOf: paths.clipProxyBinary), activeBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testPrepareActiveBinaryRejectsMismatchedBundledTargetWithoutInstallingIt() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("mismatched bundled", to: bundled)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .bundled,
            binarySha: sha256(bundled),
            size: fileSize(bundled),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: bundledManifest
        )
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.prepareActiveBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest))

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeClipProxyManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testReconcileBundledRejectsMismatchedTargetWithoutChangingActiveBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("active", to: paths.clipProxyBinary)
        try writeManifest(
            version: "7.2.41",
            sourceKind: .bundled,
            binarySha: sha256(paths.clipProxyBinary),
            size: fileSize(paths.clipProxyBinary),
            target: .darwinArm64,
            to: paths.activeClipProxyManifest
        )
        try writeExecutable("mismatched bundled", to: bundled)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .bundled,
            binarySha: sha256(bundled),
            size: fileSize(bundled),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: bundledManifest
        )
        let activeBefore = try Data(contentsOf: paths.clipProxyBinary)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest))

        XCTAssertEqual(try Data(contentsOf: paths.clipProxyBinary), activeBefore)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testReconcileBundledRejectsMismatchedPendingWithoutInstallingBundledBinary() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("active", to: paths.clipProxyBinary)
        try writeManifest(
            version: "7.2.41",
            sourceKind: .bundled,
            binarySha: sha256(paths.clipProxyBinary),
            size: fileSize(paths.clipProxyBinary),
            target: .darwinArm64,
            to: paths.activeClipProxyManifest
        )
        try writeExecutable("bundled", to: bundled)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .bundled,
            binarySha: sha256(bundled),
            size: fileSize(bundled),
            target: .darwinArm64,
            to: bundledManifest
        )
        try writeExecutable("mismatched pending", to: paths.pendingClipProxyBinary)
        try writeManifest(
            version: "7.2.43",
            sourceKind: .userUpdated,
            binarySha: sha256(paths.pendingClipProxyBinary),
            size: fileSize(paths.pendingClipProxyBinary),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: paths.pendingClipProxyManifest
        )
        let activeBefore = try Data(contentsOf: paths.clipProxyBinary)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest))

        XCTAssertEqual(try Data(contentsOf: paths.clipProxyBinary), activeBefore)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testPrepareActiveBinaryRejectsMismatchedScheduledPendingWithoutPromotingOrInstalling() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundled = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeExecutable("bundled", to: bundled)
        try writeManifest(
            version: "7.2.41",
            sourceKind: .bundled,
            binarySha: sha256(bundled),
            size: fileSize(bundled),
            target: .darwinArm64,
            to: bundledManifest
        )
        try writeExecutable("mismatched pending", to: paths.pendingClipProxyBinary)
        try writeManifest(
            version: "7.2.42",
            sourceKind: .userUpdated,
            binarySha: sha256(paths.pendingClipProxyBinary),
            size: fileSize(paths.pendingClipProxyBinary),
            target: .init(operatingSystem: .darwin, architecture: .x86_64),
            to: paths.pendingClipProxyManifest
        )
        try Data("scheduled\n".utf8).write(to: paths.pendingClipProxyApplyOnNextStartMarker)
        let store = makeStore(paths: paths)

        XCTAssertThrowsError(try store.prepareActiveBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest))

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeBackupURL(paths).path))
    }

    func testBinaryStoreSerializesMutableOperationsWithSharedLock() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private static let operationLock = NSLock()"))
        XCTAssertTrue(source.contains("try Self.operationLock.withLock"))
        XCTAssertTrue(source.contains("private func applyPendingLocked() throws"))
        XCTAssertTrue(source.contains("private func prepareActiveBinaryLocked(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws"))
        XCTAssertTrue(source.contains("func sha256HexDigest() throws -> String"))
    }

    private func makeStore(paths: ManagedPaths) -> CLIProxyAPIBinaryStore {
        CLIProxyAPIBinaryStore(
            paths: paths,
            compatibilityAuthorizer: RuntimeCompatibilityPreflight(environment: SupportedMacOSEnvironment())
        )
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

    private func writeManifest(
        version: String,
        sourceKind: CLIProxyAPIBinarySourceKind,
        binarySha: String,
        size: Int,
        target: CLIProxyAPIArtifactTarget? = nil,
        upstreamAsset: String? = nil,
        to url: URL
    ) throws {
        let data = try JSONEncoder().encode(
            manifest(
                version: version,
                sourceKind: sourceKind,
                binarySha: binarySha,
                size: size,
                target: target,
                upstreamAsset: upstreamAsset
            )
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func manifest(
        version: String,
        sourceKind: CLIProxyAPIBinarySourceKind,
        binarySha: String,
        size: Int,
        target: CLIProxyAPIArtifactTarget? = nil,
        upstreamAsset: String? = nil
    ) -> CLIProxyAPIBinaryManifest {
        let asset = upstreamAsset ?? "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz"
        return CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: version,
            commit: "commit-\(version)",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: sourceKind,
            source: "https://example.com/\(asset)",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v\(version)",
            upstreamAsset: asset,
            upstreamAssetSha256: "archive-sha-\(version)",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: binarySha,
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api",
            target: target
        )
    }

    private func activeBackupURL(_ paths: ManagedPaths) -> URL {
        paths.clipProxyDirectory.appendingPathComponent("cliproxyapi.backup")
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return data.sha256HexDigest()
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }
}

private final class ArtifactRecordingAuthorizer: RuntimeCompatibilityAuthorizing, @unchecked Sendable {
    private(set) var staticArtifacts: [CompatibilityArtifacts] = []

    func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        staticArtifacts.append(artifacts)
        return Self.allowedReport
    }

    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        staticReport(artifacts: artifacts)
    }

    func require(_ action: CompatibilityAction, artifacts: CompatibilityArtifacts) throws {}

    private static let allowedReport = RuntimeCompatibilityReport(
        findings: [],
        decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map {
            ($0, CompatibilityDecision(action: $0, disposition: .allowed))
        })
    )
}

private struct SupportedMacOSEnvironment: RuntimeEnvironmentProviding {
    func snapshot() -> RuntimeEnvironmentSnapshot {
        RuntimeEnvironmentSnapshot(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .arm64,
            loginShell: "/bin/zsh"
        )
    }
}
