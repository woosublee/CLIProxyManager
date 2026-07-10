# CPM Runtime CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GUI를 실행하지 않은 동일 macOS 사용자 SSH 세션에서 `cpm`으로 CLIProxyAPI 프록시와 GUI 앱의 상태·lifecycle·로그를 안전하게 제어한다.

**Architecture:** 기존 `ProxyServiceManager`, `AppConfigStore`, `ProxyHealthClient`를 Core facade로 조합하고, `CLIProxyManagerCommand`는 인자 해석과 output/exit-code 경계만 담당하게 만든다. 별도 daemon, IPC, HTTP 관리 API는 만들지 않으며 CLI와 GUI는 같은 managed paths와 현재 사용자의 `launchctl` domain을 사용한다.

**Tech Stack:** Swift 5.10, macOS 15+, Foundation, existing `ProcessRunner`, Swift Package Manager, XCTest, `launchctl`, `open`, `osascript`, `tail`.

## Global Constraints

- 지원 플랫폼은 macOS 15 이상이다.
- GUI가 없어도 `cpm start|stop|restart|status|logs`가 동작해야 한다.
- `cpm start`는 프록시만 제어하고 GUI 앱을 시작하지 않는다. `cpm app start`는 프록시를 시작하지 않는다.
- CLI는 같은 non-root macOS 사용자 계정의 `~/.cliproxy-manager`와 user `launchctl` domain만 다룬다. `sudo cpm`은 mutation 전에 exit code `3`으로 중단한다.
- daemon, IPC, 외부 HTTP 관리 API, 원격 machine fleet 기능은 추가하지 않는다.
- `status`는 `--json`을 지원하고 stdout에는 결과만, stderr에는 diagnostic/error만 출력한다.
- 성공은 `0`, 일반 실행 실패는 `1`, usage는 `2`, 설치·권한·사용자 precondition은 `3`이다.
- 기존 `cliproxy-manager secret`과 `cliproxy-manager routing next`는 기능·출력 호환성을 유지한다.
- proxy log의 실제 경로는 `<ManagedPaths.authDirectory>/logs`이며, `<root>/logs`를 새로 만들거나 조회 대상에 사용하지 않는다.

---

## File Structure

- Modify: `Package.swift`
  - 새 `CPMCLI` executable target과 `cpm` product를 추가하고, 기존 `CLIProxyManagerCLI`/`cliproxy-manager` product는 compatibility entry point로 유지한다.
- Modify: `Sources/CLIProxyManagerCLI/main.swift`
  - legacy executable의 async dispatcher 실행과 typed error → exit-code/stderr mapping을 제공한다.
- Create: `Sources/CPMCLI/main.swift`
  - 공식 `cpm` executable의 async dispatcher 실행과 typed error → exit-code/stderr mapping을 제공한다.
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
  - legacy commands를 보존하면서 runtime command group으로 dispatch한다.
- Create: `Sources/CLIProxyManagerCore/CLI/CLICommandSupport.swift`
  - `CLIProxyManagerCommandError`, exit code, stdout/stderr/confirmation abstraction을 정의한다.
- Create: `Sources/CLIProxyManagerCore/Runtime/AppBundleLocator.swift`
  - bundle helper 또는 `/Applications/CLIProxyManager.app`에서 required proxy resource와 optional helper resource를 안전하게 찾는다.
- Create: `Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift`
  - config port, bundle proxy resource, `ProxyServiceManager`, health client를 조합한다.
- Create: `Sources/CLIProxyManagerCore/Runtime/ProxyLogService.swift`
  - 실제 proxy log file 선택, tail, `tail -F` follow를 분리한다.
- Create: `Sources/CLIProxyManagerCore/Runtime/AppLifecycleService.swift`
  - GUI bundle 상태와 `open`/`osascript` 기반 lifecycle을 제공한다.
- Create: `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`
  - app/helper/proxy 기본 상태를 stable Codable model로 조합한다.
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - `proxyLogsDirectory`를 추가한다.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Diagnostics Reveal이 `proxyLogsDirectory`를 열도록 바꾼다.
- Modify tests: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`, `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Create tests: `Tests/CLIProxyManagerCoreTests/CLICommandSupportTests.swift`, `Tests/CLIProxyManagerCoreTests/AppBundleLocatorTests.swift`, `Tests/CLIProxyManagerCoreTests/ProxyRuntimeServiceTests.swift`, `Tests/CLIProxyManagerCoreTests/ProxyLogServiceTests.swift`, `Tests/CLIProxyManagerCoreTests/AppLifecycleServiceTests.swift`, `Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift`
- Modify test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

