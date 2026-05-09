# Proxy Server Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add practical CLIProxyAPI server lifecycle management so the app can start, stop, restart, and reflect server state without leaving users stuck with a running process.

**Architecture:** Extend the Core proxy layer from launch-only startup into a small runtime controller that owns the process it starts. Keep health detection separate: `ProxyHealthClient` still answers whether something responds on the port, while `ProxyServiceManager` owns start/stop/restart for the app-managed process. The SwiftUI dashboard calls the runtime controller through an injected protocol, so tests can verify lifecycle behavior without spawning real processes.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, XCTest, Foundation `Process`, existing `CLIProxyManagerCore` models and test doubles.

---

## Scope

This plan implements server lifecycle only:

- Start bundled CLIProxyAPI from the app.
- Stop the CLIProxyAPI process started by this app.
- Restart by stopping then starting with the current port.
- Show Start/Stop/Restart controls in the dashboard.
- Keep `cc`, `ccapi`, `ccodex`, Keychain editing, OAuth account connection, and settings forms out of scope for this plan.

## File Structure

- Modify `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
  - Add app-managed process lifetime state.
  - Replace launch-only protocol with process handle abstraction that supports terminate.
  - Add `stop()` and `restart(port:)`.
- Modify `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
  - Add tests for stop, restart, no-op stop, and launch failure cleanup behavior.
- Modify `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Extend `ProxyServiceStarting` into a lifecycle protocol.
  - Add `stopServer()` and `restartServer()`.
  - Track an `isServerActionInProgress` flag for button disabling.
- Modify `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - Add tests for stop/restart success and failure status updates.
- Modify `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - Add Start, Stop, Restart buttons to `StatusPanel`.
  - Disable buttons while lifecycle action is in progress.
- No new docs are required beyond this plan.

---

### Task 1: Add process handle abstraction to Core proxy service

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

- [ ] **Step 1: Write failing tests for start retaining a process handle and stop terminating it**

Append this test before `testStartReportsWriteFailure` in `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`:

```swift
    func testStopTerminatesAppManagedProcess() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = FakeManagedProcess()
        let launcher = FakeProcessLauncher(process: process)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.stop()

        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEqual(process.waitCallCount, 1)
    }
```

Update `FakeProcessLauncher` at the bottom of the same file to return a process handle:

```swift
private final class FakeManagedProcess: ManagedProxyProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminateCallCount = 0
    private var _waitCallCount = 0

    var terminateCallCount: Int {
        lock.withLock { _terminateCallCount }
    }

    var waitCallCount: Int {
        lock.withLock { _waitCallCount }
    }

    func terminate() {
        lock.withLock { _terminateCallCount += 1 }
    }

    func waitUntilExit() {
        lock.withLock { _waitCallCount += 1 }
    }
}
```

Replace the existing `FakeProcessLauncher` with:

```swift
private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let error: Error?
    private let process: any ManagedProxyProcess
    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(error: Error? = nil, process: any ManagedProxyProcess = FakeManagedProcess()) {
        self.error = error
        self.process = process
    }

    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        if let error {
            throw error
        }
        return process
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails to compile**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProxyServiceManagerTests/testStopTerminatesAppManagedProcess
```

Expected: FAIL to compile because `ManagedProxyProcess` does not exist, `ProcessLaunching.launch` still returns `Void`, and `ProxyServiceManager.stop()` does not exist.

- [ ] **Step 3: Implement the process handle abstraction and `stop()`**

Replace the top of `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift` with this structure, preserving the existing `ProxyServiceError`, `ProxyServiceManager`, `config(for:)`, and `isValidPort(_:)` content where shown:

```swift
import Foundation

public protocol ManagedProxyProcess: Sendable {
    func terminate()
    func waitUntilExit()
}

extension Process: ManagedProxyProcess {}

public protocol ProcessLaunching: Sendable {
    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess
}

public struct ProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
```

In `ProxyServiceManager`, add state and update `start`/`stop`:

```swift
public struct ProxyServiceManager: @unchecked Sendable {
    private let paths: ManagedPaths
    private let bundledBinaryURL: URL?
    private let launcher: any ProcessLaunching
    private let fileManager: FileManager
    private let lock = NSLock()
    private var process: (any ManagedProxyProcess)?

