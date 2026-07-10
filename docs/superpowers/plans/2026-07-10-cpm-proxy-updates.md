# CPM Proxy Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cpm update check|stage|apply proxy`로 GUI 없이 CLIProxyAPI 바이너리를 release 조회, checksum·metadata 검증, staged pending 저장, 안전한 적용과 기존 실행 상태 보존까지 수행한다.

**Architecture:** 기존 `CLIProxyAPIReleaseClient`, `CLIProxyAPIArchiveVerifier`, `CLIProxyAPIBinaryStore`를 UI state와 24시간 자동-check policy에서 분리한 Core `ProxyUpdateService`로 조합한다. CLI와 GUI는 같은 pending/active manifest를 사용하며 GUI adapter는 새 service를 호출해 download/verify/apply 로직이 이중화되지 않게 한다.

**Tech Stack:** Swift 5.10, Foundation `URLSession`, existing `HTTPClient`, CryptoKit SHA-256, existing archive verifier/binary store, XCTest, GitHub Releases API.

## Global Constraints

- 지원 플랫폼은 macOS 15 이상이며 upstream은 `router-for-me/CLIProxyAPI`다.
- stable latest release와 macOS arm64 asset `CLIProxyAPI_<version>_darwin_aarch64.tar.gz`만 지원한다.
- `checksums.txt` SHA-256과 archive에서 추출한 binary의 `--version` metadata 검증을 모두 통과해야 stage할 수 있다.
- `cpm update check proxy`는 파일과 process를 변경하지 않는다.
- `cpm update stage proxy`는 verified pending binary만 저장하며 실행 중 proxy를 중단하거나 교체하지 않는다.
- `cpm update apply proxy`는 pending binary만 적용한다. TTY confirmation이 필요하고 `--yes`는 confirmation만 생략한다.
- apply 전 proxy가 실행 중이었다면 apply 후 restart하고 readiness를 확인한다. 이전에 중지 상태였다면 시작하지 않는다.
- 실패하면 active binary를 보존하거나 `CLIProxyAPIBinaryStore`의 원자적 복구를 사용한다.
- GUI의 Sparkle 앱 업데이트 흐름과 24시간 proxy 자동-check UX는 유지한다.
- update command output, manifest, error에는 API key나 OAuth profile contents를 기록하지 않는다.

---

## File Structure

- Create: `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift`
  - check/stage/apply 결과와 CLI/GUI 공용 orchestration을 제공한다.
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift`
  - update service에 필요한 client protocol conformances와 test injection surface를 정리한다.
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`
  - staged service가 cleanup을 보장할 수 있는 verification result contract를 확인·보완한다.
- Modify: `Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift`
  - update apply 전후 실행 상태 판별과 restart/readiness 경계를 제공한다.
- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift`
  - `ProxyUpdating` protocol을 추가한다.
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
  - `cpm update check|stage|apply proxy`와 later `app|all` targets의 grammar를 추가한다.
- Modify: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
  - UI-specific state는 유지하고 Core `ProxyUpdateService`를 adapter로 사용한다.
- Create tests: `Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift`, `Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift`
- Modify tests: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`, `Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift`, `Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift`

---

### Task 1: Core proxy update result model and release comparison

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift`

**Interfaces:**
- Produces: `public enum ProxyUpdateCheckResult: Equatable, Sendable { case upToDate(current: String?); case available(current: String?, release: CLIProxyAPIRelease); case pending(current: String?, pending: CLIProxyAPIBinaryManifest) }`.
- Produces: `public struct ProxyUpdateStageResult: Equatable, Sendable { let version: String; let staged: Bool }`.
- Produces: `public struct ProxyUpdateApplyResult: Equatable, Sendable { let version: String; let restartedProxy: Bool; let proxyReady: Bool }`.
- Produces: `public protocol ProxyUpdateChecking: Sendable { func latestRelease() async throws -> CLIProxyAPIRelease }`.
- Consumes: existing `CLIProxyAPIBinaryStore`, `CLIProxyAPIReleaseClient`, manifest/version types.

- [ ] **Step 1: Write the release comparison tests before implementation**

Create `ProxyUpdateServiceTests.swift` with a fake checker and sandboxed `CLIProxyAPIBinaryStore`:

```swift
func testCheckReportsAvailableWhenReleaseIsNewerThanActiveBinary() async throws {
    let paths = try makePaths(activeVersion: "7.2.41")
    let service = makeService(
        paths: paths,
        checker: ReleaseCheckerDouble(release: release(version: "7.2.50"))
    )

    let result = try await service.check()

    XCTAssertEqual(result, .available(current: "7.2.41", release: release(version: "7.2.50")))
}

