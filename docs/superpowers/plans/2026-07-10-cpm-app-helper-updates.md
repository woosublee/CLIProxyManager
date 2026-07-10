# CPM App and Helper Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cpm update check|stage|apply app|all`로 GUI 없이 Sparkle appcast release를 검증하고 CLIProxyManager app bundle, 공식 `cpm` helper, legacy `cliproxy-manager` helper를 함께 안전하게 갱신한다.

**Architecture:** Sparkle의 GUI `SPUStandardUpdaterController`는 변경하지 않고 headless Core service가 고정된 GitHub appcast와 committed Ed25519 public key를 검증한다. 다운로드된 DMG는 signature·length·mounted app bundle identity/version·code signature·두 helper를 검증한 뒤 사용자 managed staging 영역에 저장한다. Apply는 `/Applications`와 `/usr/local/bin` 내부 temporary location에서 각 대상의 rename transaction을 수행하고, 중간 실패면 prior app과 두 helper를 자동 복구한다.

**Tech Stack:** Swift 5.10, macOS 15+, Foundation `XMLParser`/`URLSession`, CryptoKit `Curve25519.Signing`, existing `HTTPClient`/`ProcessRunner`, `hdiutil`, `codesign`, `ditto`, Swift Package Manager, XCTest, shell ScriptTests.

## Global Constraints

- 지원 플랫폼은 macOS 15 이상이다.
- appcast feed는 정확히 `https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml`이며 사용자가 다른 feed URL을 지정할 수 없다.
- appcast enclosure와 redirect 최종 URL은 HTTPS여야 한다.
- app update는 `Info.plist`의 committed `SUPublicEDKey`에 해당하는 Ed25519 signature 및 enclosure length를 검증해야 한다.
- stage는 app/helper/proxy active files를 바꾸지 않는다. apply만 변경한다.
- app apply 대상은 `/Applications/CLIProxyManager.app`, `/usr/local/bin/cpm`, `/usr/local/bin/cliproxy-manager`이며 세 대상은 모두 preflight를 통과해야 변경을 시작한다.
- `sudo cpm` 또는 GUI administrator prompt는 지원하지 않는다. 권한 부족은 exit code `3`으로 실패하며 staged artifact는 보존한다.
- app update는 GUI app을 정상 종료하려 시도하되 proxy lifecycle을 임의로 변경하지 않는다.
- app update는 active CLIProxyAPI binary를 번들 버전으로 낮추지 않는다.
- successful update의 user-initiated rollback command는 제공하지 않는다. `.previous`는 transaction 실패 시 자동 복구에만 사용하고 성공 시 제거한다.
- `cpm update apply`는 TTY confirmation을 요구하며 `--yes`가 confirmation만 생략한다.
- 기존 Sparkle GUI update UI와 기존 `cliproxy-manager secret|routing next` 호환성은 유지한다.

---

## File Structure

- Modify: `Package.swift`
  - 별도 `CPMCLI` target의 `cpm` product와 legacy `CLIProxyManagerCLI`/`cliproxy-manager` product가 같은 Core dispatcher를 호출하는지 확정한다.
- Modify: `Makefile`
  - 두 helper를 bundle, code-sign, verify, install transaction에 포함한다.
- Modify: `scripts/verify-dmg.sh`
  - mounted DMG 내부 두 helper를 검사한다.
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`
  - Makefile/release string regression assertions을 확장한다.
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
  - 실제 bundle/external `cpm` helper가 함께 설치된 뒤 새 generated shell function의 default helper를 `cpm`으로 전환한다.
- Modify: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
  - official helper 탐색 기대값을 `cpm`으로 갱신한다.
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift`
  - appcast item, staged manifest, check/stage/apply value types를 정의한다.
- Create: `Sources/CLIProxyManagerCore/Updates/AppcastClient.swift`
  - fixed URL download, XML parsing, HTTPS validation, increasing build selection을 제공한다.
- Create: `Sources/CLIProxyManagerCore/Updates/SparkleSignatureVerifier.swift`
  - base64 Ed25519 signature/public key 검증과 enclosure byte-length 검증을 제공한다.
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateStager.swift`
  - verified DMG mount, bundle/helper verification, managed staging tree와 manifest 작성을 담당한다.
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateApplier.swift`
  - preflight, GUI normal quit, temporary copy/rename transaction, automatic restore를 담당한다.
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateService.swift`
  - check/stage/apply을 위 units로 조합하고 CLI-facing result를 반환한다.
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - app update stage root와 manifest/app/helper paths를 제공한다.
- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift`
  - `AppUpdating` protocol을 정의한다.
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
  - app/proxy/all default update grammar와 confirmation output을 완성한다.