    public init(
        paths: ManagedPaths,
        bundledBinaryURL: URL? = nil,
        launcher: any ProcessLaunching = ProcessLauncher(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.bundledBinaryURL = bundledBinaryURL
        self.launcher = launcher
        self.fileManager = fileManager
    }

    public func start(port: Int) async throws {
        guard isValidPort(port) else {
            throw ProxyServiceError.invalidPort(port)
        }

        do {
            try installBundledBinaryIfNeeded()
            try config(for: port).write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        } catch let error as ProxyServiceError {
            throw error
        } catch {
            throw ProxyServiceError.writeFailed(error.localizedDescription)
        }

        do {
            let launchedProcess = try launcher.launch(paths.clipProxyBinary.path, ["--config", paths.clipProxyConfigFile.path])
            lock.withLock { process = launchedProcess }
        } catch {
            throw ProxyServiceError.launchFailed(error.localizedDescription)
        }
    }

    public func stop() async throws {
        let runningProcess = lock.withLock { () -> (any ManagedProxyProcess)? in
            let currentProcess = process
            process = nil
            return currentProcess
        }

        runningProcess?.terminate()
        runningProcess?.waitUntilExit()
    }
```

Keep the existing `installBundledBinaryIfNeeded()` and `config(for:)` methods unchanged below this block.

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProxyServiceManagerTests/testStopTerminatesAppManagedProcess
```

Expected: PASS.

- [ ] **Step 5: Run all proxy service tests**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProxyServiceManagerTests
```

Expected: PASS. Existing tests may require only the `FakeProcessLauncher` signature update shown above.

- [ ] **Step 6: Commit**

```bash
git add \
  /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  /Users/woosublee/Documents/dev/CLIProxyManager/Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: add proxy server stop support"
```

---

### Task 2: Add restart and no-op stop semantics

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

- [ ] **Step 1: Write failing tests for no-op stop and restart**

Add these tests after `testStopTerminatesAppManagedProcess`:

```swift
    func testStopWithoutRunningProcessIsNoOp() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.stop()

        XCTAssertEqual(launcher.invocations, [])
    }

    func testRestartStopsExistingProcessBeforeStartingAgain() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let firstProcess = FakeManagedProcess()
        let secondProcess = FakeManagedProcess()
        let launcher = FakeProcessLauncher(processes: [firstProcess, secondProcess])
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.restart(port: 9000)

        XCTAssertEqual(firstProcess.terminateCallCount, 1)
        XCTAssertEqual(firstProcess.waitCallCount, 1)
        XCTAssertEqual(launcher.invocations.map(\.arguments), [
            ["--config", paths.clipProxyConfigFile.path],
            ["--config", paths.clipProxyConfigFile.path]
        ])

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("port: 9000"))
    }
```

Update `FakeProcessLauncher` initializer to support multiple processes:

```swift
private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let error: Error?
    private let lock = NSLock()
    private var processes: [any ManagedProxyProcess]
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(error: Error? = nil, process: any ManagedProxyProcess = FakeManagedProcess()) {
        self.error = error
        self.processes = [process]
    }

    init(error: Error? = nil, processes: [any ManagedProxyProcess]) {
        self.error = error
        self.processes = processes
    }

    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        if let error {
            throw error
        }
        return lock.withLock { processes.removeFirst() }
    }
}
```

- [ ] **Step 2: Run focused tests and verify restart fails to compile**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProxyServiceManagerTests/testRestartStopsExistingProcessBeforeStartingAgain
```

Expected: FAIL to compile because `restart(port:)` does not exist.

- [ ] **Step 3: Implement `restart(port:)`**

Add this method below `stop()` in `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`:

```swift
    public func restart(port: Int) async throws {
        try await stop()
        try await start(port: port)
    }
```

- [ ] **Step 4: Run proxy service tests**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ProxyServiceManagerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add \
  /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  /Users/woosublee/Documents/dev/CLIProxyManager/Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "feat: add proxy server restart support"