`AutomaticShellInstallService`의 기본 helper를 `cpm`으로 바꾸는 작업은 bundle과 external helper가 실제로 함께 설치되는 app/helper update 계획의 Task 1에서 수행한다. 이 runtime plan만 완료된 상태에서는 기존 앱 bundle에 `cpm` helper가 아직 없을 수 있으므로 shell renderer의 default를 먼저 바꾸지 않는다.

---

### Task 1: `cpm` product, command boundary, legacy command compatibility

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CLIProxyManagerCLI/main.swift`
- Create: `Sources/CPMCLI/main.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Create: `Sources/CLIProxyManagerCore/CLI/CLICommandSupport.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLICommandSupportTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

**Interfaces:**
- Produces: `public enum CLICommandExitCode: Int32 { case success = 0, failure = 1, usage = 2, prerequisite = 3 }`
- Produces: `public protocol CLICommandOutputWriting: Sendable { var isInteractive: Bool { get }; func writeStdout(_:) ; func writeStderr(_:) ; func confirm(_:) -> Bool }`
- Produces later: runtime command service contracts after their corresponding result types exist in Tasks 2–5.
- Consumes later: every runtime service returns only Codable/Equatable Core value types and throws `CLIProxyManagerCommandError` for user-facing errors.

- [ ] **Step 1: Add command-boundary tests before changing the executable**

Create `Tests/CLIProxyManagerCoreTests/CLICommandSupportTests.swift` with an in-memory terminal double and assert the published error contract:

```swift
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
```

- [ ] **Step 2: Run the new test to establish the failing API**

Run:

```bash
swift test --filter CLICommandSupportTests
```

Expected: compile failure because `CLICommandExitCode`, new error cases, and `CLICommandOutputWriting` do not exist.

- [ ] **Step 3: Introduce the typed output and exit-code boundary**

Create `Sources/CLIProxyManagerCore/CLI/CLICommandSupport.swift`. Keep `CLIProxyManagerCommandError.usage` as a no-associated-value case so existing tests remain source compatible; extend it instead of introducing a second command error type.

```swift
import Foundation

public enum CLICommandExitCode: Int32, Sendable {
    case success = 0
    case failure = 1
    case usage = 2
    case prerequisite = 3
}

public protocol CLICommandOutputWriting: Sendable {
    var isInteractive: Bool { get }
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
    func confirm(_ prompt: String) -> Bool
}

public struct TerminalCommandOutput: CLICommandOutputWriting {
    public init() {}
    public var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }
    public func writeStdout(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    public func writeStderr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
    public func confirm(_ prompt: String) -> Bool {
        writeStderr("\(prompt) [y/N] ")
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.lowercased())
    }
}
```

Add `case prerequisite(String)` and `case operation(String)` to the existing `CLIProxyManagerCommandError`, its `description`, and this computed property:

```swift
public var exitCode: CLICommandExitCode {
    switch self {
    case .usage, .emptySecret:
        return .usage
    case .prerequisite:
        return .prerequisite
    case .operation:
        return .failure
    }
}
```

Use `import Darwin` in the support file for `isatty` and `STDIN_FILENO`.

- [ ] **Step 4: Preserve existing command behavior while making dispatcher async-ready**

Change `CLIProxyManagerCommand.run(arguments:)` to `public func run(arguments: [String]) async throws`. Keep these exact branches before any new runtime command branch:

```swift
if arguments.count == 3, arguments[0] == "secret" {
    try runSecret(arguments: arguments)
    return
}
if arguments.count == 3, arguments[0] == "routing", arguments[1] == "next" {
    try runRoutingNext(profileID: arguments[2])
    return
}
```

Replace its current `output: @Sendable (String) -> Void` dependency with `output: any CLICommandOutputWriting`; update `runSecret` and `runRoutingNext` to call `output.writeStdout("\(value)\n")`. The old tests must continue to assert the exact secret and shell assignment content, allowing only the expected trailing newline change.

- [ ] **Step 5: Add two executable targets and map errors in both entry points**

SwiftPM cannot expose two products that point to the same executable target. In `Package.swift`, retain the existing legacy target/product and add a separate `CPMCLI` target/product, both importing `CLIProxyManagerCore`:

```swift
.executable(name: "cpm", targets: ["CPMCLI"]),
.executableTarget(
    name: "CPMCLI",
    dependencies: ["CLIProxyManagerCore"],
    path: "Sources/CPMCLI"
),
```

Keep the existing `cliproxy-manager` product for compatibility. Put identical entry-point code in `Sources/CPMCLI/main.swift` and `Sources/CLIProxyManagerCLI/main.swift`:

```swift
import CLIProxyManagerCore
import Foundation