- Modify: `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`
  - staged app version을 상태에 반영한다.
- Modify: `README.md`
  - initial cpm bootstrap, stage/apply workflow, permission model, GUI optional behavior를 설명한다.
- Create tests: `Tests/CLIProxyManagerCoreTests/AppcastClientTests.swift`, `Tests/CLIProxyManagerCoreTests/SparkleSignatureVerifierTests.swift`, `Tests/CLIProxyManagerCoreTests/AppUpdateStagerTests.swift`, `Tests/CLIProxyManagerCoreTests/AppUpdateApplierTests.swift`, `Tests/CLIProxyManagerCoreTests/AppUpdateServiceTests.swift`
- Modify tests: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift`, `Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift`
- Modify scripts/tests: `Tests/ScriptTests/release-local-tests.sh`, `Tests/ScriptTests/generate-sparkle-appcast-tests.sh`
- Modify: `.github/workflows/release.yml`
  - existing script test command을 CI Test phase에 넣는다.

---

### Task 1: Ship the two-helper package contract before app self-update

**Files:**
- Modify: `Package.swift`
- Modify: `Makefile`
- Modify: `scripts/verify-dmg.sh`
- Modify: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift`
- Modify: `Tests/ScriptTests/release-local-tests.sh`

**Interfaces:**
- Produces: bundle helpers at `CLIProxyManager.app/Contents/Helpers/cpm` and `CLIProxyManager.app/Contents/Helpers/cliproxy-manager`.
- Produces: external helpers at `/usr/local/bin/cpm` and `/usr/local/bin/cliproxy-manager`.
- Produces: `make install` transaction that restores both helper paths and app bundle if a post-staging rename fails.
- Consumes: completed `cpm` executable product from the runtime plan.

- [ ] **Step 1: Add failing packaging contract assertions**

In `ReleaseWorkflowTests.swift`, extend the Makefile test to require these literal checks:

```swift
XCTAssertTrue(makefile.contains("CPM_EXECUTABLE = $(SWIFT_BUILD_DIR)/cpm"))
XCTAssertTrue(makefile.contains("BUNDLED_CPM := $(HELPERS_DIR)/cpm"))
XCTAssertTrue(makefile.contains("Contents/Helpers/cpm"))
XCTAssertTrue(makefile.contains("Contents/Helpers/cliproxy-manager"))
XCTAssertTrue(makefile.contains("/usr/local/bin/cpm"))
XCTAssertTrue(makefile.contains("/usr/local/bin/cliproxy-manager"))
```

In `release-local-tests.sh`, extend the fake installed bundle inspection to require both `Contents/Helpers/cpm` and `Contents/Helpers/cliproxy-manager` are executable after `make install`.

- [ ] **Step 2: Run packaging assertions to confirm failure**

```bash
swift test --filter ReleaseWorkflowTests
bash Tests/ScriptTests/release-local-tests.sh
```

Expected: FAIL because the bundle and install target currently contain only `cliproxy-manager`.

- [ ] **Step 3: Build and bundle both dispatcher names**

In `Makefile`, define:

```make
CPM_EXECUTABLE = $(SWIFT_BUILD_DIR)/cpm
LEGACY_HELPER_EXECUTABLE = $(SWIFT_BUILD_DIR)/cliproxy-manager
BUNDLED_CPM := $(HELPERS_DIR)/cpm
BUNDLED_LEGACY_HELPER := $(HELPERS_DIR)/cliproxy-manager
```

Change `swift-build` to build both executable products, and make `bundle` require and copy both outputs. Update code-sign, `verify`, `verify-dmg`, and `install-helper` checks to validate both helpers. The compatibility executable must invoke the same `CLIProxyManagerCommand` dispatcher rather than a shell symlink, so it remains signed as a first-class Mach-O binary.

- [ ] **Step 4: Replace the install target with an all-or-nothing three-target transaction**

In `make install`, use these locations:

```make
INSTALL_PATH="/Applications/$(APP_NAME).app"
CPM_PATH="/usr/local/bin/cpm"
LEGACY_HELPER_PATH="/usr/local/bin/cliproxy-manager"
APP_STAGING="/Applications/.$(APP_NAME).app.staging"
APP_PREVIOUS="/Applications/.$(APP_NAME).app.previous"
CPM_STAGING="/usr/local/bin/.cpm.staging"
CPM_PREVIOUS="/usr/local/bin/.cpm.previous"
LEGACY_STAGING="/usr/local/bin/.cliproxy-manager.staging"
LEGACY_PREVIOUS="/usr/local/bin/.cliproxy-manager.previous"
```