```

---

### Task 3: Expose lifecycle actions through DashboardViewModel

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing tests for stop/restart view model actions**

In `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`, add these tests after `testStartServerFailureUpdatesServerAndCodexCardStatus`:

```swift
    func testStopServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.stopServer()

        XCTAssertEqual(proxyService.stopCallCount, 1)
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .error)
    }

    func testRestartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.restartServer()

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
    }
```

Replace the `ProxyServiceStarting` test double with this expanded version:

```swift
private final class StubProxyServiceStarter: ProxyServiceControlling, @unchecked Sendable {
    private let error: Error?
    private let lock = NSLock()
    private var _ports: [Int] = []
    private var _restartPorts: [Int] = []
    private var _stopCallCount = 0

    var ports: [Int] {
        lock.withLock { _ports }
    }

    var restartPorts: [Int] {
        lock.withLock { _restartPorts }
    }

    var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func start(port: Int) async throws {
        lock.withLock { _ports.append(port) }
        if let error {
            throw error
        }
    }

    func stop() async throws {
        lock.withLock { _stopCallCount += 1 }
        if let error {
            throw error
        }
    }

    func restart(port: Int) async throws {
        lock.withLock { _restartPorts.append(port) }
        if let error {
            throw error
        }
    }
}
```

- [ ] **Step 2: Run focused tests and verify they fail to compile**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter DashboardViewModelRefreshTests/testStopServerUsesInjectedProxyServiceAndRefreshesStatus
```

Expected: FAIL to compile because `ProxyServiceControlling`, `stopServer()`, and `restartServer()` do not exist.

- [ ] **Step 3: Extend the app lifecycle protocol and view model actions**

In `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`, replace:

```swift
protocol ProxyServiceStarting: Sendable {
    func start(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceStarting {}
```

with:

```swift
protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceControlling {}
```

Update the stored property and initializer:

```swift
    @Published var isServerActionInProgress = false

    private let config: AppConfig
    private let proxyHealthClient: ProxyHealthClient
    private let proxyService: any ProxyServiceControlling
    private let claudeConnector: ClaudeConnector

    init(
        config: AppConfig = .default,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        claudeConnector: ClaudeConnector = ClaudeConnector()
    ) {
```

Replace `startServer()` with:

```swift
    func startServer() async {
        await performServerAction(title: "CLIProxyAPI 시작 실패") {
            try await proxyService.start(port: config.port)
        }
    }

    func stopServer() async {
        await performServerAction(title: "CLIProxyAPI 종료 실패") {
            try await proxyService.stop()
        }
    }

    func restartServer() async {
        await performServerAction(title: "CLIProxyAPI 재시작 실패") {
            try await proxyService.restart(port: config.port)
        }
    }

    private func performServerAction(title: String, action: () async throws -> Void) async {
        isServerActionInProgress = true
        defer { isServerActionInProgress = false }

        do {
            try await action()
            await refresh()
        } catch {
            updateStatuses(
                serverStatus: DiagnosticStatus(
                    severity: .error,
                    title: title,
                    message: error.localizedDescription
                ),
                claudeStatus: nil
            )
        }
    }
```

Keep `refresh()` and `updateStatuses(...)` as they are.

- [ ] **Step 4: Run app view model tests**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter DashboardViewModelRefreshTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add \
  /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  /Users/woosublee/Documents/dev/CLIProxyManager/Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: expose proxy lifecycle actions"
```

---

### Task 4: Add Stop and Restart controls to DashboardView

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Test: build and app launch check only; SwiftUI view snapshot tests are out of scope for this package.

- [ ] **Step 1: Update `StatusPanel` call site**

In `Sources/CLIProxyManagerApp/Views/DashboardView.swift`, replace the current `StatusPanel` call:

```swift
                StatusPanel(title: "CLIProxyAPI Server", status: viewModel.serverStatus) {
                    Task {
                        await viewModel.startServer()
                    }
                }
```

with:

```swift
                StatusPanel(
                    title: "CLIProxyAPI Server",
                    status: viewModel.serverStatus,
                    isActionInProgress: viewModel.isServerActionInProgress,
                    startAction: {
                        Task { await viewModel.startServer() }
                    },
                    stopAction: {
                        Task { await viewModel.stopServer() }
                    },
                    restartAction: {
                        Task { await viewModel.restartServer() }
                    }
                )