let output = TerminalCommandOutput()
do {
    try await CLIProxyManagerCommand(output: output)
        .run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIProxyManagerCommandError {
    output.writeStderr("\(error.description)\n")
    exit(error.exitCode.rawValue)
} catch {
    output.writeStderr("\(error.localizedDescription)\n")
    exit(CLICommandExitCode.failure.rawValue)
}
```

- [ ] **Step 6: Expand legacy command regression tests and run them

Update `CLIProxyManagerCommandTests` so `testSecretGetStillPrintsSecret` and `testRoutingNextPrintsShellAssignments` call `try await command.run(arguments:)` and assert a single stdout entry ending in `\n`. Add:

```swift
func testUnknownArgumentsStillThrowUsage() async {
    let command = CLIProxyManagerCommand(output: OutputDouble(isInteractive: false))
    await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["unknown"])) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
    }
}
```

Add the repository’s standard async `XCTAssertThrowsErrorAsync` helper locally in this test file if it is not already present. Run:

```bash
swift test --filter CLICommandSupportTests
swift test --filter CLIProxyManagerCommandTests
swift build --product cpm
swift build --product cliproxy-manager
```

Expected: all tests pass and both executable products build.

- [ ] **Step 7: Commit the independently working dispatcher boundary**

```bash
git add Package.swift Sources/CLIProxyManagerCLI/main.swift Sources/CPMCLI/main.swift Sources/CLIProxyManagerCore/CLI Tests/CLIProxyManagerCoreTests/CLICommandSupportTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "feat: add cpm command boundary" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 2: Bundle discovery and proxy runtime facade

**Files:**
- Create: `Sources/CLIProxyManagerCore/Runtime/AppBundleLocator.swift`
- Create: `Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift`
- Create: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppBundleLocatorTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyRuntimeServiceTests.swift`

**Interfaces:**
- Produces: `public struct ManagedAppBundle: Equatable, Sendable` with required `appURL`, `proxyBinaryURL`, `proxyManifestURL`, `version`, `build` and optional `cpmHelperURL`, `legacyHelperURL`.
- Produces: `public protocol AppBundleLocating: Sendable { func locateInstalledApp() throws -> ManagedAppBundle }`.
- Produces: `public struct ProxyRuntimeStatus: Codable, Equatable, Sendable` with `port`, `running`, `health`, `activeVersion`, `pendingVersion`.
- Produces: `public protocol ProxyRuntimeServicing: Sendable { func status() async throws -> ProxyRuntimeStatus; func start() async throws -> ProxyRuntimeStatus; func stop() async throws -> ProxyRuntimeStatus; func restart() async throws -> ProxyRuntimeStatus }`.
- Produces: `public struct ProxyRuntimeService: ProxyRuntimeServicing`, constructed with `AppBundleLocating` and `proxyServiceFactory: @Sendable (URL?, URL?) -> any ProxyServiceControlling`.
- Consumes: `ManagedPaths`, `AppConfigStore`, `ProxyServiceManager`, `ProxyHealthClient`, `CLIProxyAPIBinaryStore`.

- [ ] **Step 1: Write failing bundle-location tests using only a temporary app fixture**

Create a fake app directory in `AppBundleLocatorTests` rather than using `/Applications`:

```swift
func testLocatesRequiredResourcesInStandardInstallPath() throws {
    let fixture = try makeAppBundle(version: "0.1.12", build: "15")
    let locator = AppBundleLocator(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"),
        standardAppURL: fixture
    )

    let bundle = try locator.locateInstalledApp()

    XCTAssertEqual(bundle.appURL, fixture)
    XCTAssertEqual(bundle.proxyBinaryURL.path, fixture.appendingPathComponent("Contents/Resources/cliproxyapi/cliproxyapi").path)
    XCTAssertNil(bundle.cpmHelperURL)
    XCTAssertEqual(bundle.legacyHelperURL?.path, fixture.appendingPathComponent("Contents/Helpers/cliproxy-manager").path)
    XCTAssertEqual(bundle.version, "0.1.12")
    XCTAssertEqual(bundle.build, "15")
}

