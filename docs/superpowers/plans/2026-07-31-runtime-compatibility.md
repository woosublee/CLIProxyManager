# Runtime Compatibility Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 지원되지 않는 host 또는 CLIProxyAPI artifact가 proxy 실행·업데이트·shell function 변경을 시작하기 전에 차단되고, 동일한 compatibility contract가 App·CLI·README에 표시되게 한다.

**Architecture:** `CLIProxyManagerCore`에 구조화된 compatibility policy와 read-only preflight를 둔다. UI는 report를 표시할 뿐 권한을 결정하지 않고, `ProxyServiceManager`, `CLIProxyAPIBinaryStore`, update service, `AutomaticShellInstallService`가 실제 process/file mutation 직전에 policy를 재확인한다.

**Tech Stack:** Swift 5.10, SwiftPM, Foundation/AppKit/SwiftUI, XCTest, Bash script tests, GitHub Actions macos-14.

## Global Constraints

- 지원 host는 macOS 15.0 이상과 native `arm64`뿐이며 Intel/x86_64, universal binary, Rosetta 지원을 추가하지 않는다.
- generated shell functions는 `zsh`만 지원하고 bash/fish 통합은 추가하지 않는다.
- Claude Code last-verified 기준은 `2.1.220`, verified on 2026-07-31이다. version mismatch는 warning이며 실행을 차단하지 않는다.
- CLIProxyAPI target은 정규화된 `darwin` / `arm64`로 저장한다. `darwin_aarch64`는 release asset filename 표기일 뿐 policy 입력이 아니다.
- Compatibility preflight는 read-only다. config, shell profile, secret, binary, process, auth state를 변경하지 않는다.
- start/restart/OAuth/model preparation과 binary mutation은 fail-closed다. `stop`, status, logs, rollback/recovery는 compatibility blocker가 있어도 허용한다.
- raw command stdout/stderr, account, email, secret, prompt, absolute home path를 UI, CLI text/JSON, log, fixture에 포함하지 않는다.
- public fixture identifier는 `example.com`을 사용한다.
- 기존 CI contract (`Build`, `Test`, `Script tests`, `Package structure`)와 `macos-14`, `contents: read` 정책을 변경하지 않는다.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibility.swift` | policy constants, action/finding/decision/report model, host/artifact snapshot, Core protocols and sanitized blockers |
| `Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibilityPreflight.swift` | side-effect-free live host/Claude/manifest inspection and report construction |
| `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift` | explicit artifact target schema with backwards-compatible decoding |
| `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift` | target validation before any pending/active/bundled binary mutation |
| `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift` | process/config mutation authorization before staging or stopping proxy |
| `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift` | update stage/apply authorization before downloader and store mutation |
| `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift` | GUI update authorization before direct update mutation |
| `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift` | async zsh/Claude preflight immediately before shell write |
| `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` | published compatibility report, display refresh, start/update/shell error projection, safe automatic shell reconciliation |
| `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`, `CPMStatus` model | cpm status compatibility summary in text and JSON |
| `README.md`, `README.en.md` | parity-tested support matrix and recovery semantics |

## Task 1: Define Compatibility Domain and Manifest Target Schema

**Files:**
- Create: `Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibility.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift`
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
- Test: `Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryManifestTests.swift`

**Interfaces:**
- Produces `CLIProxyAPIArtifactTarget(operatingSystem:architecture:)`, `CompatibilityAction`, `CompatibilityDisposition`, `CompatibilityFinding`, `RuntimeCompatibilityReport`, and `RuntimeCompatibilityPolicy`.
- Produces `CLIProxyAPIBinaryManifest.target: CLIProxyAPIArtifactTarget?` with source-compatible decoding.

- [ ] **Step 1: Write failing policy and manifest tests**

```swift
func testProxyStartBlocksUnsupportedArchitecture() {
    let report = RuntimeCompatibilityPolicy.current.report(
        environment: .init(operatingSystem: .macOS(major: 15, minor: 0), architecture: .x86_64, loginShell: "/bin/zsh"),
        artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
        claude: .notChecked
    )

    XCTAssertEqual(report.decision(for: .startProxy).disposition, .blocked)
    XCTAssertTrue(report.findings.contains(.unsupportedArchitecture(expected: .arm64, actual: .x86_64)))
}