func testCheckReportsUpToDateWhenReleaseEqualsCurrentBinary() async throws {
    let paths = try makePaths(activeVersion: "7.2.50")
    let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: release(version: "7.2.50")))

    XCTAssertEqual(try await service.check(), .upToDate(current: "7.2.50"))
}

func testCheckReportsPendingBeforeAvailableRelease() async throws {
    let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
    let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: release(version: "7.2.50")))

    XCTAssertEqual(try await service.check(), .pending(current: "7.2.41", pending: try XCTUnwrap(CLIProxyAPIBinaryStore(paths: paths).pendingManifest())))
}
```

Use test helper manifests whose binary checksum and size match a small executable fixture; do not bypass binary validation.

- [ ] **Step 2: Run the tests and verify the API is missing**

```bash
swift test --filter ProxyUpdateServiceTests/testCheck
```

Expected: compile failure because `ProxyUpdateService` and result types do not exist.

- [ ] **Step 3: Implement check-only service behavior**

At the top of `ProxyUpdateService.swift`, add:

```swift
public protocol ProxyUpdateChecking: Sendable {
    func latestRelease() async throws -> CLIProxyAPIRelease
}

extension CLIProxyAPIReleaseClient: ProxyUpdateChecking {}
```

Implement `check()` in `ProxyUpdateService` with this order:

1. Read validated active version using `store.validatedCurrentVersion(bundledManifestURL:)`.
2. Read pending manifest. If a valid pending manifest exists and its version is greater than current (or current is absent), return `.pending` without downloading an archive.
3. Fetch latest upstream release.
4. Return `.upToDate` if current is non-nil and latest is less than or equal to current; otherwise return `.available`.

If stored pending metadata is invalid, rely on the existing binary store validation path to reject it and leave the existing active binary untouched; do not report it as a valid update.

- [ ] **Step 4: Run tests and existing release-client coverage**

```bash
swift test --filter ProxyUpdateServiceTests/testCheck
swift test --filter CLIProxyAPIReleaseClientTests
```

Expected: PASS.

- [ ] **Step 5: Commit release comparison**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift
git commit -m "feat: check proxy binary updates from cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 2: Verified staging from the existing archive verifier

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift`

**Interfaces:**
- Produces: `public protocol ProxyUpdateDownloading: Sendable { func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult; func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) }`.
- Produces: `public func stage() async throws -> ProxyUpdateStageResult`.
- Consumes: Task 1 check result; existing `CLIProxyAPIBinaryStore.savePending(binaryURL:manifest:)`.

- [ ] **Step 1: Write staging tests covering both positive and negative paths**

Add these tests to `ProxyUpdateServiceTests`:

```swift
func testStageDownloadsVerifiesAndStoresPendingBinary() async throws {
    let paths = try makePaths(activeVersion: "7.2.41")
    let downloaded = try makeVerificationResult(version: "7.2.50")
    let downloader = DownloaderDouble(result: downloaded)
    let service = makeService(
        paths: paths,
        checker: ReleaseCheckerDouble(release: release(version: "7.2.50")),
        downloader: downloader
    )

    let result = try await service.stage()

    XCTAssertEqual(result, ProxyUpdateStageResult(version: "7.2.50", staged: true))
    XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest()?.version, "7.2.50")
    XCTAssertEqual(downloader.cleanedResults, [downloaded])
}

func testStageDoesNotDownloadWhenCurrentBinaryIsAlreadyNewer() async throws {
    let paths = try makePaths(activeVersion: "7.2.60")
    let downloader = DownloaderDouble(result: nil)
    let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: release(version: "7.2.50")), downloader: downloader)

    let result = try await service.stage()

    XCTAssertEqual(result, ProxyUpdateStageResult(version: "7.2.60", staged: false))
    XCTAssertTrue(downloader.requests.isEmpty)
}

func testStageLeavesExistingPendingAndActiveFilesUntouchedWhenVerificationFails() async throws {
    let paths = try makePaths(activeVersion: "7.2.41")
    let service = makeService(
        paths: paths,
        checker: ReleaseCheckerDouble(release: release(version: "7.2.50")),
        downloader: DownloaderDouble(error: VerificationError.invalidArchive)
    )

    await XCTAssertThrowsErrorAsync(try await service.stage())
    XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
    XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).activeManifest()?.version, "7.2.41")
}
```

- [ ] **Step 2: Run staging tests and confirm failure**

```bash
swift test --filter ProxyUpdateServiceTests/testStage
```

Expected: compile failure because `stage()` and `ProxyUpdateDownloading` are missing.

- [ ] **Step 3: Extract the downloader adapter from the App target into Core**

Move the `CLIProxyAPIUpdateDownloading` protocol and `CLIProxyAPIUpdateDownloader` implementation out of `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift` into `ProxyUpdateService.swift`, renaming them to `ProxyUpdateDownloading` and `ProxyUpdateDownloader`. Preserve exact archive verifier behavior:

```swift
public struct ProxyUpdateDownloader: ProxyUpdateDownloading {
    public let client: CLIProxyAPIReleaseClient
    public let verifier: CLIProxyAPIArchiveVerifier

    public func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        let archive = try await client.downloadArchive(for: release)
        return try await verifier.verify(archiveData: archive, release: release)
    }

    public func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) {
        verifier.cleanup(result)
    }
}
```

- [ ] **Step 4: Implement `stage()` with unconditional cleanup**

`stage()` must call `check()`. For `.upToDate`, return the current version with `staged: false`. For `.pending`, return the pending version with `staged: false` and do not overwrite it. For `.available`, call downloader, use `defer { downloader.cleanup(result) }`, then call `store.savePending(binaryURL: result.binaryURL, manifest: result.manifest)`. Return `staged: true` only after the store succeeds.

- [ ] **Step 5: Run stage and archive-verifier tests**

```bash
swift test --filter ProxyUpdateServiceTests/testStage
swift test --filter CLIProxyAPIArchiveVerifierTests
```

Expected: PASS; existing checksum mismatch, malformed archive, missing binary, and metadata mismatch tests remain green.

- [ ] **Step 6: Commit verified staging**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift
git commit -m "feat: stage verified proxy updates" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 3: Apply staged proxy binary while preserving runtime state

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift`
- Modify: `Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/ProxyRuntimeServiceTests.swift`

**Interfaces:**
- Produces: `public protocol ProxyRuntimeUpdating: Sendable { func status() async throws -> ProxyRuntimeStatus; func restart() async throws -> ProxyRuntimeStatus }`.
- Produces: `public func apply() async throws -> ProxyUpdateApplyResult`.
- Consumes: Task 2 staged pending binary and Task 1 `ProxyUpdateApplyResult`.

- [ ] **Step 1: Write running and stopped apply tests**

```swift
func testApplyRestartsAndChecksReadyWhenProxyWasRunning() async throws {
    let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
    let runtime = ProxyRuntimeUpdateDouble(statuses: [
        ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.41", pendingVersion: "7.2.50"),
        ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.50", pendingVersion: nil)
    ])
    let service = makeService(paths: paths, runtime: runtime)

    let result = try await service.apply()

    XCTAssertEqual(runtime.restartCount, 1)
    XCTAssertEqual(result, ProxyUpdateApplyResult(version: "7.2.50", restartedProxy: true, proxyReady: true))
}