func testRejectsBundleWithUnexpectedIdentifier() throws {
    let fixture = try makeAppBundle(identifier: "example.invalid", version: "0.1.12", build: "15")
    let locator = AppBundleLocator(executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"), standardAppURL: fixture)

    XCTAssertThrowsError(try locator.locateInstalledApp()) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("CLIProxyManager.app has an unexpected bundle identifier."))
    }
}
```

The helper `makeAppBundle` must create executable empty resource files and an `Info.plist` containing `CFBundleIdentifier = com.woosublee.CLIProxyManager`, `CFBundleShortVersionString`, and `CFBundleVersion`.

- [ ] **Step 2: Run bundle-location tests and verify they fail**

```bash
swift test --filter AppBundleLocatorTests
```

Expected: compile failure because the locator and bundle type do not exist.

- [ ] **Step 3: Implement strict bundle lookup**

Create `AppBundleLocator.swift`. The locator must try, in order, the enclosing `.app` when `executableURL` is under `Contents/Helpers`, then `standardAppURL` (default `/Applications/CLIProxyManager.app`). It must require regular files at:

```swift
let proxyBinary = contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi")
let proxyManifest = contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi.manifest.json")
let cpmHelper = contents.appendingPathComponent("Helpers/cpm")
let legacyHelper = contents.appendingPathComponent("Helpers/cliproxy-manager")
```

Read the plist with `Bundle(url:)?.bundleIdentifier`, `object(forInfoDictionaryKey:)`, reject a non-matching identifier, and throw `.prerequisite` with a specific missing-resource sentence. Require the proxy binary and proxy manifest; set `cpmHelperURL` and `legacyHelperURL` to `nil` when the corresponding helper does not exist so this plan can run against the current app bundle. Do not search arbitrary directories or trust `PATH`.

- [ ] **Step 4: Define the proxy runtime command protocol and write failing facade tests**

Create `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift` and define this protocol before implementing the concrete facade:

```swift
import Foundation

public protocol ProxyRuntimeServicing: Sendable {
    func status() async throws -> ProxyRuntimeStatus
    func start() async throws -> ProxyRuntimeStatus
    func stop() async throws -> ProxyRuntimeStatus
    func restart() async throws -> ProxyRuntimeStatus
}
```

Then write the facade tests:

In `ProxyRuntimeServiceTests`, use a sandbox `ManagedPaths` and a `ProxyServiceDouble` recording `start(port:)`, `stop()`, and `restart(port:)`. Test the public command semantics:

```swift
func testStartUsesConfiguredPortAndBundleResources() async throws {
    let paths = try makeManagedPaths(port: 8317)
    let proxy = ProxyServiceDouble()
    let service = ProxyRuntimeService(
        configLoader: { try AppConfigStore(paths: paths).load() },
        bundleLocator: BundleLocatorDouble(bundle: try makeAppBundle(version: "0.1.12", build: "15")),
        proxyServiceFactory: { _, _ in proxy },
        healthClient: HealthClientDouble(status: .ready),
        binaryStore: CLIProxyAPIBinaryStore(paths: paths)
    )

    let status = try await service.start()

    XCTAssertEqual(proxy.events, [.start(8317)])
    XCTAssertEqual(status.port, 8317)
    XCTAssertTrue(status.running)
}