Stage all three before renaming any target. On error, remove new targets, restore each existing `.previous` artifact to its canonical path, then remove staging. Preserve the existing `trap rollback ERR` style and include both helper restore operations in it. Do not invoke `sudo`.

- [ ] **Step 5: Switch newly generated shell functions to `cpm` now that it is packaged**

In `AutomaticShellInstallService`, change the default fallback from `/usr/local/bin/cliproxy-manager` to `/usr/local/bin/cpm`; replace bundle helper discovery suffix with `Helpers/cpm`; update DEBUG sibling discovery to look for `cpm`. Update every expected default string in `AutomaticShellInstallServiceTests` accordingly. Preserve explicit `helperCommand:` overrides in `ShellFunctionRendererTests`; those remain compatibility and escaping tests for arbitrary helper paths.

- [ ] **Step 6: Verify exact packaging behavior**

```bash
swift test --filter ReleaseWorkflowTests
swift test --filter AutomaticShellInstallServiceTests
bash Tests/ScriptTests/release-local-tests.sh
make CONFIGURATION=debug CODESIGN_IDENTITY=- verify
```

Expected: PASS. `verify` reports both helper paths present and executable inside the app bundle, and fresh shell function rendering resolves to `cpm`.

- [ ] **Step 7: Commit the bootstrap package contract**

```bash
git add Package.swift Makefile scripts/verify-dmg.sh Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift Tests/ScriptTests/release-local-tests.sh
git commit -m "feat: ship cpm alongside legacy helper" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 2: Fixed appcast parsing and Sparkle-compatible Ed25519 verification

**Files:**
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift`
- Create: `Sources/CLIProxyManagerCore/Updates/AppcastClient.swift`
- Create: `Sources/CLIProxyManagerCore/Updates/SparkleSignatureVerifier.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppcastClientTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/SparkleSignatureVerifierTests.swift`

**Interfaces:**
- Produces: `public struct AppUpdateRelease: Equatable, Sendable { let version: String; let build: Int; let enclosureURL: URL; let expectedLength: Int; let edSignature: String }`.
- Produces: `public protocol AppcastFetching: Sendable { func fetchLatest(afterBuild: Int) async throws -> AppUpdateRelease? }`.
- Produces: `public protocol AppUpdateArtifactDownloading: Sendable { func download(_ url: URL) async throws -> Data }`.
- Produces: `public struct SparkleSignatureVerifier` with `verify(artifact:expectedLength:base64Signature:base64PublicKey:) throws`.

- [ ] **Step 1: Write parser tests using an in-memory signed-appcast-shaped XML fixture**

Create `AppcastClientTests.swift` and inject a `HTTPClient` double that returns data. Include these cases:

```swift
func testFetchLatestSelectsOnlyAReleaseWithHigherBuild() async throws {
    let client = AppcastClient(
        httpClient: HTTPClientDouble(data: appcastXML(items: [
            item(build: 15, url: "https://github.com/example/old.dmg"),
            item(build: 16, url: "https://github.com/example/new.dmg")
        ]))
    )

    let update = try await client.fetchLatest(afterBuild: 15)

    XCTAssertEqual(update?.build, 16)
    XCTAssertEqual(update?.version, "0.1.13")
}

func testFetchLatestRejectsNonHTTPSFeedRedirectOrEnclosure() async {
    let client = AppcastClient(httpClient: HTTPClientDouble(data: item(build: 16, url: "http://example.invalid/update.dmg").data(using: .utf8)!))

    await XCTAssertThrowsErrorAsync(try await client.fetchLatest(afterBuild: 15)) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .operation("App update enclosure must use HTTPS."))
    }
}

func testFetchLatestRejectsMissingSignatureOrLength() async {
    let client = AppcastClient(httpClient: HTTPClientDouble(data: malformedItemWithoutSignature().data(using: .utf8)!))
    await XCTAssertThrowsErrorAsync(try await client.fetchLatest(afterBuild: 15))
}
```

Also add a test that `AppcastClient.feedURL.absoluteString` is exactly the committed GitHub URL; never derive it from a user preference.

- [ ] **Step 2: Run parser tests and verify they fail**

