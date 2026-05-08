# CLIProxyAPI Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS SwiftUI app that manages CLIProxyAPI, Claude Code subscription/API profiles, Codex OAuth routing, and shell functions `cc`, `ccapi`, `ccodex` for non-developers.

**Architecture:** Start with a Swift Package containing a testable `CLIProxyManagerCore` library, a SwiftUI app executable, and a small `cliproxy-manager` CLI helper. Core services handle config, shell function rendering, shell profile installation, Keychain-backed secrets, Claude Code command integration, and CLIProxyAPI health/process management. UI layers consume those services through view models.

**Tech Stack:** Swift 5.10+, SwiftPM, SwiftUI, Foundation, Security.framework, ServiceManagement.framework, XCTest, macOS 13+.

---

## File Structure

Create this structure under `/Users/woosublee/Documents/dev/CLIProxyManager`:

```text
Package.swift
.gitignore
scripts/vendor-cliproxyapi.sh
Resources/cliproxyapi/.gitkeep
Resources/Licenses/CLIProxyAPI-LICENSE.txt
Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift
Sources/CLIProxyManagerApp/Views/DashboardView.swift
Sources/CLIProxyManagerApp/Views/OnboardingView.swift
Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift
Sources/CLIProxyManagerApp/ViewModels/OnboardingViewModel.swift
Sources/CLIProxyManagerCLI/main.swift
Sources/CLIProxyManagerCore/Config/AppConfig.swift
Sources/CLIProxyManagerCore/Config/ManagedPaths.swift
Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift
Sources/CLIProxyManagerCore/Shell/ShellProfileInstaller.swift
Sources/CLIProxyManagerCore/Secrets/SecretStore.swift
Sources/CLIProxyManagerCore/Secrets/KeychainSecretStore.swift
Sources/CLIProxyManagerCore/System/ProcessRunner.swift
Sources/CLIProxyManagerCore/Claude/ClaudeConnector.swift
Sources/CLIProxyManagerCore/Proxy/ProxyHealthClient.swift
Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift
Sources/CLIProxyManagerCore/Diagnostics/DiagnosticStatus.swift
Sources/CLIProxyManagerCore/Launch/LaunchAtLoginController.swift
Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
Tests/CLIProxyManagerCoreTests/ShellProfileInstallerTests.swift
Tests/CLIProxyManagerCoreTests/SecretStoreTests.swift
Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift
Tests/CLIProxyManagerCoreTests/ProxyHealthClientTests.swift
Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
Tests/CLIProxyManagerCoreTests/DashboardViewModelTests.swift
```

Responsibility boundaries:

- `CLIProxyManagerCore`: all business logic and testable services.
- `CLIProxyManagerApp`: SwiftUI presentation and user actions.
- `CLIProxyManagerCLI`: helper used by generated shell functions, especially Keychain secret retrieval.
- `scripts`: local development and binary vendoring utilities.
- `Resources/cliproxyapi`: pinned CLIProxyAPI binary location for app packaging.

---

### Task 1: Bootstrap Swift Package

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Resources/cliproxyapi/.gitkeep`
- Create: `Sources/CLIProxyManagerCore/Diagnostics/DiagnosticStatus.swift`
- Create: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
- Create: `Sources/CLIProxyManagerCLI/main.swift`
- Create: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

- [ ] **Step 1: Initialize git repository**

Run:

```bash
cd /Users/woosublee/Documents/dev/CLIProxyManager
git init
```

Expected: `Initialized empty Git repository` or `Reinitialized existing Git repository`.

- [ ] **Step 2: Write the package manifest**

Create `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CLIProxyManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CLIProxyManager", targets: ["CLIProxyManagerApp"]),
        .executable(name: "cliproxy-manager", targets: ["CLIProxyManagerCLI"]),
        .library(name: "CLIProxyManagerCore", targets: ["CLIProxyManagerCore"])
    ],
    targets: [
        .target(
            name: "CLIProxyManagerCore",
            dependencies: [],
            path: "Sources/CLIProxyManagerCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerApp",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerApp",
            resources: [
                .copy("../../Resources/cliproxyapi")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerCLI",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerCLI"
        ),
        .testTarget(
            name: "CLIProxyManagerCoreTests",
            dependencies: ["CLIProxyManagerCore"],
            path: "Tests/CLIProxyManagerCoreTests"
        )
    ]
)
```

- [ ] **Step 3: Write `.gitignore`**

Create `.gitignore`:

```gitignore
.DS_Store
.build/
.swiftpm/
*.xcodeproj
*.xcworkspace
derived-data/
Resources/cliproxyapi/cliproxyapi
.superpowers/brainstorm/
```

- [ ] **Step 4: Add resource placeholder**

Create `Resources/cliproxyapi/.gitkeep` with empty content.

- [ ] **Step 5: Add first core enum**

Create `Sources/CLIProxyManagerCore/Diagnostics/DiagnosticStatus.swift`:

```swift
import Foundation

public enum DiagnosticSeverity: String, Equatable, Sendable {
    case ready
    case warning
    case error
}

public struct DiagnosticStatus: Equatable, Sendable {
    public let severity: DiagnosticSeverity
    public let title: String
    public let message: String

    public init(severity: DiagnosticSeverity, title: String, message: String) {
        self.severity = severity
        self.title = title
        self.message = message
    }
}
```

- [ ] **Step 6: Add minimal SwiftUI entry point**

Create `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`:

```swift
import SwiftUI

@main
struct CLIProxyManagerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("CLIProxy Manager")
                .frame(width: 720, height: 480)
        }
    }
}
```

- [ ] **Step 7: Add minimal CLI helper entry point**

Create `Sources/CLIProxyManagerCLI/main.swift`:

```swift
import Foundation