func testStopDoesNotStartTheGUIApp() async throws {
    let proxy = ProxyServiceDouble()
    let service = makeRuntimeService(proxy: proxy, health: .stopped)

    _ = try await service.stop()

    XCTAssertEqual(proxy.events, [.stop])
}
```

The test double must conform to a new Core `ProxyServiceControlling` protocol, which `ProxyServiceManager` adopts.

- [ ] **Step 5: Implement the facade with existing lifecycle code**

Add this public protocol beside `ProxyServiceManager` and conform the real manager without changing its existing behavior:

```swift
public protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceControlling {}
```

Implement `ProxyRuntimeService` so every status reads the current config port and calls `ProxyHealthClient.status(port:)`. Convert `DiagnosticStatus.severity == .ready` to `running == true`; preserve the health title/message in a Codable `ProxyHealthSummary`. Read active and pending manifests through `CLIProxyAPIBinaryStore` and expose their version strings or `nil`.

For `start` and `restart`, resolve bundle proxy URLs via `AppBundleLocating`, create a `ProxyServiceControlling` using `proxyServiceFactory(bundle.proxyBinaryURL, bundle.proxyManifestURL)`, and call it with the configured port. The default factory must construct `ProxyServiceManager(paths:bundledBinaryURL:bundledManifestURL:)`, so a fresh install has a verified bundled baseline. For `stop`, call a factory-created manager with `nil` bundle URLs and do not require the app bundle; a managed binary/config may still be stopped after the app has been removed.

- [ ] **Step 6: Run focused and existing lifecycle tests**

```bash
swift test --filter AppBundleLocatorTests
swift test --filter ProxyRuntimeServiceTests
swift test --filter ProxyServiceManagerTests
```

Expected: PASS. Existing `ProxyServiceManager` config, launch, orphan-cleanup, and user-updated-binary tests remain green.

- [ ] **Step 7: Commit the proxy runtime facade**

```bash
git add Sources/CLIProxyManagerCore/Runtime/AppBundleLocator.swift Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift Tests/CLIProxyManagerCoreTests/AppBundleLocatorTests.swift Tests/CLIProxyManagerCoreTests/ProxyRuntimeServiceTests.swift
git commit -m "feat: add headless proxy runtime service" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 3: Real proxy log discovery and streaming

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Create: `Sources/CLIProxyManagerCore/Runtime/ProxyLogService.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyLogServiceTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Modify test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: `ManagedPaths.proxyLogsDirectory: URL` equal to `authDirectory.appendingPathComponent("logs", isDirectory: true)`.
- Produces: `public struct ProxyLogSnapshot: Equatable, Sendable { let fileURL: URL; let text: String }`.
- Produces: `public protocol LogFollowing: Sendable { func follow(fileURL: URL) throws }`.
- Produces: `public protocol ProxyLogServicing: Sendable { func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot; func follow() throws }` in `RuntimeCommandServices.swift`.
- Produces: `public struct ProxyLogService: ProxyLogServicing`.

- [ ] **Step 1: Write failing managed-path and log-selection tests**

Add this path test to `AppConfigTests`:

```swift
func testManagedPathsUseAuthLogsForProxyRuntimeLogs() {
    let root = URL(fileURLWithPath: "/tmp/managed", isDirectory: true)
    let paths = ManagedPaths(rootDirectory: root)
    XCTAssertEqual(paths.proxyLogsDirectory, root.appendingPathComponent("auth/logs", isDirectory: true))
}
```

Create `ProxyLogServiceTests` with sandbox log files:

```swift
func testReadsMainLogLastWhenItExists() throws {
    let paths = try makePaths()
    try write("one\ntwo\nthree\n", to: paths.proxyLogsDirectory.appendingPathComponent("main.log"))
    try write("newest-but-not-main\n", to: paths.proxyLogsDirectory.appendingPathComponent("error-new.log"))

    let snapshot = try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(2)

    XCTAssertEqual(snapshot.fileURL.lastPathComponent, "main.log")
    XCTAssertEqual(snapshot.text, "two\nthree\n")
}

func testFallsBackToMostRecentlyModifiedRegularLog() throws {
    let paths = try makePaths()
    try write("old\n", to: paths.proxyLogsDirectory.appendingPathComponent("old.log"), modifiedAt: .distantPast)
    try write("new\n", to: paths.proxyLogsDirectory.appendingPathComponent("new.log"), modifiedAt: .now)

    let snapshot = try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(200)

    XCTAssertEqual(snapshot.fileURL.lastPathComponent, "new.log")
}