```bash
swift test --filter AppcastClientTests
```

Expected: compile failure because app update models and client are absent.

- [ ] **Step 3: Implement narrow XML parsing and URL policy**

Use `Foundation.XMLParser` with a private delegate that collects only the first `<item>` containing an `<enclosure>` with all of:

```text
url
length
sparkle:version
sparkle:shortVersionString
sparkle:edSignature
```

Convert `sparkle:version` to `Int`; reject values less than or equal to `afterBuild`. Require `feedURL.scheme == "https"` before calling HTTP and `enclosureURL.scheme == "https"` after parsing. Parse a positive `length` without accepting float, sign, whitespace-only, or overflow values. The client must select the highest build greater than `afterBuild`, not merely the first XML item.

- [ ] **Step 4: Write failing Ed25519 length/signature tests**

In `SparkleSignatureVerifierTests.swift`, generate a deterministic `Curve25519.Signing.PrivateKey(rawRepresentation:)` fixture, sign `Data("dmg bytes".utf8)`, and assert:

```swift
func testAcceptsMatchingSignatureAndLength() throws {
    let artifact = Data("dmg bytes".utf8)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    let signature = try key.signature(for: artifact)

    XCTAssertNoThrow(try SparkleSignatureVerifier().verify(
        artifact: artifact,
        expectedLength: artifact.count,
        base64Signature: signature.base64EncodedString(),
        base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
    ))
}

func testRejectsOneByteTamperedArtifact() throws {
    let artifact = Data("dmg bytes".utf8)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    let signature = try key.signature(for: artifact)

    XCTAssertThrowsError(try SparkleSignatureVerifier().verify(
        artifact: Data("dmg byteX".utf8),
        expectedLength: artifact.count,
        base64Signature: signature.base64EncodedString(),
        base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
    ))
}
```

- [ ] **Step 5: Implement CryptoKit verification and test it**

Implement `SparkleSignatureVerifier.verify` in this order:

1. Guard `artifact.count == expectedLength`, otherwise throw `.operation("Downloaded app update length does not match appcast metadata.")`.
2. Base64-decode public key and signature; instantiate `Curve25519.Signing.PublicKey(rawRepresentation:)`.
3. Call `isValidSignature(signature, for: artifact)`.
4. Throw `.operation("Downloaded app update signature is invalid.")` if false.

Run:

```bash
swift test --filter AppcastClientTests
swift test --filter SparkleSignatureVerifierTests
```

Expected: PASS.

- [ ] **Step 6: Add a release-pipeline compatibility fixture**

Extend `Tests/ScriptTests/generate-sparkle-appcast-tests.sh` to save a small signed binary artifact and its appcast enclosure attributes generated by the real/fake `sign_update` harness. Add a Core fixture test that loads this artifact/signature pair and confirms `SparkleSignatureVerifier` accepts it. If the Sparkle-generated signature format is not directly compatible with `Curve25519.Signing`, stop this task and replace the verifier implementation with the Sparkle vendored verification implementation behind a Core wrapper; do not weaken validation or accept unverified DMGs.

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
swift test --filter SparkleSignatureVerifierTests
```

Expected: PASS with release-pipeline-compatible signature validation.

- [ ] **Step 7: Commit feed and signature verification**

```bash
git add Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift Sources/CLIProxyManagerCore/Updates/AppcastClient.swift Sources/CLIProxyManagerCore/Updates/SparkleSignatureVerifier.swift Tests/CLIProxyManagerCoreTests/AppcastClientTests.swift Tests/CLIProxyManagerCoreTests/SparkleSignatureVerifierTests.swift Tests/ScriptTests/generate-sparkle-appcast-tests.sh
git commit -m "feat: verify headless app update releases" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 3: Verify mounted DMG and persist an app update stage

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateStager.swift`
- Modify: `Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppUpdateStagerTests.swift`

**Interfaces:**
- Produces: `ManagedPaths.appUpdatesDirectory`, `appUpdateDirectory(build:)`, `appUpdateManifest(build:)`.
- Produces: `public struct StagedAppUpdate: Codable, Equatable, Sendable` with version, build, sourceURL, artifactSHA256, expectedLength, stagedAt.
- Produces: `public protocol AppUpdateStaging: Sendable { func stage(release: AppUpdateRelease, artifact: Data) async throws -> StagedAppUpdate; func stagedUpdate() throws -> StagedAppUpdate? }`.
- Consumes: Task 2 verified artifact and `ProcessRunning` for `hdiutil`, `codesign`, and `ditto`.

- [ ] **Step 1: Write failing app-stage tests with an injected mount verifier**

Use a fake `MountedDMGInspecting` protocol; unit tests must not mount a real DMG:

```swift
func testStageCopiesVerifiedAppAndBothHelpersIntoManagedPath() async throws {
    let paths = try makePaths()
    let inspector = MountedDMGInspectorDouble(app: verifiedMountedApp(version: "0.1.13", build: 16))
    let stager = AppUpdateStager(paths: paths, mountedInspector: inspector, now: { fixedDate })
    let artifact = Data("signed-dmg".utf8)

    let staged = try await stager.stage(release: release(version: "0.1.13", build: 16), artifact: artifact)

    XCTAssertEqual(staged.version, "0.1.13")
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appUpdateDirectory(build: 16).appendingPathComponent("CLIProxyManager.app").path))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.appUpdateDirectory(build: 16).appendingPathComponent("cpm").path))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.appUpdateDirectory(build: 16).appendingPathComponent("cliproxy-manager").path))
}