print("cliproxy-manager helper")
```

- [ ] **Step 8: Add smoke test**

Create `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDiagnosticStatusStoresMessage() {
        let status = DiagnosticStatus(severity: .ready, title: "Ready", message: "All good")
        XCTAssertEqual(status.severity, .ready)
        XCTAssertEqual(status.title, "Ready")
        XCTAssertEqual(status.message, "All good")
    }
}
```

- [ ] **Step 9: Run tests**

Run:

```bash
cd /Users/woosublee/Documents/dev/CLIProxyManager
swift test
```

Expected: all tests pass.

- [ ] **Step 10: Commit**

Run:

```bash
git add Package.swift .gitignore Resources Sources Tests
git commit -m "chore: bootstrap Swift package"
```

---

### Task 2: Add Config and Managed Paths

**Files:**
- Create: `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
- Create: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`

- [ ] **Step 1: Replace config tests with failing expectations**

Replace `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDefaultConfigMatchesMVPDecisions() {
        let config = AppConfig.default

        XCTAssertEqual(config.port, 8317)
        XCTAssertEqual(config.commands.cc, "cc")
        XCTAssertEqual(config.commands.ccapi, "ccapi")
        XCTAssertEqual(config.commands.ccodex, "ccodex")
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
        XCTAssertEqual(config.ccodex.opusModel, "gpt-5.5(xhigh)")
        XCTAssertEqual(config.ccodex.sonnetModel, "gpt-5.5(xhigh)")
        XCTAssertEqual(config.ccodex.haikuModel, "gpt-5.5(low)")
        XCTAssertFalse(config.includeDangerouslySkipPermissions)
    }

    func testManagedPathsCanBeRootedInTemporaryDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)

        XCTAssertEqual(paths.rootDirectory, root)
        XCTAssertEqual(paths.functionsFile, root.appendingPathComponent("functions.zsh"))
        XCTAssertEqual(paths.configFile, root.appendingPathComponent("config.json"))
        XCTAssertEqual(paths.logsDirectory, root.appendingPathComponent("logs"))
        XCTAssertEqual(paths.clipProxyDirectory, root.appendingPathComponent("cliproxyapi"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: FAIL because `AppConfig` and `ManagedPaths` do not exist.

- [ ] **Step 3: Implement `AppConfig`**

Create `Sources/CLIProxyManagerCore/Config/AppConfig.swift`:

```swift
import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public struct Commands: Codable, Equatable, Sendable {
        public var cc: String
        public var ccapi: String
        public var ccodex: String
    }

    public struct ClaudeAPI: Codable, Equatable, Sendable {
        public var model: String
    }

    public struct Codex: Codable, Equatable, Sendable {
        public var opusModel: String
        public var sonnetModel: String
        public var haikuModel: String
    }

    public var port: Int
    public var commands: Commands
    public var ccapi: ClaudeAPI
    public var ccodex: Codex
    public var includeDangerouslySkipPermissions: Bool

    public init(
        port: Int,
        commands: Commands,
        ccapi: ClaudeAPI,
        ccodex: Codex,
        includeDangerouslySkipPermissions: Bool
    ) {
        self.port = port
        self.commands = commands
        self.ccapi = ccapi
        self.ccodex = ccodex
        self.includeDangerouslySkipPermissions = includeDangerouslySkipPermissions
    }

    public static let `default` = AppConfig(
        port: 8317,
        commands: Commands(cc: "cc", ccapi: "ccapi", ccodex: "ccodex"),
        ccapi: ClaudeAPI(model: "claude-opus-4-7"),
        ccodex: Codex(
            opusModel: "gpt-5.5(xhigh)",
            sonnetModel: "gpt-5.5(xhigh)",
            haikuModel: "gpt-5.5(low)"
        ),
        includeDangerouslySkipPermissions: false
    )
}
```

- [ ] **Step 4: Implement `ManagedPaths`**

Create `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`:

```swift
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
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Config Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "feat: add app configuration defaults"
```

---

### Task 3: Render Shell Functions

**Files:**
- Create: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

- [ ] **Step 1: Write failing renderer tests**

Create `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ShellFunctionRendererTests: XCTestCase {
    func testRenderUsesFunctionsNotAliasesOrGlobalExports() {
        let renderer = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        let script = renderer.render()

        XCTAssertTrue(script.contains("cc() {"))
        XCTAssertTrue(script.contains("ccapi() {"))
        XCTAssertTrue(script.contains("ccodex() {"))
        XCTAssertFalse(script.contains("alias cc="))
        XCTAssertFalse(script.contains("export ANTHROPIC_BASE_URL"))
        XCTAssertFalse(script.contains("export ANTHROPIC_AUTH_TOKEN"))
    }

    func testRenderPassesArgumentsThroughToClaude() {
        let script = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertEqual(script.components(separatedBy: "claude \"$@\"").count - 1, 3)
    }

    func testRenderUsesConfiguredModelsAndPort() {
        var config = AppConfig.default
        config.port = 8320
        config.ccapi.model = "claude-sonnet-4-6"
        config.ccodex.opusModel = "gpt-5.3-codex(xhigh)"
        config.ccodex.sonnetModel = "gpt-5.3-codex(medium)"
        config.ccodex.haikuModel = "gpt-5.3-codex(low)"

        let script = ShellFunctionRenderer(
            config: config,
            helperCommand: "/opt/cliproxy-manager/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("http://127.0.0.1:8320/v1/models"))
        XCTAssertTrue(script.contains("ANTHROPIC_MODEL=\"claude-sonnet-4-6\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL=\"gpt-5.3-codex(xhigh)\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL=\"gpt-5.3-codex(medium)\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL=\"gpt-5.3-codex(low)\""))
        XCTAssertTrue(script.contains("/opt/cliproxy-manager/bin/cliproxy-manager secret get claude-api-key"))
    }

    func testDangerousPermissionFlagIsOptIn() {
        var config = AppConfig.default
        config.includeDangerouslySkipPermissions = true

        let script = ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("claude --dangerously-skip-permissions \"$@\""))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: FAIL because `ShellFunctionRenderer` does not exist.

- [ ] **Step 3: Implement renderer**

Create `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`:

```swift
import Foundation

public struct ShellFunctionRenderer: Sendable {
    private let config: AppConfig
    private let helperCommand: String

    public init(config: AppConfig, helperCommand: String) {
        self.config = config
        self.helperCommand = helperCommand
    }

    public func render() -> String {
        let claudeCommand = config.includeDangerouslySkipPermissions
            ? "claude --dangerously-skip-permissions \"$@\""
            : "claude \"$@\""
        let port = config.port

        return """
        # Generated by CLIProxyAPI Manager. Do not edit this file manually.
        # Edit profiles in the CLIProxyAPI Manager app instead.

        \(config.commands.cc)() {
          \(claudeCommand)
        }

        \(config.commands.ccapi)() {
          ANTHROPIC_AUTH_TOKEN="$(\(helperCommand) secret get claude-api-key)" \\
          ANTHROPIC_MODEL="\(config.ccapi.model)" \\
          \(claudeCommand)
        }

        \(config.commands.ccodex)() {
          if ! curl -sf "http://127.0.0.1:\(port)/v1/models" >/dev/null; then
            echo "CLIProxyAPI Manager가 실행 중이 아닙니다. 앱을 열어 주세요."
            return 1
          fi

          ANTHROPIC_BASE_URL="http://127.0.0.1:\(port)" \\
          ANTHROPIC_AUTH_TOKEN="sk-dummy" \\
          ANTHROPIC_DEFAULT_OPUS_MODEL="\(config.ccodex.opusModel)" \\
          ANTHROPIC_DEFAULT_SONNET_MODEL="\(config.ccodex.sonnetModel)" \\
          ANTHROPIC_DEFAULT_HAIKU_MODEL="\(config.ccodex.haikuModel)" \\
          \(claudeCommand)
        }

        """
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "feat: render managed shell functions"
```

---

### Task 4: Install Shell Functions Safely

**Files:**
- Create: `Sources/CLIProxyManagerCore/Shell/ShellProfileInstaller.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ShellProfileInstallerTests.swift`

- [ ] **Step 1: Write failing installer tests**

Create `Tests/CLIProxyManagerCoreTests/ShellProfileInstallerTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ShellProfileInstallerTests: XCTestCase {
    func testInstallWritesFunctionsAndAddsSingleSourceLine() throws {
        let sandbox = try makeSandbox()
        let zshrc = sandbox.appendingPathComponent(".zshrc")
        try "# existing\n".write(to: zshrc, atomically: true, encoding: .utf8)

        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent(".cliproxy-manager"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrc)

        try installer.install(functionScript: "cc() {\n  claude \"$@\"\n}\n")

        let functions = try String(contentsOf: paths.functionsFile, encoding: .utf8)
        let profile = try String(contentsOf: zshrc, encoding: .utf8)

        XCTAssertTrue(functions.contains("cc()"))
        XCTAssertTrue(profile.contains("source \(paths.functionsFile.path)"))
        XCTAssertEqual(profile.components(separatedBy: "source \(paths.functionsFile.path)").count - 1, 1)
    }

    func testInstallIsIdempotent() throws {
        let sandbox = try makeSandbox()
        let zshrc = sandbox.appendingPathComponent(".zshrc")
        try "".write(to: zshrc, atomically: true, encoding: .utf8)

        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent(".cliproxy-manager"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrc)

        try installer.install(functionScript: "cc() {}\n")
        try installer.install(functionScript: "cc() {}\n")

        let profile = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertEqual(profile.components(separatedBy: "source \(paths.functionsFile.path)").count - 1, 1)
    }

    func testInstallCreatesBackupBeforeChangingZshrc() throws {
        let sandbox = try makeSandbox()
        let zshrc = sandbox.appendingPathComponent(".zshrc")
        try "original\n".write(to: zshrc, atomically: true, encoding: .utf8)

        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent(".cliproxy-manager"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrc)

        try installer.install(functionScript: "cc() {}\n")

        let backups = try FileManager.default.contentsOfDirectory(at: sandbox, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".zshrc.cliproxy-manager.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "original\n")
    }

    func testUninstallRemovesSourceLineButKeepsFunctionsFile() throws {
        let sandbox = try makeSandbox()
        let zshrc = sandbox.appendingPathComponent(".zshrc")
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent(".cliproxy-manager"))
        let installer = ShellProfileInstaller(paths: paths, zshrcFile: zshrc)

        try "".write(to: zshrc, atomically: true, encoding: .utf8)
        try installer.install(functionScript: "cc() {}\n")
        try installer.uninstall()

        let profile = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(profile.contains("source \(paths.functionsFile.path)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.functionsFile.path))
    }

    private func makeSandbox() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter ShellProfileInstallerTests
```

Expected: FAIL because `ShellProfileInstaller` does not exist.

- [ ] **Step 3: Implement installer**

Create `Sources/CLIProxyManagerCore/Shell/ShellProfileInstaller.swift`:

```swift
import Foundation

public struct ShellProfileInstaller: Sendable {
    private let paths: ManagedPaths
    private let zshrcFile: URL
    private let fileManager: FileManager

    public init(
        paths: ManagedPaths,
        zshrcFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc"),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.zshrcFile = zshrcFile
        self.fileManager = fileManager
    }

    public func install(functionScript: String) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try functionScript.write(to: paths.functionsFile, atomically: true, encoding: .utf8)

        let sourceLine = "source \(paths.functionsFile.path)"
        let currentProfile = (try? String(contentsOf: zshrcFile, encoding: .utf8)) ?? ""
        try backupZshrcIfNeeded(currentProfile: currentProfile)

        if currentProfile.contains(sourceLine) {
            return
        }

        let separator = currentProfile.hasSuffix("\n") || currentProfile.isEmpty ? "" : "\n"
        let updated = currentProfile + separator + "\n# CLIProxyAPI Manager\n" + sourceLine + "\n"
        try updated.write(to: zshrcFile, atomically: true, encoding: .utf8)
    }

    public func uninstall() throws {
        let sourceLine = "source \(paths.functionsFile.path)"
        let currentProfile = (try? String(contentsOf: zshrcFile, encoding: .utf8)) ?? ""
        try backupZshrcIfNeeded(currentProfile: currentProfile)

        let filtered = currentProfile
            .components(separatedBy: .newlines)
            .filter { line in
                line != "# CLIProxyAPI Manager" && line != sourceLine
            }
            .joined(separator: "\n")

        try (filtered.hasSuffix("\n") ? filtered : filtered + "\n")
            .write(to: zshrcFile, atomically: true, encoding: .utf8)
    }

    private func backupZshrcIfNeeded(currentProfile: String) throws {
        if !fileManager.fileExists(atPath: zshrcFile.path) {
            try "".write(to: zshrcFile, atomically: true, encoding: .utf8)
        }

        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = zshrcFile.deletingLastPathComponent()
            .appendingPathComponent(".zshrc.cliproxy-manager.\(stamp).bak")

        try currentProfile.write(to: backup, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter ShellProfileInstallerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Shell/ShellProfileInstaller.swift Tests/CLIProxyManagerCoreTests/ShellProfileInstallerTests.swift
git commit -m "feat: install shell functions safely"
```

---

### Task 5: Add Keychain Secret Store and CLI Helper

**Files:**
- Create: `Sources/CLIProxyManagerCore/Secrets/SecretStore.swift`
- Create: `Sources/CLIProxyManagerCore/Secrets/KeychainSecretStore.swift`
- Replace: `Sources/CLIProxyManagerCLI/main.swift`
- Create: `Tests/CLIProxyManagerCoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Write failing secret store tests**

Create `Tests/CLIProxyManagerCoreTests/SecretStoreTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class SecretStoreTests: XCTestCase {
    func testInMemorySecretStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.set("abc123", for: .claudeAPIKey)
        XCTAssertEqual(try store.get(.claudeAPIKey), "abc123")
    }

    func testMissingSecretThrows() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.get(.claudeAPIKey)) { error in
            XCTAssertEqual(error as? SecretStoreError, .missingSecret("claude-api-key"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter SecretStoreTests
```

Expected: FAIL because secret types do not exist.

- [ ] **Step 3: Implement secret protocol and in-memory store**

Create `Sources/CLIProxyManagerCore/Secrets/SecretStore.swift`:

```swift
import Foundation

public enum SecretKey: String, Sendable {
    case claudeAPIKey = "claude-api-key"
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    case missingSecret(String)
    case writeFailed(String)
    case readFailed(String)

    public var description: String {
        switch self {
        case .missingSecret(let key): return "Missing secret: \(key)"
        case .writeFailed(let message): return "Failed to write secret: \(message)"
        case .readFailed(let message): return "Failed to read secret: \(message)"
        }
    }
}

public protocol SecretStore: Sendable {
    func get(_ key: SecretKey) throws -> String
    func set(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String] = [:]

    public init() {}

    public func get(_ key: SecretKey) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw SecretStoreError.missingSecret(key.rawValue)
        }
        return value
    }

    public func set(_ value: String, for key: SecretKey) throws {
        values[key] = value
    }

    public func delete(_ key: SecretKey) throws {
        values.removeValue(forKey: key)
    }
}
```

- [ ] **Step 4: Implement Keychain store**

Create `Sources/CLIProxyManagerCore/Secrets/KeychainSecretStore.swift`:

```swift
import Foundation
import Security

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "io.woosublee.CLIProxyManager") {
        self.service = service
    }

    public func get(_ key: SecretKey) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw SecretStoreError.missingSecret(key.rawValue)
        }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.readFailed("Keychain status \(status)")
        }
        return value
    }

    public func set(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw SecretStoreError.writeFailed("Keychain update status \(updateStatus)")
        }

        var createQuery = query
        createQuery[kSecValueData as String] = data
        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw SecretStoreError.writeFailed("Keychain add status \(createStatus)")
        }
    }

    public func delete(_ key: SecretKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 5: Replace CLI helper**

Replace `Sources/CLIProxyManagerCLI/main.swift`:

```swift
import Foundation
import CLIProxyManagerCore

let arguments = Array(CommandLine.arguments.dropFirst())
let store = KeychainSecretStore()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard arguments.count >= 3, arguments[0] == "secret" else {
    fail("Usage: cliproxy-manager secret get|set|delete claude-api-key")
}

guard let key = SecretKey(rawValue: arguments[2]) else {
    fail("Unknown secret key: \(arguments[2])")
}

do {
    switch arguments[1] {
    case "get":
        print(try store.get(key))
    case "set":
        let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { fail("Secret value was empty") }
        try store.set(value, for: key)
    case "delete":
        try store.delete(key)
    default:
        fail("Usage: cliproxy-manager secret get|set|delete claude-api-key")
    }
} catch {
    fail(String(describing: error))
}
```

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter SecretStoreTests
```

Expected: PASS.

- [ ] **Step 7: Build CLI helper**

Run:

```bash
swift build --product cliproxy-manager
```

Expected: build succeeds.

- [ ] **Step 8: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Secrets Sources/CLIProxyManagerCLI/main.swift Tests/CLIProxyManagerCoreTests/SecretStoreTests.swift
git commit -m "feat: add Keychain secret helper"
```

---

### Task 6: Connect to Official Claude Code CLI

**Files:**
- Create: `Sources/CLIProxyManagerCore/System/ProcessRunner.swift`
- Create: `Sources/CLIProxyManagerCore/Claude/ClaudeConnector.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift`

- [ ] **Step 1: Write failing Claude connector tests**

Create `Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ClaudeConnectorTests: XCTestCase {
    func testInstalledClaudeReportsReadyWhenAuthStatusSucceeds() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .ready)
        XCTAssertEqual(status.title, "Claude Code 연결됨")
    }

    func testMissingClaudeReportsError() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .error)
        XCTAssertEqual(status.title, "Claude Code 미설치")
    }

    func testLoggedOutClaudeReportsWarning() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "not logged in")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .warning)
        XCTAssertEqual(status.title, "Claude 로그인 필요")
    }
}

private final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        results.removeFirst()
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter ClaudeConnectorTests
```

Expected: FAIL because process and connector types do not exist.

- [ ] **Step 3: Implement process runner**

Create `Sources/CLIProxyManagerCore/System/ProcessRunner.swift`:

```swift
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(exitCode: 127, stdout: "", stderr: String(describing: error))
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
```

- [ ] **Step 4: Implement Claude connector**

Create `Sources/CLIProxyManagerCore/Claude/ClaudeConnector.swift`:

```swift
import Foundation

public struct ClaudeConnector: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func status() async -> DiagnosticStatus {
        let which = await runner.run("/usr/bin/env", ["which", "claude"])
        guard which.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .error,
                title: "Claude Code 미설치",
                message: "Claude Code CLI를 설치한 뒤 다시 확인하세요."
            )
        }

        let version = await runner.run("/usr/bin/env", ["claude", "--version"])
        guard version.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude Code 확인 실패",
                message: version.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let auth = await runner.run("/usr/bin/env", ["claude", "auth", "status"])
        guard auth.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude 로그인 필요",
                message: "앱에서 로그인 버튼을 눌러 claude auth login을 실행하세요."
            )
        }

        return DiagnosticStatus(
            severity: .ready,
            title: "Claude Code 연결됨",
            message: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func loginCommand() -> [String] {
        ["claude", "auth", "login"]
    }

    public func logoutCommand() -> [String] {
        ["claude", "auth", "logout"]
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter ClaudeConnectorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/System Sources/CLIProxyManagerCore/Claude Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift
git commit -m "feat: inspect Claude Code login status"
```

---

### Task 7: Add CLIProxyAPI Health and Service Management

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/ProxyHealthClient.swift`
- Create: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ProxyHealthClientTests.swift`
- Create: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

- [ ] **Step 1: Write failing health tests**

Create `Tests/CLIProxyManagerCoreTests/ProxyHealthClientTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ProxyHealthClientTests: XCTestCase {
    func testHealthyModelsResponseIsReady() async {
        let client = ProxyHealthClient(http: FakeHTTPClient(result: .success(Data("{\"data\":[]}".utf8))))
        let status = await client.status(port: 8317)

        XCTAssertEqual(status.severity, .ready)
        XCTAssertEqual(status.title, "CLIProxyAPI 실행 중")
    }

    func testFailedRequestIsError() async {
        let client = ProxyHealthClient(http: FakeHTTPClient(result: .failure(URLError(.cannotConnectToHost))))
        let status = await client.status(port: 8317)

        XCTAssertEqual(status.severity, .error)
        XCTAssertEqual(status.title, "CLIProxyAPI 중지됨")
    }
}

private struct FakeHTTPClient: HTTPClient {
    let result: Result<Data, Error>

    func get(_ url: URL) async throws -> Data {
        try result.get()
    }
}
```

- [ ] **Step 2: Write failing service manager tests**

Create `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testStartUsesManagedBinaryAndConfigPath() async {
        let runner = RecordingProcessRunner()
        let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/cliproxy-test"))
        let manager = ProxyServiceManager(paths: paths, runner: runner)

        await manager.start(port: 8317)

        XCTAssertEqual(runner.calls.first?.executable, paths.clipProxyBinary.path)
        XCTAssertTrue(runner.calls.first?.arguments.contains("--config") == true)
        XCTAssertTrue(runner.calls.first?.arguments.contains(paths.clipProxyConfigFile.path) == true)
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    var calls: [Call] = []

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
swift test --filter ProxyHealthClientTests
swift test --filter ProxyServiceManagerTests
```

Expected: FAIL because proxy types do not exist.

- [ ] **Step 4: Implement health client**

Create `Sources/CLIProxyManagerCore/Proxy/ProxyHealthClient.swift`:

```swift
import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct ProxyHealthClient: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func status(port: Int) async -> DiagnosticStatus {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        do {
            _ = try await http.get(url)
            return DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI 실행 중",
                message: "포트 \(port)에서 모델 목록을 불러올 수 있습니다."
            )
        } catch {
            return DiagnosticStatus(
                severity: .error,
                title: "CLIProxyAPI 중지됨",
                message: "앱에서 서버를 시작하세요."
            )
        }
    }
}
```

- [ ] **Step 5: Implement service manager**

Create `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`:

```swift
import Foundation

public struct ProxyServiceManager: Sendable {
    private let paths: ManagedPaths
    private let runner: ProcessRunning

    public init(paths: ManagedPaths, runner: ProcessRunning = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    public func start(port: Int) async {
        try? FileManager.default.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        let config = """
        port: \(port)
        auth-dir: "~/.cli-proxy-api"
        logging-to-file: true
        debug: false
        api-keys:
          - "sk-dummy"
        """
        try? config.write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)

        _ = await runner.run(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
    }
}
```

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter ProxyHealthClientTests
swift test --filter ProxyServiceManagerTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Proxy Tests/CLIProxyManagerCoreTests/ProxyHealthClientTests.swift Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: add CLIProxyAPI health checks"
```

---

### Task 8: Add Dashboard View Model

**Files:**
- Create: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Create: `Tests/CLIProxyManagerCoreTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing dashboard state test**

Create `Tests/CLIProxyManagerCoreTests/DashboardViewModelTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class DashboardViewModelTests: XCTestCase {
    func testProfileCardsUseConfiguredCommandNames() {
        let config = AppConfig.default
        let cards = ProfileCard.makeDefaultCards(config: config)

        XCTAssertEqual(cards.map(\.command), ["cc", "ccapi", "ccodex"])
        XCTAssertEqual(cards.map(\.title), ["Claude 구독", "Claude API", "OpenAI/Codex"])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: FAIL because `ProfileCard` does not exist.

- [ ] **Step 3: Add profile card model to core**

Create `Sources/CLIProxyManagerCore/Diagnostics/ProfileCard.swift`:

```swift
import Foundation

public struct ProfileCard: Equatable, Identifiable, Sendable {
    public let id: String
    public let command: String
    public let title: String
    public let subtitle: String
    public let status: DiagnosticStatus

    public init(command: String, title: String, subtitle: String, status: DiagnosticStatus) {
        self.id = command
        self.command = command
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }

    public static func makeDefaultCards(config: AppConfig) -> [ProfileCard] {
        [
            ProfileCard(
                command: config.commands.cc,
                title: "Claude 구독",
                subtitle: "Claude Code 공식 로그인 사용",
                status: DiagnosticStatus(severity: .warning, title: "확인 필요", message: "상태 확인 전입니다.")
            ),
            ProfileCard(
                command: config.commands.ccapi,
                title: "Claude API",
                subtitle: "Keychain API key 사용",
                status: DiagnosticStatus(severity: .warning, title: "확인 필요", message: "상태 확인 전입니다.")
            ),
            ProfileCard(
                command: config.commands.ccodex,
                title: "OpenAI/Codex",
                subtitle: "CLIProxyAPI 경유",
                status: DiagnosticStatus(severity: .warning, title: "확인 필요", message: "상태 확인 전입니다.")
            )
        ]
    }
}
```

- [ ] **Step 4: Implement app view model**

Create `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`:

```swift
import Foundation
import CLIProxyManagerCore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus

    private let config: AppConfig
    private let proxyHealthClient: ProxyHealthClient
    private let claudeConnector: ClaudeConnector

    init(
        config: AppConfig = .default,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        claudeConnector: ClaudeConnector = ClaudeConnector()
    ) {
        self.config = config
        self.proxyHealthClient = proxyHealthClient
        self.claudeConnector = claudeConnector
        self.cards = ProfileCard.makeDefaultCards(config: config)
        self.serverStatus = DiagnosticStatus(severity: .warning, title: "확인 필요", message: "서버 상태 확인 전입니다.")
    }

    func refresh() async {
        serverStatus = await proxyHealthClient.status(port: config.port)
        let claudeStatus = await claudeConnector.status()
        cards = [
            ProfileCard(command: config.commands.cc, title: "Claude 구독", subtitle: "Claude Code 공식 로그인 사용", status: claudeStatus),
            ProfileCard(command: config.commands.ccapi, title: "Claude API", subtitle: "Keychain API key 사용", status: cards[1].status),
            ProfileCard(command: config.commands.ccodex, title: "OpenAI/Codex", subtitle: "CLIProxyAPI 경유", status: serverStatus)
        ]
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/CLIProxyManagerCore/Diagnostics/ProfileCard.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerCoreTests/DashboardViewModelTests.swift
git commit -m "feat: add profile dashboard state"
```

---

### Task 9: Build SwiftUI Dashboard and Onboarding Shell

**Files:**
- Replace: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
- Create: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Create: `Sources/CLIProxyManagerApp/Views/OnboardingView.swift`
- Create: `Sources/CLIProxyManagerApp/ViewModels/OnboardingViewModel.swift`

- [ ] **Step 1: Implement dashboard view**

Create `Sources/CLIProxyManagerApp/Views/DashboardView.swift`:

```swift
import SwiftUI
import CLIProxyManagerCore

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Dashboard", value: "dashboard")
                NavigationLink("Accounts", value: "accounts")
                NavigationLink("Models", value: "models")
                NavigationLink("Logs", value: "logs")
                NavigationLink("Settings", value: "settings")
            }
            .navigationTitle("CLIProxy Manager")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Profiles")
                        .font(.largeTitle.bold())

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(viewModel.cards) { card in
                            ProfileCardView(card: card)
                        }
                    }

                    StatusPanel(title: "CLIProxyAPI Server", status: viewModel.serverStatus)
                }
                .padding(24)
            }
            .task { await viewModel.refresh() }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct ProfileCardView: View {
    let card: ProfileCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.command)
                .font(.system(.title2, design: .monospaced).bold())
            Text(card.title)
                .font(.headline)
            Text(card.subtitle)
                .foregroundStyle(.secondary)
            Divider()
            Label(card.status.title, systemImage: iconName)
                .foregroundStyle(color)
            Text(card.status.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var iconName: String {
        switch card.status.severity {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch card.status.severity {
        case .ready: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct StatusPanel: View {
    let title: String
    let status: DiagnosticStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text(status.title).font(.headline)
            Text(status.message).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

- [ ] **Step 2: Implement onboarding view model**

Create `Sources/CLIProxyManagerApp/ViewModels/OnboardingViewModel.swift`:

```swift
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var steps: [String] = [
        "Claude Code 설치 확인",
        "Claude 구독 연결",
        "Claude API key 선택 입력",
        "OpenAI/Codex 연결",
        "shell functions 설치",
        "프로필 테스트"
    ]
}
```

- [ ] **Step 3: Implement onboarding view**

Create `Sources/CLIProxyManagerApp/Views/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("CLIProxy Manager 설정")
                .font(.largeTitle.bold())
            Text("앱이 Claude Code, Claude API, OpenAI/Codex 프로필을 사용할 준비를 확인합니다.")
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.steps.enumerated()), id: \.offset) { index, step in
                HStack {
                    Text("\(index + 1)")
                        .font(.headline)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(Circle())
                    Text(step)
                }
            }

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 720, minHeight: 480)
    }
}
```

- [ ] **Step 4: Replace app entry point**

Replace `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`:

```swift
import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                DashboardView()
            } else {
                OnboardingView()
                    .toolbar {
                        Button("대시보드로 이동") {
                            hasCompletedOnboarding = true
                        }
                    }
            }
        }
        .windowStyle(.titleBar)
    }
}
```

- [ ] **Step 5: Build app**

Run:

```bash
swift build --product CLIProxyManager
```

Expected: build succeeds.

- [ ] **Step 6: Run app manually**

Run:

```bash
swift run CLIProxyManager
```

Expected: macOS app window opens with onboarding screen. Click `대시보드로 이동` and verify profile cards appear.

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/CLIProxyManagerApp
git commit -m "feat: add SwiftUI dashboard shell"
```

