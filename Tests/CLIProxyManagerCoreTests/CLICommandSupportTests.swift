import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLICommandSupportTests: XCTestCase {
    func testUsageFailureUsesUsageExitCode() {
        XCTAssertEqual(CLIProxyManagerCommandError.usage.exitCode, .usage)
    }

    func testPrerequisiteFailureUsesPrerequisiteExitCode() {
        XCTAssertEqual(
            CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is not installed.").exitCode,
            .prerequisite
        )
    }

    func testOperationFailureUsesFailureExitCode() {
        XCTAssertEqual(CLIProxyManagerCommandError.operation("launchctl failed").exitCode, .failure)
    }

    func testTerminalOutputKeepsStdoutAndStderrSeparate() {
        let output = OutputDouble(isInteractive: false)
        output.writeStdout("ready\n")
        output.writeStderr("failed\n")
        XCTAssertEqual(output.stdout, ["ready\n"])
        XCTAssertEqual(output.stderr, ["failed\n"])
    }

    func testExecutableEntryPointsPreserveSecretStoreErrorDiagnostics() throws {
        let expectedCatch = """
        } catch let error as SecretStoreError {
            output.writeStderr("\\(error.description)\\n")
            exit(CLICommandExitCode.failure.rawValue)
        } catch {
        """

        for path in [
            "Sources/CLIProxyManagerCLI/main.swift",
            "Sources/CPMCLI/main.swift"
        ] {
            let source = try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains(expectedCatch), "\(path) must preserve SecretStoreError diagnostics and map them to failure.")
        }
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private final class OutputDouble: CLICommandOutputWriting, @unchecked Sendable {
    let isInteractive: Bool
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []

    init(isInteractive: Bool) { self.isInteractive = isInteractive }
    func writeStdout(_ text: String) { stdout.append(text) }
    func writeStderr(_ text: String) { stderr.append(text) }
    func confirm(_: String) -> Bool { false }
}