func testStageLeavesNoDestinationWhenMountedBundleIdentifierIsWrong() async {
    let paths = try makePaths()
    let stager = AppUpdateStager(paths: paths, mountedInspector: MountedDMGInspectorDouble(app: invalidIdentifierApp()))

    await XCTAssertThrowsErrorAsync(try await stager.stage(release: release(version: "0.1.13", build: 16), artifact: Data("dmg".utf8)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appUpdateDirectory(build: 16).path))
}
```

- [ ] **Step 2: Run stage tests and verify they fail**

```bash
swift test --filter AppUpdateStagerTests
```

Expected: compile failure because stage paths and stager do not exist.

- [ ] **Step 3: Add managed stage paths and atomic stage layout**

Add to `ManagedPaths`:

```swift
public var appUpdatesDirectory: URL {
    rootDirectory.appendingPathComponent("updates/app", isDirectory: true)
}

public func appUpdateDirectory(build: Int) -> URL {
    appUpdatesDirectory.appendingPathComponent(String(build), isDirectory: true)
}

public func appUpdateManifest(build: Int) -> URL {
    appUpdateDirectory(build: build).appendingPathComponent("manifest.json")
}
```

Stage into `<root>/updates/app/.<build>.tmp/`, then rename to `<root>/updates/app/<build>/` only after the copied app/helper files and manifest validate. Remove a prior stage with the same build only after new temporary contents are valid. Do not include config, Keychain, or auth files in the stage.

- [ ] **Step 4: Implement production mounted-DMG inspection**

`HdiutilMountedDMGInspector` must:

1. Write already signature-verified DMG data to a temporary regular file under `appUpdatesDirectory` with permissions `0600`.
2. Run `/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint <temporary mount dir> <dmg path>` through `ProcessRunning`; always schedule `/usr/bin/hdiutil detach <mount dir>` in `defer` when attach succeeds.
3. Require `<mount>/CLIProxyManager.app`, then read `Contents/Info.plist` and require `CFBundleIdentifier == com.woosublee.CLIProxyManager`, release version, and release build exactly match `AppUpdateRelease`.
4. Require executable `Contents/Helpers/cpm` and `Contents/Helpers/cliproxy-manager`.
5. Run `/usr/bin/codesign --verify --deep --strict <mounted app>` and reject a nonzero result.
6. Copy the app using `/usr/bin/ditto --norsrc --noextattr`; copy helpers from the copied staged app into sibling `cpm` and `cliproxy-manager` paths; set helper permissions `0755`.

All `hdiutil`, `codesign`, and `ditto` stderr must appear only in wrapped `.operation` errors; no auth or home data is logged.

- [ ] **Step 5: Run staging tests and binary/resource regression tests**

```bash
swift test --filter AppUpdateStagerTests
swift test --filter LicenseResourceTests
swift test --filter AppBundleLocatorTests
```

Expected: PASS.

- [ ] **Step 6: Commit verified app staging**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift Sources/CLIProxyManagerCore/Updates/AppUpdateStager.swift Tests/CLIProxyManagerCoreTests/AppUpdateStagerTests.swift
git commit -m "feat: stage verified app updates for cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 4: Apply staged app plus both helpers with preflight and restoration

**Files:**
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateApplier.swift`
- Create: `Sources/CLIProxyManagerCore/Updates/AppUpdateService.swift`
- Modify: `Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppUpdateApplierTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppUpdateServiceTests.swift`