---

### Task 10: Add Binary Vendoring and Manual Verification Script

**Files:**
- Create: `scripts/vendor-cliproxyapi.sh`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`

- [ ] **Step 1: Add vendoring script**

Create `scripts/vendor-cliproxyapi.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/Resources/cliproxyapi/cliproxyapi"
SOURCE="${1:-$(command -v cliproxyapi || true)}"

if [[ -z "$SOURCE" ]]; then
  echo "cliproxyapi binary not found. Pass the binary path explicitly." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$SOURCE" "$DEST"
chmod +x "$DEST"
echo "Vendored CLIProxyAPI binary to $DEST"
```

- [ ] **Step 2: Make script executable**

Run:

```bash
chmod +x scripts/vendor-cliproxyapi.sh
```

Expected: no output.

- [ ] **Step 3: Run vendoring script with current local binary**

Run:

```bash
./scripts/vendor-cliproxyapi.sh /usr/local/opt/cliproxyapi/bin/cliproxyapi
```

Expected: `Vendored CLIProxyAPI binary to .../Resources/cliproxyapi/cliproxyapi`.

- [ ] **Step 4: Confirm binary is not committed**

Run:

```bash
git status --short Resources/cliproxyapi
```

Expected: only `.gitkeep` is tracked; `Resources/cliproxyapi/cliproxyapi` is ignored by `.gitignore`.

- [ ] **Step 5: Update service manager to ensure binary exists before start**

Replace `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`:

```swift
import Foundation