```

- [ ] **Step 2: Update `StatusPanel` properties**

In the same file, replace:

```swift
private struct StatusPanel: View {
    let title: String
    let status: DiagnosticStatus
    let startAction: () -> Void
```

with:

```swift
private struct StatusPanel: View {
    let title: String
    let status: DiagnosticStatus
    let isActionInProgress: Bool
    let startAction: () -> Void
    let stopAction: () -> Void
    let restartAction: () -> Void
```

- [ ] **Step 3: Replace the single Start button with three lifecycle buttons**

Replace:

```swift
                Button("Start Server", action: startAction)
```

with:

```swift
                HStack(spacing: 8) {
                    Button("Start", action: startAction)
                    Button("Stop", action: stopAction)
                    Button("Restart", action: restartAction)
                }
                .disabled(isActionInProgress)
```

- [ ] **Step 4: Build the app**

Run:

```bash
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
```

Expected: PASS.

- [ ] **Step 5: Run app view model tests and full tests**

Run:

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter DashboardViewModelRefreshTests
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager"
```

Expected: PASS.

- [ ] **Step 6: Launch the built app briefly**

Run:

```bash
APP="/Users/woosublee/Documents/dev/CLIProxyManager/.build/arm64-apple-macosx/debug/CLIProxyManager"
"$APP" >/tmp/cliproxy-manager-app.log 2>&1 & pid=$!
python3 - <<'PY' "$pid"
import os, signal, sys, time
pid = int(sys.argv[1])
time.sleep(2)
try:
    os.kill(pid, 0)
except ProcessLookupError:
    sys.exit(0)
os.kill(pid, signal.SIGTERM)
time.sleep(1)
try:
    os.kill(pid, 0)
except ProcessLookupError:
    sys.exit(0)
os.kill(pid, signal.SIGKILL)
PY
rc=$?
wait "$pid" 2>/dev/null || true
exit "$rc"
```

Expected: command exits 0.

- [ ] **Step 7: Commit**

```bash
git add /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerApp/Views/DashboardView.swift
git commit -m "feat: add server lifecycle controls"
```

---

### Task 5: Final verification and review

**Files:**
- No source changes expected.

- [ ] **Step 1: Run full tests**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager"
```

Expected: all tests pass.

- [ ] **Step 2: Build both products**

```bash
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product CLIProxyManager
swift build --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --product cliproxy-manager
```

Expected: both builds pass.

- [ ] **Step 3: Verify generated shell functions are still safe**

```bash
swift test --package-path "/Users/woosublee/Documents/dev/CLIProxyManager" --filter ShellFunctionRendererTests
```

Expected: PASS, confirming lifecycle UI work did not regress shell rendering.

- [ ] **Step 4: Verify git status is clean**

```bash
git -C "/Users/woosublee/Documents/dev/CLIProxyManager" status --short
```

Expected: no output.

- [ ] **Step 5: Request final code review**

Ask a reviewer to inspect:

- `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`

Review focus:

- `stop()` terminates only the app-managed process and is a safe no-op when nothing is running.
- `restart(port:)` stops before starting and writes the new config.
- Dashboard buttons call the correct lifecycle actions.
- UI disables lifecycle buttons while an action is in progress.
- Existing health checks and shell rendering are not regressed.

Expected: no Blocker or Important findings.

---

## Self-Review

- Spec coverage: The plan covers the immediate next usability gap identified in the running app: server stop/restart and lifecycle controls. Account connect/disconnect and settings editing are intentionally excluded so this implementation stays small and shippable.
- Placeholder scan: No unfinished markers or cross-referenced shortcut steps remain. Each code-changing step includes exact code or exact replacement snippets.
- Type consistency: The plan consistently uses `ManagedProxyProcess`, `ProcessLaunching.launch(...) -> any ManagedProxyProcess`, `ProxyServiceControlling`, `stopServer()`, and `restartServer()` across Core, App, and tests.