**Interfaces:**
- Produces: `public struct AppUpdateApplyResult: Equatable, Sendable { let version: String; let appRestarted: Bool; let appRestartWarning: String? }`.
- Produces: `public protocol AppUpdating: Sendable { func check() async throws -> AppUpdateCheckResult; func stage() async throws -> AppUpdateStageResult; func apply() async throws -> AppUpdateApplyResult }`.
- Consumes: Task 3 `StagedAppUpdate`, Task 2 appcast client/signature verifier, Task 4 runtime `AppLifecycleControlling`.

- [ ] **Step 1: Write transactional preflight and rollback tests with a filesystem mover double**

Create `AppUpdateApplierTests` using isolated app/helper directories rather than real `/Applications` and `/usr/local/bin`:

```swift
func testPreflightFailureDoesNotReplaceAnyTarget() async throws {
    let fixture = try makeTargets()
    let applier = makeApplier(targets: fixture.targets, permissionChecker: PermissionCheckerDouble(allowed: false))

    await XCTAssertThrowsErrorAsync(try await applier.apply(staged: fixture.staged)) { error in
        XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("Current user cannot update all app and helper installation paths."))
    }

    XCTAssertEqual(try contents(of: fixture.appTarget), "old app")
    XCTAssertEqual(try contents(of: fixture.cpmTarget), "old cpm")
    XCTAssertEqual(try contents(of: fixture.legacyTarget), "old legacy")
}

func testFailureReplacingSecondHelperRestoresAppAndFirstHelper() async throws {
    let fixture = try makeTargets()
    let mover = TransactionMoverDouble(failOnMoveNumber: 5)
    let applier = makeApplier(targets: fixture.targets, mover: mover)

    await XCTAssertThrowsErrorAsync(try await applier.apply(staged: fixture.staged))

    XCTAssertEqual(try contents(of: fixture.appTarget), "old app")
    XCTAssertEqual(try contents(of: fixture.cpmTarget), "old cpm")
    XCTAssertEqual(try contents(of: fixture.legacyTarget), "old legacy")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appPrevious.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cpmPrevious.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyPrevious.path))
}

func testSuccessfulApplyRestartsOnlyPreexistingRunningApp() async throws {
    let lifecycle = AppLifecycleDouble(running: true)
    let result = try await makeApplier(lifecycle: lifecycle).apply(staged: try makeStaged())

    XCTAssertEqual(lifecycle.calls, [.stop, .start])
    XCTAssertTrue(result.appRestarted)
}
```

- [ ] **Step 2: Run applier tests and verify they fail**

```bash
swift test --filter AppUpdateApplierTests
```

Expected: compile failure because the applier, target model, permission checker, and transaction mover do not exist.

- [ ] **Step 3: Implement all-target preflight before mutations**

Define `AppInstallTargets` with defaults:

```swift
public struct AppInstallTargets: Equatable, Sendable {
    public let app: URL
    public let cpm: URL
    public let legacyHelper: URL
    public static let standard = AppInstallTargets(
        app: URL(fileURLWithPath: "/Applications/CLIProxyManager.app"),
        cpm: URL(fileURLWithPath: "/usr/local/bin/cpm"),
        legacyHelper: URL(fileURLWithPath: "/usr/local/bin/cliproxy-manager")
    )
}
```

Before stop/copy/rename, verify all of:

- process effective uid is not `0`;
- parent directories exist and are writable/searchable by current user;
- existing target files/directories are writable/deletable by current user, or absent with parent writable;
- staged app and both staged helper regular files exist, are not symlinks, match `StagedAppUpdate` build/version, and executable helpers are `0755`.

On any failure throw exactly `.prerequisite("Current user cannot update all app and helper installation paths.")` and make no target changes. Preserve the staged directory.

- [ ] **Step 4: Implement copy-to-local-temporary then rename transaction**

For each target, create temporary and previous siblings in its own parent directory:

```text
/Applications/.CLIProxyManager.app.cpm-stage
/Applications/.CLIProxyManager.app.cpm-previous
/usr/local/bin/.cpm.cpm-stage
/usr/local/bin/.cpm.cpm-previous
/usr/local/bin/.cliproxy-manager.cpm-stage
/usr/local/bin/.cliproxy-manager.cpm-previous
```

Copy staged source to each local temporary target before any canonical target rename. Then:

1. Record `wasRunning = try await appLifecycle.status().running`.
2. If `wasRunning`, call `appLifecycle.stop()`; stop failure aborts before copying/renaming.
3. Rename existing canonical targets to corresponding previous paths when present.
4. Rename all local temporary targets to canonical paths.
5. On any error after step 3, remove new canonical targets, move every existing previous target back, remove local temporary paths, then throw an `.operation` that includes whether automatic restoration succeeded.
6. On success remove prior paths and the consumed staged app directory.
7. If `wasRunning`, call `appLifecycle.start()`. If GUI session is unavailable after a successful filesystem transaction, return `appRestarted: false` with a warning instead of rolling back the successfully installed version.

Do not touch `~/.cliproxy-manager/cliproxyapi/cliproxyapi`; proxy update remains an independent command.

- [ ] **Step 5: Implement service check/stage/apply orchestration**

`AppUpdateService.check()` reads current installed build with `AppBundleLocating`, then calls `AppcastFetching.fetchLatest(afterBuild:)`; a valid staged manifest for a higher build yields `.pending`, otherwise a release yields `.available`, otherwise `.upToDate`.

`stage()` uses the appcast client, downloads the enclosure with an `HTTPClient`-backed artifact downloader, calls `SparkleSignatureVerifier`, then `AppUpdateStaging.stage`.

`apply()` reads a staged manifest and calls `AppUpdateApplier`. With no staged manifest, throw:

```swift
.prerequisite("No staged CLIProxyManager update is available. Run cpm update stage app first.")
```

- [ ] **Step 6: Run all app update unit tests**

```bash
swift test --filter AppUpdateApplierTests
swift test --filter AppUpdateServiceTests
swift test --filter AppUpdateStagerTests
```

Expected: PASS, including preflight-no-change and rollback restoration cases.

- [ ] **Step 7: Commit safe app/helper apply**

```bash
git add Sources/CLIProxyManagerCore/Updates/AppUpdateApplier.swift Sources/CLIProxyManagerCore/Updates/AppUpdateService.swift Sources/CLIProxyManagerCore/Updates/AppUpdateModels.swift Tests/CLIProxyManagerCoreTests/AppUpdateApplierTests.swift Tests/CLIProxyManagerCoreTests/AppUpdateServiceTests.swift
git commit -m "feat: apply staged app updates with cpm" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 5: Complete `cpm update app|proxy|all` command grammar and status

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift`
- Modify: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift`
- Modify: `Sources/CLIProxyManagerCore/Runtime/StatusService.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift`
- Modify: `Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift`

**Interfaces:**
- Produces: complete public grammar:

```text
cpm update check [app|proxy|all]
cpm update stage [app|proxy|all]
cpm update apply [app|proxy|all] [--yes]
```

- Consumes: proxy `ProxyUpdating` from proxy-update plan and app `AppUpdating` from Task 4.

- [ ] **Step 1: Replace explicit-target-only test with default-all behavior tests**

Update `CLIProxyManagerUpdateCommandTests`:

```swift
func testCheckWithoutTargetChecksAppThenProxy() async throws {
    let services = UpdateServicesDouble()
    try await makeCommand(services: services).run(arguments: ["update", "check"])
    XCTAssertEqual(services.calls, [.appCheck, .proxyCheck])
}

func testStageAllStagesBothIndependentTargets() async throws {
    let services = UpdateServicesDouble()
    try await makeCommand(services: services).run(arguments: ["update", "stage", "all"])
    XCTAssertEqual(services.calls, [.appStage, .proxyStage])
}

func testApplyAllAppliesBothStagedTargetsWithOneConfirmation() async throws {
    let services = UpdateServicesDouble(interactive: true, confirms: true)
    try await makeCommand(services: services).run(arguments: ["update", "apply", "all"])
    XCTAssertEqual(services.confirmationPrompts, ["Apply all staged updates? "])
    XCTAssertEqual(services.calls, [.appApply, .proxyApply])
}