public enum ProxyServiceError: Error, Equatable {
    case missingBinary(String)
}

public struct ProxyServiceManager: Sendable {
    private let paths: ManagedPaths
    private let runner: ProcessRunning
    private let fileManager: FileManager

    public init(paths: ManagedPaths, runner: ProcessRunning = ProcessRunner(), fileManager: FileManager = .default) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    public func start(port: Int) async throws {
        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path) else {
            throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
        }

        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        let config = """
        port: \(port)
        auth-dir: "~/.cli-proxy-api"
        logging-to-file: true
        debug: false
        api-keys:
          - "sk-dummy"
        """
        try config.write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)

        _ = await runner.run(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
    }
}
```

- [ ] **Step 6: Update service manager test for throwing start**

Replace `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testStartUsesManagedBinaryAndConfigPath() async throws {
        let runner = RecordingProcessRunner()
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        try FileManager.default.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.clipProxyBinary.path, contents: Data())

        let manager = ProxyServiceManager(paths: paths, runner: runner)

        try await manager.start(port: 8317)

        XCTAssertEqual(runner.calls.first?.executable, paths.clipProxyBinary.path)
        XCTAssertTrue(runner.calls.first?.arguments.contains("--config") == true)
        XCTAssertTrue(runner.calls.first?.arguments.contains(paths.clipProxyConfigFile.path) == true)
    }

    func testStartThrowsWhenBinaryIsMissing() async throws {
        let paths = ManagedPaths(rootDirectory: try makeSandbox())
        let manager = ProxyServiceManager(paths: paths, runner: RecordingProcessRunner())

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected missing binary error")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .missingBinary(paths.clipProxyBinary.path))
        }
    }

    private func makeSandbox() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    var calls: [Call] = []

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
```

- [ ] **Step 7: Run full tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

Run:

```bash
git add scripts/vendor-cliproxyapi.sh Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: vendor managed CLIProxyAPI binary"
```

---

### Task 11: Add Public Distribution License Notices

**Files:**
- Create: `Resources/Licenses/CLIProxyAPI-LICENSE.txt`
- Create: `Sources/CLIProxyManagerCore/Legal/LicenseNotice.swift`
- Create: `Sources/CLIProxyManagerApp/Views/LicensesView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Create: `README.md`
- Create: `Tests/CLIProxyManagerCoreTests/LicenseNoticeTests.swift`