func testApplyDoesNotStartProxyWhenItWasStopped() async throws {
    let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
    let runtime = ProxyRuntimeUpdateDouble(statuses: [
        ProxyRuntimeStatus(port: 8317, running: false, health: .stopped, activeVersion: "7.2.41", pendingVersion: "7.2.50")
    ])
    let service = makeService(paths: paths, runtime: runtime)

    let result = try await service.apply()

    XCTAssertEqual(runtime.restartCount, 0)
    XCTAssertEqual(result, ProxyUpdateApplyResult(version: "7.2.50", restartedProxy: false, proxyReady: false))
}

func testApplyFailsWithoutPendingBinary() async throws {
    let service = makeService(paths: try makePaths(activeVersion: "7.2.41"))
    await XCTAssertThrowsErrorAsync(try await service.apply()) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("No staged CLIProxyAPI update is available. Run cpm update stage proxy first."))
    }
}
```

- [ ] **Step 2: Run apply tests and verify they fail**

```bash
swift test --filter ProxyUpdateServiceTests/testApply
```

Expected: compile failure because `apply()` and runtime update protocol do not exist.

- [ ] **Step 3: Implement ordered apply semantics**

In `ProxyUpdateService.apply()`:

1. Require a pending manifest and retain its version for output.
2. Call `runtime.status()` before changing the binary.
3. Call `store.applyPending()`. Preserve the binary store’s existing move/backup rollback behavior; do not reimplement it.
4. If pre-apply runtime `running == false`, return `restartedProxy: false, proxyReady: false`.
5. If it was running, call `runtime.restart()`. If restart returns `running == false` or non-ready health, throw `.operation("CLIProxyAPI <version> was applied, but the proxy did not become ready after restart.")`.
6. Return `restartedProxy: true, proxyReady: true` only after the readiness result.

The active binary remains updated if the restart fails; the error must say that the operator should inspect `cpm logs` and choose a later explicit restart. Do not silently roll back a successfully verified binary solely because the proxy fails to start.

- [ ] **Step 4: Run apply and binary-store regression tests**

```bash
swift test --filter ProxyUpdateServiceTests/testApply
swift test --filter CLIProxyAPIBinaryStoreTests
swift test --filter ProxyRuntimeServiceTests
```

Expected: PASS.

- [ ] **Step 5: Commit safe proxy apply**

```bash
git add Sources/CLIProxyManagerCore/Proxy/ProxyUpdateService.swift Sources/CLIProxyManagerCore/Runtime/ProxyRuntimeService.swift Tests/CLIProxyManagerCoreTests/ProxyUpdateServiceTests.swift Tests/CLIProxyManagerCoreTests/ProxyRuntimeServiceTests.swift
git commit -m "feat: apply staged proxy updates from cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 4: Add proxy update grammar and adapt the GUI service

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift`
- Modify test: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`

**Interfaces:**
- Produces: `public protocol ProxyUpdating: Sendable { func check() async throws -> ProxyUpdateCheckResult; func stage() async throws -> ProxyUpdateStageResult; func apply() async throws -> ProxyUpdateApplyResult }`.
- Consumes later: app-update plan adds `AppUpdating`; `cpm update <verb> all` is not enabled until both services exist.

- [ ] **Step 1: Write command grammar and confirmation tests**

Create `CLIProxyManagerUpdateCommandTests.swift`:

```swift
func testCheckProxyDispatchesWithoutConfirmation() async throws {
    let services = UpdateServicesDouble(interactive: true)
    let command = makeCommand(services: services)

    try await command.run(arguments: ["update", "check", "proxy"])

    XCTAssertEqual(services.calls, [.proxyCheck])
    XCTAssertEqual(services.confirmationPrompts, [])
}

func testApplyProxyRequiresInteractiveConfirmation() async throws {
    let services = UpdateServicesDouble(interactive: true, confirms: false)
    let command = makeCommand(services: services)

    try await command.run(arguments: ["update", "apply", "proxy"])

    XCTAssertEqual(services.calls, [])
    XCTAssertEqual(services.confirmationPrompts, ["Apply staged CLIProxyAPI update? "])
}

func testApplyProxyYesSkipsConfirmation() async throws {
    let services = UpdateServicesDouble(interactive: false)
    let command = makeCommand(services: services)

    try await command.run(arguments: ["update", "apply", "proxy", "--yes"])

    XCTAssertEqual(services.calls, [.proxyApply])
    XCTAssertTrue(services.confirmationPrompts.isEmpty)
}

func testUpdateWithoutTargetDefaultsToAllOnlyAfterAppUpdaterExists() async {
    let command = makeCommand(services: UpdateServicesDouble())
    await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["update", "check"])) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
    }
}
```

At this phase, require explicit `proxy`; the app-update plan changes the last test after adding app/all targets.

- [ ] **Step 2: Run the command tests and verify they fail**

```bash
swift test --filter CLIProxyManagerUpdateCommandTests
```

Expected: compile failure because `ProxyUpdating` and update grammar do not exist.

- [ ] **Step 3: Implement explicit proxy update grammar and copy**

Add `ProxyUpdating` to `RuntimeCommandServices.swift` and make `ProxyUpdateService` conform. In `CLIProxyManagerCommand`, accept only:

```text
update check proxy
update stage proxy
update apply proxy [--yes]
```

Use text output:

```text
CLIProxyAPI is up to date at <version>.
CLIProxyAPI update available: <current> → <available>.
CLIProxyAPI <version> is staged.
CLIProxyAPI <version> is already staged.
Applied CLIProxyAPI <version> and restarted the proxy.
Applied CLIProxyAPI <version>; the proxy remains stopped.
```

For interactive apply, refuse non-TTY calls without `--yes` using `.usage` with `Use --yes to apply updates in a non-interactive session.` This prevents a CI/SSH pipe from waiting for input.

- [ ] **Step 4: Rewire the GUI adapter without changing UI state semantics**

Change `CLIProxyAPIUpdateService` to own `private let updateService: any ProxyUpdating` and use it for release check, stage, and apply. It may retain its existing `CLIProxyAPIUpdateState`, `@Published` properties, 24-hour suppression, `lastDeferredVersion`, and UI-specific messages. Remove duplicated archive download/store calls from the App service.

Update App tests so they verify the UI adapter calls fake `ProxyUpdating` methods and still sets `state`, `availableUpdate`, `pendingUpdate`, and `currentVersionText` exactly as before.

- [ ] **Step 5: Run Core command, App adapter, and full tests**

```bash
swift test --filter CLIProxyManagerUpdateCommandTests
swift test --filter CLIProxyAPIUpdateServiceTests
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit the completed proxy update surface**

```bash
git add Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift
git commit -m "feat: manage proxy updates with cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 5: Verify headless proxy update behavior on the development build

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed `cpm update check|stage|apply proxy` commands.

- [ ] **Step 1: Document the three proxy update phases**

Add these commands to the SSH section of `README.md`:

```zsh
cpm update check proxy
cpm update stage proxy
cpm update apply proxy
# For automation only after reviewing the staged version:
cpm update apply proxy --yes
```

Explain that stage validates upstream `checksums.txt` and extracted CLIProxyAPI version before changing the active executable, and apply preserves whether the proxy was running.

- [ ] **Step 2: Run non-network unit verification**

```bash
swift test --filter ProxyUpdateServiceTests
swift test --filter CLIProxyManagerUpdateCommandTests
swift test
```

Expected: PASS without live GitHub access because every HTTP/archive path is injected in unit tests.

- [ ] **Step 3: Perform one intentional manual check in the development build**

```bash
swift build --product cpm
.build/debug/cpm update check proxy
```

Expected: output reports either up-to-date or an available version; it must not create `pending/`, replace `cliproxyapi`, or restart the proxy. Do not run `stage` or `apply` against a personal environment unless the user explicitly requests the real update.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "docs: explain cpm proxy update workflow" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```