func testApplyAllContinuesWhenOnlyOneTargetHasStagedUpdate() async throws {
    let services = UpdateServicesDouble(appApplyError: .noStage, proxyApplyResult: .applied)
    try await makeCommand(services: services).run(arguments: ["update", "apply", "all", "--yes"])
    XCTAssertEqual(services.calls, [.appApply, .proxyApply])
}
```

- [ ] **Step 2: Run grammar tests and verify failure**

```bash
swift test --filter CLIProxyManagerUpdateCommandTests
```

Expected: FAIL because no app updater exists in the existing dispatcher and no-target remains usage.

- [ ] **Step 3: Implement target parsing and all-result rules**

Parse the target as `app`, `proxy`, or `all`, defaulting absent target to `all`. `--yes` is valid only once and only for `apply`. For `all`, run app first and proxy second, collecting outcomes:

- check/stage: return nonzero only if at least one requested target fails; print both outcomes.
- apply: treat each `.noStage` prerequisite as skipped for `all`, continue to the other target, and fail only if neither target applied or any target has a non-`noStage` failure.
- app/proxy direct apply: `.noStage` remains an exit `3` error.

Use headers exactly:

```text
App: <outcome>
Proxy: <outcome>
```

Before apply, prompt once with `Apply staged CLIProxyManager update? `, `Apply staged CLIProxyAPI update? `, or `Apply all staged updates? `. Noninteractive apply without `--yes` remains usage error.

- [ ] **Step 4: Populate staged app version in status without exposing sensitive data**

Modify `StatusService` to inject `AppUpdating` or a narrow `AppUpdateStageReading` protocol. When a valid staged app manifest exists, set `CPMStatus.App.stagedVersion` to its version; otherwise `nil`. Keep proxy staged version reading separate through existing pending manifest. Add test assertions that JSON includes `stagedVersion` but excludes `sourceURL`, auth profile content, or key material.

- [ ] **Step 5: Run command and status coverage**

```bash
swift test --filter CLIProxyManagerUpdateCommandTests
swift test --filter StatusServiceTests
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit full update command surface**

```bash
git add Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift Sources/CLIProxyManagerCore/Runtime/StatusService.swift Tests/CLIProxyManagerCoreTests/CLIProxyManagerUpdateCommandTests.swift Tests/CLIProxyManagerCoreTests/StatusServiceTests.swift
git commit -m "feat: complete cpm app and proxy updates" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 6: Release CI, README, and development-build verification

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`
- Modify: `Tests/ScriptTests/release-local-tests.sh`
- Modify: `Tests/ScriptTests/generate-sparkle-appcast-tests.sh`

**Interfaces:**
- Consumes: completed package, stage, apply, status, and update command contracts.

- [ ] **Step 1: Add CI coverage for existing shell release tests**

In the release workflow Test step, replace the single command with:

```yaml
run: |
  swift test
  bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
  bash Tests/ScriptTests/release-local-tests.sh
  bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh
```

Keep the build/sign/release steps after this test block unchanged.

- [ ] **Step 2: Document bootstrap and safe update flow**

Add these sections to README:

```markdown
### First `cpm` installation

Install a release containing `cpm` once using the normal DMG/install flow. Earlier releases only contain `cliproxy-manager`, so they cannot install `cpm` by themselves.

### Headless updates

```zsh
cpm update check
cpm update stage
cpm update apply
# Automation after inspecting staged versions:
cpm update apply --yes
```
```

State all of these facts explicitly:

- `stage` verifies the appcast Ed25519 signature, artifact size, mounted app identity/version, code signature, and both helpers before changing any installed file.
- `apply` updates `/Applications/CLIProxyManager.app`, `/usr/local/bin/cpm`, and `/usr/local/bin/cliproxy-manager` together or restores the previous three paths if replacement fails.
- command must run as the same non-root macOS user that installed the app; `sudo cpm` is rejected and a permission error leaves the stage intact.
- GUI restart is best effort after successful app replacement; GUI absence does not prevent proxy or update management.
- `cpm update apply proxy` and app updates are independent; app update does not downgrade active CLIProxyAPI.

- [ ] **Step 3: Run complete offline verification**

```bash
swift test
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
bash Tests/ScriptTests/release-local-tests.sh
bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh
make CONFIGURATION=debug CODESIGN_IDENTITY=- verify-dmg
```

Expected: PASS; DMG verification confirms app and both helpers.

- [ ] **Step 4: Perform non-destructive development-build checks**

```bash
swift build --product cpm
.build/debug/cpm status --json
.build/debug/cpm update check
```

Expected: status JSON lists app/helper/proxy fields without secrets; update check may report up-to-date or updates available but must not write an app stage, replace a helper, restart the GUI, or restart the proxy. Do not execute real `stage` or `apply` against the user’s installed app without explicit permission.

- [ ] **Step 5: Commit release hardening and documentation**

```bash
git add .github/workflows/release.yml README.md Tests/ScriptTests/release-local-tests.sh Tests/ScriptTests/generate-sparkle-appcast-tests.sh
git commit -m "docs: document cpm headless update workflow" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```