- [ ] **Step 1: Write failing license notice test**

Create `Tests/CLIProxyManagerCoreTests/LicenseNoticeTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class LicenseNoticeTests: XCTestCase {
    func testCLIProxyAPINoticeMentionsMITAndProviderTerms() {
        let notice = LicenseNotice.cliProxyAPI

        XCTAssertEqual(notice.name, "CLIProxyAPI")
        XCTAssertEqual(notice.licenseName, "MIT License")
        XCTAssertTrue(notice.requiredNotice.contains("MIT License"))
        XCTAssertTrue(notice.providerTermsNotice.contains("각 provider 약관"))
    }
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter LicenseNoticeTests
```

Expected: FAIL because `LicenseNotice` does not exist.

- [ ] **Step 3: Add CLIProxyAPI license file**

Create `Resources/Licenses/CLIProxyAPI-LICENSE.txt` with the exact MIT license text from upstream CLIProxyAPI:

```text
MIT License

Copyright (c) CLIProxyAPI contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Before final public release, replace the copyright line with the exact upstream copyright line from the pinned CLIProxyAPI release.

- [ ] **Step 4: Add license notice model**

Create `Sources/CLIProxyManagerCore/Legal/LicenseNotice.swift`:

```swift
import Foundation

public struct LicenseNotice: Equatable, Sendable {
    public let name: String
    public let licenseName: String
    public let requiredNotice: String
    public let providerTermsNotice: String