func testRejectsSymlinkCandidateOutsideManagedLogs() throws {
    let paths = try makePaths()
    let outside = paths.rootDirectory.appendingPathComponent("secret.log")
    try write("private", to: outside)
    try FileManager.default.createSymbolicLink(at: paths.proxyLogsDirectory.appendingPathComponent("main.log"), withDestinationURL: outside)

    XCTAssertThrowsError(try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(10))
}
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
swift test --filter AppConfigTests/testManagedPathsUseAuthLogsForProxyRuntimeLogs
swift test --filter ProxyLogServiceTests
```

Expected: compile failure because `proxyLogsDirectory` and `ProxyLogService` do not exist.

- [ ] **Step 3: Implement safe log lookup and `tail -F` adapter**

Add this protocol to `RuntimeCommandServices.swift` before declaring `ProxyLogService`:

```swift
public protocol ProxyLogServicing: Sendable {
    func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot
    func follow() throws
}
```

Add to `ManagedPaths`:

```swift
public var proxyLogsDirectory: URL {
    authDirectory.appendingPathComponent("logs", isDirectory: true)
}
```

Leave `logsDirectory` source-compatible for this commit, but remove all app call sites that use it for proxy diagnostics.

In `ProxyLogService`, list only direct children of `proxyLogsDirectory` with `.isRegularFileKey`, `.isSymbolicLinkKey`, and `.contentModificationDateKey`; reject symlinks; prefer a regular `main.log`; otherwise pick the latest modified file whose extension is exactly `log`. Read trailing lines by splitting UTF-8 text with `omittingEmptySubsequences: false`, retaining at most the requested positive count, then append one newline when the source ends in a newline.

Implement the live follower as:

```swift
public struct TailProcessFollower: LogFollowing {
    public func follow(fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-n", "0", "-F", fileURL.path]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
    }
}
```

`ProxyLogService.follow()` must locate the same safe file and call the injected follower, allowing a test double to verify the selected path without starting an unbounded process.

- [ ] **Step 4: Change the GUI Reveal path and test it**

In `DashboardViewModel.revealLogsInFinder()`, replace `ManagedPaths().logsDirectory` with `ManagedPaths().proxyLogsDirectory`. Update the test that records the opened URL to assert `auth/logs`; do not create `<root>/logs` in the implementation.

- [ ] **Step 5: Run the log and affected app tests**

```bash
swift test --filter ProxyLogServiceTests
swift test --filter AppConfigTests/testManagedPathsUseAuthLogsForProxyRuntimeLogs
swift test --filter DashboardViewModelTests
```

Expected: PASS.

- [ ] **Step 6: Commit the actual-log correction**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/Runtime/ProxyLogService.swift Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerCoreTests/ProxyLogServiceTests.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: expose managed proxy logs to cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 4: GUI app lifecycle service that does not affect proxy lifecycle

**Files:**
- Create: `Sources/CLIProxyManagerCore/Runtime/AppLifecycleService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppLifecycleServiceTests.swift`

**Interfaces:**
- Produces: `public struct AppLifecycleStatus: Codable, Equatable, Sendable { let installed: Bool; let running: Bool; let path: String?; let version: String?; let build: String? }`.
- Produces: `public protocol AppLifecycleControlling: Sendable { func status() async throws -> AppLifecycleStatus; func start() async throws -> AppLifecycleStatus; func stop() async throws -> AppLifecycleStatus; func restart() async throws -> AppLifecycleStatus }` in `RuntimeCommandServices.swift`.
- Produces: `public struct AppLifecycleService: AppLifecycleControlling`.
- Consumes: `AppBundleLocating`, `ProcessRunning` and an injected `AppProcessInspecting` protocol.

- [ ] **Step 1: Write failing lifecycle behavior tests using process doubles**

Create `AppLifecycleServiceTests` and use an `AppProcessInspectorDouble` rather than executing `open` or `osascript`:

```swift
func testStartUsesOpenWithTheInstalledBundlePath() async throws {
    let runner = ProcessRunnerDouble(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
    let inspector = AppProcessInspectorDouble(runningValues: [false, true])
    let service = makeService(runner: runner, inspector: inspector)

    let status = try await service.start()

    XCTAssertEqual(runner.calls, [
        ("/usr/bin/open", ["-a", "/Applications/CLIProxyManager.app"])
    ])
    XCTAssertTrue(status.running)
}

func testStopRequestsNormalQuitAndNeverCallsProxyControl() async throws {
    let runner = ProcessRunnerDouble(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
    let inspector = AppProcessInspectorDouble(runningValues: [true, false])
    let service = makeService(runner: runner, inspector: inspector)

    _ = try await service.stop()

    XCTAssertEqual(runner.calls.first, (
        "/usr/bin/osascript",
        ["-e", "tell application id \"com.woosublee.CLIProxyManager\" to quit"]
    ))
}

func testStartReportsPrerequisiteWhenAppIsNotInstalled() async {
    let service = makeService(locator: MissingBundleLocator())
    await XCTAssertThrowsErrorAsync(try await service.start()) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("CLIProxyManager.app is not installed at /Applications/CLIProxyManager.app."))
    }
}
```

- [ ] **Step 2: Run the lifecycle tests and verify they fail**

```bash
swift test --filter AppLifecycleServiceTests
```

Expected: compile failure because `AppLifecycleService` and `AppProcessInspecting` do not exist.

- [ ] **Step 3: Implement app process inspection and lifecycle actions**

Add this protocol to `RuntimeCommandServices.swift` before declaring `AppLifecycleService`:

```swift
public protocol AppLifecycleControlling: Sendable {
    func status() async throws -> AppLifecycleStatus
    func start() async throws -> AppLifecycleStatus
    func stop() async throws -> AppLifecycleStatus
    func restart() async throws -> AppLifecycleStatus
}
```

Define:

```swift
public protocol AppProcessInspecting: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}
```

Implement `PgrepAppProcessInspector` using `ProcessRunning.run("/usr/bin/pgrep", ["-x", "CLIProxyManager"])`; `exitCode == 0` is running. In `AppLifecycleService`:

- `status` returns `installed = false` when the bundle locator throws `.prerequisite`, but rethrows unexpected locator errors.
- `start` resolves the bundle, runs `/usr/bin/open -a <app path>`, then polls the inspector every 100 ms for up to 3 seconds. If `open` fails or the process never appears, throw `.operation` with its stderr or `Aqua GUI session is unavailable; the app could not start.`
- `stop` returns a non-error `running = false` when already stopped. Otherwise run exactly `osascript -e 'tell application id "com.woosublee.CLIProxyManager" to quit'`, poll for 3 seconds, and throw `.operation("CLIProxyManager did not exit after a normal quit request.")` if still running. Do not send `kill`, `pkill`, or call proxy services.
- `restart` calls `stop`, then `start`; if start fails, preserve and report the stop success in the error message.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter AppLifecycleServiceTests
```