func testManifestWithoutTargetRemainsDecodable() throws {
    let manifest = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: legacyManifestData())
    XCTAssertNil(manifest.target)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'RuntimeCompatibilityTests|CLIProxyAPIBinaryManifestTests'`

Expected: compile failure because compatibility policy types and `target` do not exist.

- [ ] **Step 3: Implement immutable domain types and schema**

```swift
public struct CLIProxyAPIArtifactTarget: Codable, Equatable, Sendable {
    public enum OperatingSystem: String, Codable, Sendable { case darwin }
    public enum Architecture: String, Codable, Sendable { case arm64 }
    public let operatingSystem: OperatingSystem
    public let architecture: Architecture
    public static let darwinArm64 = Self(operatingSystem: .darwin, architecture: .arm64)
}

public enum CompatibilityAction: String, Codable, Sendable {
    case inspect, stopProxy, startProxy, restartProxy, prepareOAuthLogin
    case prepareModelServer, stageProxyUpdate, applyProxyUpdate
    case scheduleProxyUpdate, installShellFunctions, recoverProxyArtifact
}

public enum CompatibilityDisposition: String, Codable, Sendable {
    case allowed, allowedWithWarnings, blocked
}
```

Implement `RuntimeCompatibilityPolicy.current` with `minimumMacOSMajor = 15`, supported arm64 target, `/bin/zsh` basename comparison, and `lastVerifiedClaudeCodeVersion = "2.1.220"`. Add optional `target` to the manifest initializer, coding keys, decoding, and bundled JSON. Do not infer legacy target in the decoder; inference belongs to policy.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'RuntimeCompatibilityTests|CLIProxyAPIBinaryManifestTests'`

Expected: PASS, including explicit target round-trip and missing-target decode.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibility.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift \
  Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json \
  Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryManifestTests.swift
git commit -m "feat: define runtime compatibility policy"
```

## Task 2: Implement Read-Only Host, Artifact, and Claude Preflight

**Files:**
- Create: `Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibilityPreflight.swift`
- Modify: `Sources/CLIProxyManagerCore/Claude/ClaudeConnector.swift`
- Test: `Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityPreflightTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift`

**Interfaces:**
- Consumes Task 1 policy, manifests, and artifact target.
- Produces `RuntimeCompatibilityChecking.staticReport(artifacts:)` and `RuntimeCompatibilityChecking.report(artifacts:) async`.
- `staticReport` reports only synchronous host/artifact hard blockers; `report` adds sanitized Claude availability/version findings.

- [ ] **Step 1: Write failing read-only and Claude observation tests**

```swift
func testPreflightReadsClaudeVersionWithoutCheckingAuth() async {
    let runner = FakeProcessRunner(results: [
        .success(stdout: "/opt/homebrew/bin/claude\n"),
        .success(stdout: "2.1.221 (Claude Code)\n")
    ])
    let report = await RuntimeCompatibilityPreflight(
        environment: FixedEnvironment.arm64Zsh,
        claudeInspector: ClaudeCodeInspector(runner: runner)
    ).report(artifacts: .matching)

    XCTAssertEqual(runner.invocations, [
        ("/usr/bin/env", ["which", "claude"]),
        ("/usr/bin/env", ["claude", "--version"])
    ])
    XCTAssertEqual(report.decision(for: .startProxy).disposition, .allowedWithWarnings)
}