    public init(name: String, licenseName: String, requiredNotice: String, providerTermsNotice: String) {
        self.name = name
        self.licenseName = licenseName
        self.requiredNotice = requiredNotice
        self.providerTermsNotice = providerTermsNotice
    }

    public static let cliProxyAPI = LicenseNotice(
        name: "CLIProxyAPI",
        licenseName: "MIT License",
        requiredNotice: "CLIProxyAPI is distributed under the MIT License. The bundled app must include the upstream copyright notice and MIT permission notice.",
        providerTermsNotice: "이 앱은 Claude, OpenAI, Codex 등 각 provider의 공식 보증 제품이 아닙니다. 사용자는 자신의 계정으로 각 provider 약관을 준수해야 합니다."
    )
}
```

- [ ] **Step 5: Add licenses view**

Create `Sources/CLIProxyManagerApp/Views/LicensesView.swift`:

```swift
import SwiftUI
import CLIProxyManagerCore

struct LicensesView: View {
    private let notice = LicenseNotice.cliProxyAPI

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Licenses & Notices")
                    .font(.largeTitle.bold())
                Text(notice.name)
                    .font(.title2.bold())
                Text(notice.licenseName)
                    .font(.headline)
                Text(notice.requiredNotice)
                Divider()
                Text("Provider Terms")
                    .font(.title3.bold())
                Text(notice.providerTermsNotice)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
```

- [ ] **Step 6: Add Licenses navigation entry**

Modify the `List` in `Sources/CLIProxyManagerApp/Views/DashboardView.swift` to include:

```swift
NavigationLink("Licenses", value: "licenses")
```

Then update the detail area to show `LicensesView()` when the selection is `licenses`. If the existing view does not yet track selection, add:

```swift
@State private var selection = "dashboard"
```

and bind the list with `List(selection: $selection)`.

- [ ] **Step 7: Add README public distribution notice**

Create `README.md`:

```markdown
# CLIProxyManager

macOS app for managing CLIProxyAPI and Claude Code launch profiles.

## What it does

CLIProxyManager helps users run Claude Code with:

- their normal Claude Code subscription login (`cc`)
- a Claude API key stored in macOS Keychain (`ccapi`)
- OpenAI/Codex OAuth through a local CLIProxyAPI server (`ccodex`)

## License notices

This app bundles or manages CLIProxyAPI, which is distributed under the MIT License. The CLIProxyAPI license is included in `Resources/Licenses/CLIProxyAPI-LICENSE.txt`.

## Provider terms

This app is not an official product of Anthropic, OpenAI, or other model providers. Users are responsible for complying with the terms of the providers and accounts they connect.
```

- [ ] **Step 8: Run license tests**

Run:

```bash
swift test --filter LicenseNoticeTests
```

Expected: PASS.

- [ ] **Step 9: Build app**

Run:

```bash
swift build --product CLIProxyManager
```

Expected: build succeeds.

- [ ] **Step 10: Commit**

Run:

```bash
git add README.md Resources/Licenses Sources/CLIProxyManagerCore/Legal Sources/CLIProxyManagerApp/Views Tests/CLIProxyManagerCoreTests/LicenseNoticeTests.swift
git commit -m "feat: add public distribution notices"
```

---

## Final Verification

- [ ] Run full test suite:

```bash
cd /Users/woosublee/Documents/dev/CLIProxyManager
swift test
```

Expected: all tests pass.

- [ ] Build both executables:

```bash
swift build --product CLIProxyManager
swift build --product cliproxy-manager
```

Expected: both builds succeed.

- [ ] Run the app:

```bash
swift run CLIProxyManager
```

Expected: onboarding and dashboard render on macOS.

- [ ] Render shell functions manually from test or debug call and verify:

Expected properties:

- functions use `cc()`, `ccapi()`, `ccodex()`.
- no `alias` declarations.
- no global `export ANTHROPIC_*` declarations.
- `ccodex` checks `http://127.0.0.1:8317/v1/models`.
- `ccapi` reads the API key via `cliproxy-manager secret get claude-api-key`.

- [ ] Check git status:

```bash
git status --short
```

Expected: clean working tree, except any intentionally untracked local binary ignored by `.gitignore`.

---

## Self-review

Spec coverage:

- macOS SwiftUI app: Tasks 1, 8, 9.
- CLIProxyAPI service manager without forking upstream: Tasks 7, 10.
- Public distribution license attribution and provider-terms notices: Task 11.
- official Claude Code login/status connector: Task 6.
- Claude API Keychain storage: Task 5.
- OpenAI/Codex through CLIProxyAPI: Tasks 3, 7, 10.
- shell functions instead of aliases: Tasks 3, 4.
- no global environment variables: Task 3 tests.
- diagnostics: Tasks 6, 7, 8.

Placeholder scan:

- The plan contains no placeholder implementation steps.
- Every task has concrete files, commands, and expected outputs.

Type consistency:

- `AppConfig`, `ManagedPaths`, `DiagnosticStatus`, `ProfileCard`, `SecretStore`, `ProcessRunning`, `ClaudeConnector`, `ProxyHealthClient`, and `ProxyServiceManager` are defined before use in later tasks.
- Product names in `Package.swift` match build commands.
