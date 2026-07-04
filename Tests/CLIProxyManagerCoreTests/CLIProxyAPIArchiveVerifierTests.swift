import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIArchiveVerifierTests: XCTestCase {
    func testRejectsArchiveChecksumMismatch() async {
        let verifier = CLIProxyAPIArchiveVerifier(runner: StubVerifierRunner(results: []))
        let release = release(assetSha256: "expected-sha")

        await XCTAssertThrowsErrorAsync(try await verifier.verify(archiveData: Data("bad".utf8), release: release)) { error in
            XCTAssertEqual(error as? CLIProxyAPIArchiveVerifierError, .archiveChecksumMismatch)
        }
    }

    func testParsesVersionOutputAndBuildsManifest() async throws {
        let archiveData = Data("archive".utf8)
        let release = release(assetSha256: archiveData.sha256HexDigest())
        let runner = StubVerifierRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "CLIProxyAPI Version: 7.2.42, Commit: abcdef12, BuiltAt: 2026-07-01T00:00:00Z\n", stderr: "")
        ])
        let verifier = CLIProxyAPIArchiveVerifier(
            runner: runner,
            extractedBinaryLocator: { tempDirectory in
                let binary = tempDirectory.appendingPathComponent("cli-proxy-api")
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: binary)
                return binary
            }
        )

        let result = try await verifier.verify(archiveData: archiveData, release: release)

        XCTAssertEqual(result.manifest.version, "7.2.42")
        XCTAssertEqual(result.manifest.commit, "abcdef12")
        XCTAssertEqual(result.manifest.builtAt, "2026-07-01T00:00:00Z")
        XCTAssertEqual(result.manifest.sourceKind, .userUpdated)
        XCTAssertEqual(result.manifest.upstreamAssetSha256, archiveData.sha256HexDigest())
        XCTAssertEqual(result.manifest.vendoredBinaryName, "cliproxyapi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.binaryURL.path))
        XCTAssertNotNil(result.temporaryDirectory)
    }

    func testCleanupRemovesVerificationTemporaryDirectory() async throws {
        let archiveData = Data("archive".utf8)
        let release = release(assetSha256: archiveData.sha256HexDigest())
        let runner = StubVerifierRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "CLIProxyAPI Version: 7.2.42, Commit: abcdef12, BuiltAt: 2026-07-01T00:00:00Z\n", stderr: "")
        ])
        let verifier = CLIProxyAPIArchiveVerifier(
            runner: runner,
            extractedBinaryLocator: { tempDirectory in
                let binary = tempDirectory.appendingPathComponent("cli-proxy-api")
                try Data("#!/bin/sh\n".utf8).write(to: binary)
                return binary
            }
        )
        let result = try await verifier.verify(archiveData: archiveData, release: release)
        let temporaryDirectory = try XCTUnwrap(result.temporaryDirectory)

        verifier.cleanup(result)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testVerifyCleansTemporaryDirectoryAfterChecksumPassesButExtractedBinaryIsMissing() async {
        let archiveData = Data("archive".utf8)
        let release = release(assetSha256: archiveData.sha256HexDigest())
        let runner = StubVerifierRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: "")
        ])
        let capturedTempDirectory = CapturedURLBox()
        let verifier = CLIProxyAPIArchiveVerifier(
            runner: runner,
            extractedBinaryLocator: { tempDirectory in
                capturedTempDirectory.url = tempDirectory
                return tempDirectory.appendingPathComponent("cli-proxy-api")
            }
        )

        await XCTAssertThrowsErrorAsync(try await verifier.verify(archiveData: archiveData, release: release)) { error in
            XCTAssertEqual(error as? CLIProxyAPIArchiveVerifierError, .missingExtractedBinary)
        }

        XCTAssertNotNil(capturedTempDirectory.url)
        if let tempDirectory = capturedTempDirectory.url {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
        }
    }

    func testAcceptsVersionMetadataWhenVersionCommandExitsNonZero() async throws {
        let archiveData = Data("archive".utf8)
        let release = release(assetSha256: archiveData.sha256HexDigest())
        let runner = StubVerifierRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 2, stdout: "CLIProxyAPI Version: 7.2.42, Commit: abcdef12, BuiltAt: 2026-07-01T00:00:00Z\n", stderr: "flag provided but not defined: -version\n")
        ])
        let verifier = CLIProxyAPIArchiveVerifier(
            runner: runner,
            extractedBinaryLocator: { tempDirectory in
                let binary = tempDirectory.appendingPathComponent("cli-proxy-api")
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: binary)
                return binary
            }
        )

        let result = try await verifier.verify(archiveData: archiveData, release: release)

        XCTAssertEqual(result.manifest.version, "7.2.42")
        XCTAssertEqual(result.manifest.commit, "abcdef12")
        XCTAssertEqual(result.manifest.builtAt, "2026-07-01T00:00:00Z")
    }

    func testRejectsVersionOutputThatDoesNotMatchReleaseTag() async {
        let archiveData = Data("archive".utf8)
        let release = release(assetSha256: archiveData.sha256HexDigest())
        let runner = StubVerifierRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "CLIProxyAPI Version: 7.2.41, Commit: abcdef12, BuiltAt: 2026-07-01T00:00:00Z\n", stderr: "")
        ])
        let verifier = CLIProxyAPIArchiveVerifier(
            runner: runner,
            extractedBinaryLocator: { tempDirectory in
                let binary = tempDirectory.appendingPathComponent("cli-proxy-api")
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: binary)
                return binary
            }
        )

        await XCTAssertThrowsErrorAsync(try await verifier.verify(archiveData: archiveData, release: release)) { error in
            XCTAssertEqual(error as? CLIProxyAPIArchiveVerifierError, .versionMismatch(expected: "7.2.42", actual: "7.2.41"))
        }
    }

    private func release(assetSha256: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")!,
            assetSha256: assetSha256
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ assertion: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        assertion(error)
    }
}

private final class CapturedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedURL: URL?

    var url: URL? {
        get { lock.withLock { capturedURL } }
        set { lock.withLock { capturedURL = newValue } }
    }
}

private final class StubVerifierRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private var _invocations: [(String, [String])] = []

    var invocations: [(String, [String])] { lock.withLock { _invocations } }

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock {
            _invocations.append((executable, arguments))
            return results.removeFirst()
        }
    }
}