Expected: PASS, including the no-proxy-side-effect assertion.

- [ ] **Step 5: Commit app lifecycle in isolation**

```bash
git add Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/Runtime/AppLifecycleService.swift Tests/CLIProxyManagerCoreTests/AppLifecycleServiceTests.swift
git commit -m "feat: add cpm app lifecycle controls" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 5: Aggregate status, runtime command grammar, and JSON output

**Files:**
- Create: `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify tests: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
- Create test: `Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift`

**Interfaces:**
- Produces: `public struct CPMStatus: Codable, Equatable, Sendable` with nested `app`, `helper`, `proxy` values exactly matching the approved JSON field names.
- Produces: `public protocol StatusReporting: Sendable { func status() async throws -> CPMStatus }` in `RuntimeCommandServices.swift`.
- Produces: `public struct StatusService: StatusReporting`.
- Consumes: Task 2 `ProxyRuntimeServicing`, Task 4 `AppLifecycleControlling`, `AppBundleLocating`, `FileManager`.

- [ ] **Step 1: Write failing status serialization tests**

Create `StatusServiceTests`:

```swift
func testJSONStatusContainsOnlyStableOperationalFields() async throws {
    let status = try await StatusService(
        appLifecycle: AppLifecycleDouble(running: false),
        proxyRuntime: ProxyRuntimeDouble(port: 8317, running: true, activeVersion: "7.2.41"),
        helperInspector: HelperInspectorDouble(installed: true, matchesBundled: true)
    ).status()

    let data = try JSONEncoder().encode(status)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual((object["app"] as? [String: Any])?["running"] as? Bool, false)
    XCTAssertEqual((object["proxy"] as? [String: Any])?["port"] as? Int, 8317)
    XCTAssertNil((object["proxy"] as? [String: Any])?["authProfiles"])
    XCTAssertNil((object["app"] as? [String: Any])?["apiKey"])
}
```

Add command tests:

```swift
func testStartDispatchesOnlyToProxyRuntime() async throws {
    let services = RuntimeServicesDouble()
    let command = makeCommand(services: services)

    try await command.run(arguments: ["start"])

    XCTAssertEqual(services.calls, [.proxyStart])
}

func testAppStartDispatchesOnlyToAppLifecycle() async throws {
    let services = RuntimeServicesDouble()
    let command = makeCommand(services: services)

    try await command.run(arguments: ["app", "start"])

    XCTAssertEqual(services.calls, [.appStart])
}

func testStatusJSONWritesValidJSONToStdout() async throws {
    let output = OutputDouble(isInteractive: false)
    let command = makeCommand(output: output, services: RuntimeServicesDouble())

    try await command.run(arguments: ["status", "--json"])

    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.stdout.joined().utf8)))
    XCTAssertTrue(output.stderr.isEmpty)
}
```

- [ ] **Step 2: Run the new command and status tests**

```bash
swift test --filter StatusServiceTests
swift test --filter CLIProxyManagerCommandTests
```

Expected: compile failure until `CPMStatus`, `StatusService`, and runtime parsing exist.

- [ ] **Step 3: Implement stable status values and the helper inspector**

Add this protocol to `RuntimeCommandServices.swift` before declaring `StatusService`:

```swift
public protocol StatusReporting: Sendable {
    func status() async throws -> CPMStatus
}
```

Define `CPMStatus` with these Codable coding keys and nullable fields:

```swift
public struct CPMStatus: Codable, Equatable, Sendable {
    public let app: App
    public let helper: Helper
    public let proxy: Proxy

    public struct App: Codable, Equatable, Sendable {
        public let installed: Bool
        public let path: String?
        public let version: String?
        public let build: String?
        public let running: Bool
        public let stagedVersion: String?
    }
    public struct Helper: Codable, Equatable, Sendable {
        public let path: String
        public let installed: Bool
        public let matchesBundled: Bool
    }
    public struct Proxy: Codable, Equatable, Sendable {
        public let port: Int
        public let running: Bool
        public let activeVersion: String?
        public let pendingVersion: String?
        public let stagedVersion: String?
        public let logsPath: String
    }
}
```

For this plan, `stagedVersion` is always `nil`; the update plans populate it without changing the JSON shape. `HelperInspector` reports `/usr/local/bin/cpm` as not installed until the app/helper plan packages it. Once a bundled `cpm` helper exists, it compares SHA-256 and file size only when both are regular files. It never compares or prints file contents.