func testPreflightDoesNotMutateArtifactOrShellState() async {
    let spy = MutationSpy()
    _ = await makePreflight(spy: spy).report(artifacts: .matching)
    XCTAssertEqual(spy.mutations, [])
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'RuntimeCompatibilityPreflightTests|ClaudeConnectorTests'`

Expected: compile failure because preflight and version-only observation APIs do not exist.

- [ ] **Step 3: Implement observers and sanitized report construction**

```swift
public protocol RuntimeCompatibilityChecking: Sendable {
    func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport
    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport
}

public protocol RuntimeEnvironmentProviding: Sendable {
    func snapshot() -> RuntimeEnvironmentSnapshot
}

public protocol ClaudeCodeInspecting: Sendable {
    func observeVersion() async -> ClaudeCodeObservation
}
```

Use `ProcessRunning` only in `ClaudeCodeInspector`; invoke exactly `which claude` and `claude --version`, parse a bounded semantic version token, and convert command failure or unparseable output to sanitized `.unavailable`/`.unverified` findings. Keep `ClaudeConnector.status()` responsible for auth status and do not expose raw stdout/stderr through the new API. Make the live environment provider injectable for OS, native architecture, translation state, and login shell tests.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'RuntimeCompatibilityPreflightTests|ClaudeConnectorTests'`

Expected: PASS; auth command is absent from preflight invocations and spies observe no mutation.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibilityPreflight.swift \
  Sources/CLIProxyManagerCore/Claude/ClaudeConnector.swift \
  Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityPreflightTests.swift \
  Tests/CLIProxyManagerCoreTests/ClaudeConnectorTests.swift
git commit -m "feat: add read-only compatibility preflight"
```

## Task 3: Propagate Artifact Targets Through Release and Vendor Producers

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`
- Modify: `scripts/vendor-cliproxyapi.sh`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift`
- Test: `Tests/ScriptTests/vendor-cliproxyapi-tests.sh`

**Interfaces:**
- Consumes `CLIProxyAPIArtifactTarget.darwinArm64` from Task 1.
- Produces `CLIProxyAPIRelease.target` and manifests with explicit `target` from both bundled and user-updated paths.

- [ ] **Step 1: Write failing producer propagation tests**

```swift
func testReleaseCarriesDarwinArm64Target() async throws {
    let release = try await makeReleaseClient().latestRelease()
    XCTAssertEqual(release.target, .darwinArm64)
}

func testArchiveVerifierPreservesReleaseTargetInManifest() async throws {
    let manifest = try await verifyFixtureArchive(target: .darwinArm64)
    XCTAssertEqual(manifest.target, .darwinArm64)
}
```

Add a shell assertion that a vendored manifest contains exactly `target.operatingSystem == "darwin"` and `target.architecture == "arm64"`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'CLIProxyAPIReleaseClientTests|CLIProxyAPIArchiveVerifierTests' && bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh`

Expected: FAIL because producer models and generated JSON do not carry target metadata.

- [ ] **Step 3: Implement target propagation**

```swift
public struct CLIProxyAPIRelease: Equatable, Sendable {
    public let target: CLIProxyAPIArtifactTarget
    // retain existing version, asset, URL, checksum fields
}
```

Make the release client choose its fixed asset name from `.darwinArm64`, pass the target into archive verification, and make the vendor script generate the nested target object. Retain exact existing checksum/version behavior and fixture asset names.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'CLIProxyAPIReleaseClientTests|CLIProxyAPIArchiveVerifierTests' && bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh`

Expected: PASS, with explicit target in bundled and update manifests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift \
  scripts/vendor-cliproxyapi.sh \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift \
  Tests/ScriptTests/vendor-cliproxyapi-tests.sh
git commit -m "feat: preserve CLIProxyAPI artifact targets"
```

## Task 4: Enforce Artifact Target Safety in Binary Storage

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift` (the existing `CLIProxyAPIBinaryStoreError` declaration at the file top)
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`

**Interfaces:**
- Consumes Task 1 policy and manifest target; uses a synchronous, injected `RuntimeCompatibilityAuthorizing`/artifact validator.
- Produces target validation for `savePending`, `schedulePendingForNextStart`, `applyPending`, `prepareActiveBinary`, bundled reconciliation, and scheduled promotion.

- [ ] **Step 1: Write failing no-mutation tests**

```swift
func testApplyPendingRejectsMismatchedTargetWithoutChangingActiveBinary() throws {
    let store = makeStore(host: .arm64)
    try installActive(version: "1.0.0", target: .darwinArm64, into: store)
    try savePending(version: "1.1.0", target: unsupportedTarget, into: store, validate: false)
    let activeBefore = try activeBinaryData()

    XCTAssertThrowsError(try store.applyPending())
    XCTAssertEqual(try activeBinaryData(), activeBefore)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingBinaryURL.path))
}
```

Add equivalent tests for save, schedule, bundled reconcile, and active preparation; assert backup/marker files are absent when authorization fails.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter CLIProxyAPIBinaryStoreTests`

Expected: FAIL because target mismatch currently passes checksum/size validation and mutates files.

- [ ] **Step 3: Implement legacy inference and mutation guards**

Add a single private `requireCompatibleTarget(manifest:action:)` call before validation, backup creation, marker creation, or file move in every listed path. Infer target only when `upstreamAsset == "CLIProxyAPI_\(manifest.version)_darwin_aarch64.tar.gz"`; classify it as warning-compatible on arm64. Target-less manifests outside that exact format are blocked. Rewrite to explicit target only after checksum validation inside an already-authorized store transaction; never backfill during inspection.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter CLIProxyAPIBinaryStoreTests`

Expected: PASS, including explicit matching target, legacy inferred target, and unknown/mismatched target no-mutation cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift
git commit -m "feat: validate artifact targets before binary mutation"
```

## Task 5: Protect Proxy Runtime and Update Actions

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
- Modify: `Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift` as required for typed error propagation
- Test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`

**Interfaces:**
- Consumes Tasks 1–4 `RuntimeCompatibilityAuthorizer` and target-safe store.
- Produces typed Core compatibility blocks translated to existing CLI prerequisite errors and UI recovery messages.

- [ ] **Step 1: Write failing runtime/update boundary tests**

```swift
func testBlockedRestartLeavesRunningProxyUntouched() async throws {
    let runtime = makeProxyService(host: .x86_64, runningPort: 8317)

    await XCTAssertThrowsErrorAsync(try await runtime.restart(port: 8317)) { error in
        XCTAssertEqual(error as? ProxyServiceError, .compatibilityBlocked(.unsupportedArchitecture))
    }
    XCTAssertEqual(await runtime.launcher.events, [])
    XCTAssertEqual(await runtime.terminatedPorts, [])
}

func testBlockedUpdateStageDoesNotInvokeDownloader() async throws {
    let downloader = DownloaderDouble()
    let service = makeUpdateService(host: .x86_64, downloader: downloader)
    await XCTAssertThrowsErrorAsync(try await service.stageLatest())
    XCTAssertEqual(await downloader.requests, [])
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'ProxyServiceManagerTests|ProxyUpdateServiceTests|CLIProxyAPIUpdateServiceTests'`

Expected: FAIL because staging/stop/download can happen without compatibility authorization.

- [ ] **Step 3: Add runtime and update authorization**

Inject the synchronous authorizer into `ProxyServiceManager`. Require `.prepareOAuthLogin` at the beginning of `prepareLocked` and `.startProxy`/`.restartProxy` at the beginning of `reconcileConfigurationLocked`, before `stageConfiguration` and `stopManagedProcessesLocked`. Do not authorize `stopLocked` or `restore`.

Inject the full preflight authorizer into both update services. Require `.stageProxyUpdate`, `.applyProxyUpdate`, or `.scheduleProxyUpdate` before download/store calls. Preserve remote update check as inspect-only. Convert policy blocks to a typed `ProxyServiceError.compatibilityBlocked` and existing `CLIProxyManagerCommandError.prerequisite` text without raw process output.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'ProxyServiceManagerTests|ProxyUpdateServiceTests|CLIProxyAPIUpdateServiceTests'`

Expected: PASS; blocked restart does not terminate the existing proxy and blocked stage does not call downloader.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift \
  Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift \
  Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift
git commit -m "feat: block incompatible proxy runtime actions"
```

## Task 6: Guard Shell Function Writes Without Rolling Back Config

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Test: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes Task 2 async compatibility checker.
- Produces `AutomaticShellInstallService.apply(...) async throws` and an automatic reconciliation result that distinguishes written, skipped-for-compatibility, and disabled.

- [ ] **Step 1: Write failing explicit/automatic shell tests**

```swift
func testNonZshExplicitInstallDoesNotWriteShellFiles() async throws {
    let installer = RecordingShellInstaller()
    let service = makeShellInstallService(
        report: .blocked(.unsupportedShell(actual: "/bin/bash")),
        installer: installer
    )

    await XCTAssertThrowsErrorAsync(try await service.apply(config: .default))
    XCTAssertEqual(installer.installations, [])
}

func testAutomaticCompatibilitySkipPreservesSavedConfigAndExistingScript() async throws {
    let fixture = makeDashboard(shellReport: .blocked(.claudeCodeUnavailable))
    let scriptBefore = try fixture.readManagedScript()

    try fixture.saveChangedConfig()

    XCTAssertEqual(try fixture.readManagedScript(), scriptBefore)
    XCTAssertEqual(fixture.config, fixture.changedConfig)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'AutomaticShellInstallServiceTests|DashboardViewModelTests'`

Expected: compile failure because apply is synchronous and automatic reconciliation cannot represent a compatibility skip.

- [ ] **Step 3: Implement async write boundary and safe reconciliation**

Change only `AutomaticShellInstallService.apply` and its callers to async. Run full preflight immediately before rendering/installing. Explicit install propagates a sanitized blocker. Automatic reconciliation returns `.skippedForCompatibility` rather than throwing into the config transaction. Defer initial automatic reconciliation until compatibility inspection completes; preserve existing generated script for all blocker cases. Keep `ShellFunctionRenderer` pure and do not inject compatibility conditions into generated functions.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'AutomaticShellInstallServiceTests|DashboardViewModelTests'`

Expected: PASS; no installer calls on blocker, config persists, and existing shell content is unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: guard shell functions with compatibility preflight"
```

## Task 7: Publish Compatibility Status in App, CLI, and Documentation

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CPMStatus.swift` or its existing model declaration file
- Modify: `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify: `README.md`
- Modify: `README.en.md`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/UpdaterConfigurationTests.swift`
- Test: `Tests/ScriptTests/support-matrix-tests.sh`

**Interfaces:**
- Consumes Task 2 full `RuntimeCompatibilityReport` and Task 6 automatic shell reconciliation result.
- Produces `DashboardViewModel.compatibilityReport`, sanitized `CPMStatus.compatibility`, and bilingual support-matrix parity checks.

- [ ] **Step 1: Write failing App/CLI/doc tests**

```swift
func testCompatibilityBlockerDoesNotReplaceReadyServerStatus() async {
    let model = makeDashboard(compatibility: .blocked(.unsupportedArchitecture))
    await model.refresh()

    XCTAssertEqual(model.serverStatus.severity, .ready)
    XCTAssertEqual(model.compatibilityReport.decision(for: .startProxy).disposition, .blocked)
}

func testStatusJSONContainsSanitizedCompatibilitySummary() async throws {
    let output = try await runCPM(arguments: ["status", "--json"], compatibility: .warningClaudeVersion("2.1.221"))
    XCTAssertTrue(output.contains("compatibility"))
    XCTAssertFalse(output.contains("/Users/"))
}
```

Add script assertions that both READMEs contain the same macOS 15, arm64, zsh, `2.1.220`, date, warning, and recovery matrix rows.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'DashboardViewModelTests|CLIProxyManagerCommandTests|UpdaterConfigurationTests' && bash Tests/ScriptTests/support-matrix-tests.sh`

Expected: FAIL because no shared report, CPM status field, support matrix, or parity script exists.

- [ ] **Step 3: Implement projections and documentation**

On Dashboard refresh, fetch compatibility report independently from server health and retain it as published state. Render concise blocker/warning content in Dashboard and action-specific explanation in General Settings; disable start/update/shell write affordances only as UX, while leaving Stop enabled.

Add a Codable compatibility summary to `CPMStatus`, source it from `StatusService`, and render concise text/JSON in `CLIProxyManagerCommand`. Include only finding code, disposition, and sanitized recovery text.

Add aligned Korean/English support matrix sections. Create the executable top-level script test so the existing tracked script runner automatically includes it.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'DashboardViewModelTests|CLIProxyManagerCommandTests|UpdaterConfigurationTests' && bash Tests/ScriptTests/support-matrix-tests.sh`

Expected: PASS; health remains independent, status JSON is redacted, and README rows match policy constants.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Sources/CLIProxyManagerCore/CLI Sources/CLIProxyManagerCore/Runtime/StatusService.swift \
  README.md README.en.md Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift \
  Tests/CLIProxyManagerCoreTests/UpdaterConfigurationTests.swift \
  Tests/ScriptTests/support-matrix-tests.sh
git commit -m "feat: report runtime compatibility"
```

## Task 8: Run Full Verification and One Medium Review Pass

**Files:**
- Modify only if review finds a verified defect in scope.
- Test: all changed unit and script suites.

- [ ] **Step 1: Run focused regression suites**

Run:

```bash
swift test --filter 'RuntimeCompatibilityTests|RuntimeCompatibilityPreflightTests|CLIProxyAPIBinaryManifestTests|CLIProxyAPIBinaryStoreTests|ProxyServiceManagerTests|ProxyUpdateServiceTests|AutomaticShellInstallServiceTests|CLIProxyManagerCommandTests'
bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh
bash Tests/ScriptTests/support-matrix-tests.sh
```

Expected: PASS.

- [ ] **Step 2: Run full automated verification**

Run:

```bash
swift test
bash scripts/run-script-tests.sh
make ci-build
make verify-bundle-structure
git diff --check
```

Expected: all Swift tests pass, all tracked scripts pass, CI-equivalent build and unsigned bundle structure pass, and no whitespace errors exist.

- [ ] **Step 3: Run one medium whole-change review**

Invoke: `/code-review medium`

Expected: inspect the complete branch diff once. Fix only confirmed Critical or Important findings, add/adjust a targeted regression test for every fix, then rerun the smallest proving suite plus the full verification command set from Step 2. Do not enter an unbounded review loop.

- [ ] **Step 4: Commit final verified changes**

```bash
git status --short
git add Sources/CLIProxyManagerCore Sources/CLIProxyManagerApp \
  Tests/CLIProxyManagerCoreTests Tests/CLIProxyManagerAppTests Tests/ScriptTests \
  scripts README.md README.en.md
git commit -m "fix: address compatibility review findings"
```

Run this commit only when the review produced confirmed fixes. Otherwise leave the prior task commits unchanged.