- [ ] **Step 4: Reject root before every mutating runtime command**

Add `public struct CurrentUserChecking: Sendable` or an equivalent injected `@Sendable () -> uid_t` dependency to `CLIProxyManagerCommand`; its default must return `geteuid()`. Before dispatching `start`, `stop`, `restart`, `app start`, `app stop`, or `app restart`, require a nonzero effective uid. On uid `0`, throw exactly:

```swift
.prerequisite("cpm must run as the macOS user that owns ~/.cliproxy-manager; do not use sudo.")
```

Do not apply this check to `status`, `logs`, `secret get`, or `routing next`. Add one command test that a root-injected dispatcher rejects `start` without invoking its `ProxyRuntimeServicing` double, and another that permits `status` under the same injected uid.

- [ ] **Step 5: Add exact grammar branches to the dispatcher**

After the legacy branches, parse only these valid runtime forms:

```text
status [--json]
start
stop
restart
logs
logs -f
logs --lines <positive-int>
logs --lines <positive-int> -f
logs -f --lines <positive-int>
app status|start|stop|restart
```

Reject duplicates, `--json` outside `status`, `--lines 0`, negative/non-numeric lines, and extra arguments with `.usage`. The default log count is `200`.

For text output, use these deterministic lines:

```text
Proxy started on port <port>.
Proxy stopped.
Proxy restarted on port <port>.
App started.
App stopped.
App restarted.
```

`logs` writes only the selected log text to stdout; `logs -f` delegates to the follower and does not append a success banner. `status --json` encodes with `.sortedKeys` and appends exactly one newline. Text `status` prints one `App:`, one `Helper:`, and one `Proxy:` summary line without paths to auth files or secret values.

- [ ] **Step 6: Run command and service tests**

```bash
swift test --filter StatusServiceTests
swift test --filter CLIProxyManagerCommandTests
swift test
```

Expected: PASS. The full suite validates that existing secret/routing commands remain intact while the new lifecycle grammar compiles and dispatches correctly.

- [ ] **Step 7: Commit the working SSH runtime CLI**

```bash
git add Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/Runtime/StatusService.swift Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "feat: add cpm runtime commands" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 6: Development-build command verification and runtime documentation

**Files:**
- Modify: `README.md`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift` only if its stopped-proxy message instructs users to open the GUI.
- Modify test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

**Interfaces:**
- Consumes: completed `cpm` runtime command grammar.
- Produces: README command examples that are executable from an SSH session and state that GUI is optional.

- [ ] **Step 1: Add a failing renderer regression test for headless recovery wording**

If the current generated function contains text directing the user to open the app, add:

```swift
func testStoppedProxyMessagePointsToCpmStartInsteadOfRequiringGUI() throws {
    let script = try ShellFunctionRenderer(config: .default, helperCommand: "/usr/local/bin/cpm").render()
    XCTAssertTrue(script.contains("cpm start"))
    XCTAssertFalse(script.contains("Open CLIProxyManager"))
}
```

Skip this step only if no generated message tells the user to open the GUI; do not alter unrelated shell function copy.

- [ ] **Step 2: Implement the smallest copy change and run the renderer test**

Replace only the recovery sentence with one that says `Start it with cpm start, then retry.` Keep the existing function name and exit behavior. Run:

```bash
swift test --filter ShellFunctionRendererTests
```

Expected: PASS.

- [ ] **Step 3: Document the completed runtime commands**

Add a `## SSH and headless management` section to `README.md` after Quick start with these exact examples:

```zsh
cpm status
cpm start
cpm logs -f
cpm restart
cpm stop

cpm app status
cpm app start
cpm app stop
```

State explicitly that `cpm start` controls only the local CLIProxyAPI proxy, does not open the GUI, and requires SSH access as the same non-root macOS account that owns `~/.cliproxy-manager`.

- [ ] **Step 4: Verify on the development build**

Run the project’s development build and CLI target:

```bash
swift build --product cpm
swift test
.build/debug/cpm status
.build/debug/cpm start
.build/debug/cpm logs --lines 20
.build/debug/cpm restart
.build/debug/cpm stop
```

Expected: lifecycle commands operate only on the DEBUG managed path (`~/.cliproxy-manager/dev`), and `status` never prints secret or OAuth data. If no bundled app resource is available from `.build/debug`, verify `stop`, `status`, and `logs` behavior and record that `start` requires the development app bundle resource; do not silently fall back to release paths.

- [ ] **Step 5: Commit runtime documentation**

```bash
git add README.md Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift
git commit -m "docs: document headless cpm runtime controls" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```
