# App Update Bundled CLIProxyAPI Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 업데이트 후 새 앱에 포함된 CLIProxyAPI를 자동으로 active 경로에 반영하고, 실행 중 서버를 안전하게 재시작하되 사용자가 승인하지 않은 pending 업데이트는 적용하지 않는다.

**Architecture:** Core의 `CLIProxyAPIBinaryStore`에 pending 적용 예약 marker와 pending을 승격하지 않는 번들 전용 reconciliation 연산을 추가한다. App 계층의 `BundledProxyReconciliationService`가 해당 연산을 감싸고 `DashboardViewModel.startApplication()`이 서버 상태 확인, reconciliation, 필요 시 단일 재시작을 orchestration한다. `CLIProxyAPIUpdateService`와 두 confirmation dialog는 `Apply on next server start` 선택을 durable marker로 기록하고 앱 시작 reconciliation 후 저장 상태를 다시 읽는다.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest, SwiftUI, Foundation/CryptoKit, macOS 15+, Sparkle 2.9.2

## Global Constraints

- Sparkle의 다운로드, 서명 검증, 앱 설치 방식은 변경하지 않는다.
- 번들 CLIProxyAPI는 active보다 최신이거나 active가 없거나 손상된 경우에만 자동 설치한다.
- 유효한 active가 번들과 같거나 더 최신이면 다운그레이드하지 않는다.
- pending은 `Apply now` 또는 `Apply on next server start`를 명시적으로 선택한 경우에만 적용한다.
- confirmation dialog의 `Cancel`은 pending 적용 예약을 생성하지 않는다.
- 성공 시 새 modal을 추가하지 않고 현재 버전과 서버 상태만 갱신한다.
- 실패 시 앱 시작은 계속하고 기존 active와 실행 중 서버를 가능한 한 보존한다.
- 전체 테스트와 development configuration build까지 자동 검증하고 앱 실행·수동 UI 확인은 사용자가 수행한다.

---

## File Structure

### Core

- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - pending 적용 예약 marker의 canonical 경로를 제공한다.
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
  - pending 적용 예약, 예약된 pending의 조건부 승격, 번들 전용 reconciliation, stale pending 정리, atomic rollback을 담당한다.

### App

- Create: `Sources/CLIProxyManagerApp/Services/BundledProxyReconciliationService.swift`
  - 앱 번들 URL과 core binary store를 연결하고 test double 주입 경계를 제공한다.
- Modify: `Sources/CLIProxyManagerApp/BundledProxyBinary.swift`
  - 기본 reconciliation service factory를 제공한다.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - 앱 시작 시 서버 상태 확인 → 번들 reconciliation → 필요 시 재시작 → 기존 startup 흐름을 orchestration한다.
- Modify: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
  - pending 적용 예약과 저장 상태 reload를 UI에 제공한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - Dashboard confirmation dialog의 `Apply on next server start`를 실제 예약 동작에 연결한다.
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - Settings confirmation dialog의 같은 동작을 실제 예약에 연결한다.
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
  - 앱 시작 reconciliation이 끝난 뒤 CLIProxyAPI update 상태를 다시 읽는다.

### Tests

- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`
  - 새 ManagedPaths marker 경로를 검증한다.
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`
  - pending 승인 경계와 bundled reconciliation 정책을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/BundledProxyReconciliationServiceTests.swift`
  - app service가 bundle URL과 결과를 정확히 전달하는지 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
  - startup reconciliation과 서버 재시작 정책을 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`
  - pending 예약 및 상태 reload를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`
  - Dashboard/Settings 버튼 wiring과 앱 startup reload 순서를 검증한다.

---

### Task 1: Make Pending Application Explicit

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:82-96`
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift:38-178`
- Modify: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift:13-22`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift:23-157`

**Interfaces:**
- Produces: `ManagedPaths.pendingClipProxyApplyOnNextStartMarker: URL`
- Produces: `CLIProxyAPIBinaryStore.schedulePendingForNextStart() throws`
- Preserves: `CLIProxyAPIBinaryStore.applyPending() throws` for immediate application
- Changes: `prepareActiveBinary(...)` applies pending only when the marker exists

- [ ] **Step 1: Write failing path and unscheduled-pending tests**

Add the marker assertion to `testManagedPathsExposeCLIProxyAPIUpdatePaths()`:

```swift
XCTAssertEqual(
    paths.pendingClipProxyApplyOnNextStartMarker,
    sandbox.appendingPathComponent("managed/cliproxyapi/pending/apply-on-next-start")
)
```

Change the existing scheduled-promotion test to explicitly schedule the pending binary:

```swift
try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)
try store.schedulePendingForNextStart()

try store.prepareActiveBinary(
    bundledBinaryURL: bundledBinary,
    bundledManifestURL: bundledManifest
)

XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyDirectory.path))
```

Add an unscheduled-pending regression test:

```swift
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
    let store = CLIProxyAPIBinaryStore(paths: paths)
    try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

    try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

    XCTAssertEqual(try store.activeManifest()?.version, "7.2.41")
    XCTAssertEqual(try store.pendingManifest()?.version, "7.2.42")
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
}
```

- [ ] **Step 2: Run focused tests and confirm they fail**

Run:

```bash
swift test --filter 'ProxyServiceManagerTests/testManagedPathsExposeCLIProxyAPIUpdatePaths|CLIProxyAPIBinaryStoreTests/testPreparePromotesValidPendingBeforeUsingBundledBinary|CLIProxyAPIBinaryStoreTests/testPrepareKeepsValidUnscheduledPendingWithoutApplyingIt'
```

Expected: FAIL because `pendingClipProxyApplyOnNextStartMarker` and `schedulePendingForNextStart()` do not exist, and current prepare applies unscheduled pending.

- [ ] **Step 3: Add the marker path and scheduling API**

Add to `ManagedPaths`:

```swift
public var pendingClipProxyApplyOnNextStartMarker: URL {
    pendingClipProxyDirectory.appendingPathComponent("apply-on-next-start")
}
```

Add the public operation and locked implementation to `CLIProxyAPIBinaryStore`:

```swift
public func schedulePendingForNextStart() throws {
    try Self.operationLock.withLock {
        guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) else {
            throw CLIProxyAPIBinaryStoreError.missingPendingBinary
        }
        guard let manifest = try pendingManifest() else {
            throw CLIProxyAPIBinaryStoreError.missingPendingManifest
        }
        try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
        try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
        try Data("scheduled\n".utf8).write(
            to: paths.pendingClipProxyApplyOnNextStartMarker,
            options: .atomic
        )
    }
}
```

Add helpers:

```swift
private func isPendingScheduledForNextStart() -> Bool {
    fileManager.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path)
}

private func clearPendingApplyOnNextStartMarker() throws {
    guard isPendingScheduledForNextStart() else { return }
    try fileManager.removeItem(at: paths.pendingClipProxyApplyOnNextStartMarker)
}
```

- [ ] **Step 4: Gate pending promotion and clear stale consent**

In `savePendingLocked`, keep the existing optional binary validation first, then clear the old marker immediately before creating/replacing pending files so an invalid download does not disturb the old pending state and a valid new binary never inherits consent for an older binary:

```swift
if validate {
    try validateBinary(at: binaryURL, manifest: manifest)
}
try clearPendingApplyOnNextStartMarker()
try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
```

Replace `applyUsablePendingIfNewest(...)` with logic that validates and removes stale pending first, preserves a newer unscheduled pending, and applies only a scheduled one:

```swift
private func applyUsablePendingIfNewest(
    bundledVersion: CLIProxyAPIVersion,
    activeVersion: CLIProxyAPIVersion?
) throws {
    guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path)
            || fileManager.fileExists(atPath: paths.pendingClipProxyManifest.path) else {
        return
    }
    guard let pending = try? pendingManifest(),
          let pendingVersion = pending.parsedVersion,
          pendingVersion > bundledVersion,
          activeVersion.map({ pendingVersion > $0 }) ?? true,
          binaryMatches(paths.pendingClipProxyBinary, manifest: pending) else {
        try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
        return
    }
    guard isPendingScheduledForNextStart() else { return }
    try applyPendingLocked()
}
```

Keep the marker through rollback by removing the pending directory only after active binary and manifest writes succeed. Successful `applyPendingLocked()` already removes the entire pending directory, which removes the marker atomically with pending cleanup.

- [ ] **Step 5: Add marker lifecycle regression tests**

Add:

```swift
func testSavePendingClearsApplyOnNextStartMarkerFromPreviousPending() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let first = sandbox.appendingPathComponent("download/first")
    let second = sandbox.appendingPathComponent("download/second")
    try writeExecutable("first", to: first)
    try writeExecutable("second", to: second)
    let store = CLIProxyAPIBinaryStore(paths: paths)
    try store.savePending(binaryURL: first, manifest: try manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(first), size: fileSize(first)))
    try store.schedulePendingForNextStart()

    try store.savePending(binaryURL: second, manifest: try manifest(version: "7.2.43", sourceKind: .userUpdated, binarySha: sha256(second), size: fileSize(second)))

    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
    XCTAssertEqual(try store.pendingManifest()?.version, "7.2.43")
}

func testSchedulePendingForNextStartRejectsMissingPendingBinary() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = CLIProxyAPIBinaryStore(paths: paths)

    XCTAssertThrowsError(try store.schedulePendingForNextStart()) { error in
        XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .missingPendingBinary)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
}
```

- [ ] **Step 6: Run binary-store tests**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
```

Expected: PASS. Existing tests that expected automatic pending promotion must now call `schedulePendingForNextStart()` explicitly.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift
git commit -m "fix: require consent for pending proxy updates" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add Bundled-Only Binary Reconciliation

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift:14-188`
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`

**Interfaces:**
- Consumes: marker semantics from Task 1
- Produces: `BundledProxyReconciliationResult`
- Produces: `CLIProxyAPIBinaryStore.reconcileBundledBinary(bundledBinaryURL:bundledManifestURL:) throws -> BundledProxyReconciliationResult`
- Guarantees: this operation never promotes a pending binary

- [ ] **Step 1: Write failing bundled reconciliation tests**

Add tests for newer bundle, newer active, missing active, invalid bundle, and pending preservation:

```swift
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
    let store = CLIProxyAPIBinaryStore(paths: paths)
    try store.savePending(binaryURL: pending, manifest: try manifest(version: "7.2.92", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending)))

    let result = try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)

    XCTAssertEqual(result, .installed(previousVersion: CLIProxyAPIVersion("7.2.72"), newVersion: CLIProxyAPIVersion("7.2.91")!))
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
    let store = CLIProxyAPIBinaryStore(paths: paths)

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
    let store = CLIProxyAPIBinaryStore(paths: paths)

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
    let store = CLIProxyAPIBinaryStore(paths: paths)

    XCTAssertThrowsError(
        try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)
    ) { error in
        XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .binaryChecksumMismatch)
    }
    XCTAssertEqual(try store.activeManifest()?.version, "7.2.72")
}
```

- [ ] **Step 2: Run focused tests and confirm missing API failures**

Run:

```bash
swift test --filter 'CLIProxyAPIBinaryStoreTests/testReconcileBundled'
```

Expected: FAIL because `BundledProxyReconciliationResult` and `reconcileBundledBinary` do not exist.

- [ ] **Step 3: Define the result type**

Add above `CLIProxyAPIBinaryStore`:

```swift
public enum BundledProxyReconciliationResult: Equatable, Sendable {
    case unchanged(version: CLIProxyAPIVersion)
    case installed(previousVersion: CLIProxyAPIVersion?, newVersion: CLIProxyAPIVersion)
    case recoveredInvalidActive(newVersion: CLIProxyAPIVersion)

    public var activeVersion: CLIProxyAPIVersion {
        switch self {
        case .unchanged(let version):
            return version
        case .installed(_, let newVersion), .recoveredInvalidActive(let newVersion):
            return newVersion
        }
    }

    public var didChangeBinary: Bool {
        switch self {
        case .unchanged:
            return false
        case .installed, .recoveredInvalidActive:
            return true
        }
    }
}
```

- [ ] **Step 4: Implement bundled-only reconciliation**

Add a public locked entry point:

```swift
public func reconcileBundledBinary(
    bundledBinaryURL: URL?,
    bundledManifestURL: URL?
) throws -> BundledProxyReconciliationResult {
    try Self.operationLock.withLock {
        try reconcileBundledBinaryLocked(
            bundledBinaryURL: bundledBinaryURL,
            bundledManifestURL: bundledManifestURL
        )
    }
}
```

Implement the private operation so bundle validation happens before any active or pending mutation:

```swift
private func reconcileBundledBinaryLocked(
    bundledBinaryURL: URL?,
    bundledManifestURL: URL?
) throws -> BundledProxyReconciliationResult {
    guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
        throw CLIProxyAPIBinaryStoreError.missingBundledBinary
    }
    guard let bundledManifestURL,
          let bundledManifest = try readManifestIfExists(bundledManifestURL) else {
        throw CLIProxyAPIBinaryStoreError.missingBundledManifest
    }
    guard let bundledVersion = bundledManifest.parsedVersion else {
        throw CLIProxyAPIBinaryStoreError.invalidManifestVersion(bundledManifest.version)
    }
    try validateBinary(at: bundledBinaryURL, manifest: bundledManifest)

    let existingManifest = try? activeManifest()
    let existingVersion = existingManifest?.parsedVersion
    guard let validActive = validActiveManifest(),
          let activeVersion = validActive.parsedVersion else {
        try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
        removePendingUnlessNewer(than: bundledVersion)
        return .recoveredInvalidActive(newVersion: bundledVersion)
    }

    if activeVersion < bundledVersion {
        try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
        removePendingUnlessNewer(than: bundledVersion)
        return .installed(previousVersion: existingVersion, newVersion: bundledVersion)
    }

    try ensureExecutable(paths.clipProxyBinary)
    removePendingUnlessNewer(than: activeVersion)
    return .unchanged(version: activeVersion)
}
```

Add pending cleanup that never promotes a binary:

```swift
private func removePendingUnlessNewer(than activeVersion: CLIProxyAPIVersion) {
    guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path)
            || fileManager.fileExists(atPath: paths.pendingClipProxyManifest.path) else {
        return
    }
    guard let pending = try? pendingManifest(),
          let pendingVersion = pending.parsedVersion,
          pendingVersion > activeVersion,
          binaryMatches(paths.pendingClipProxyBinary, manifest: pending) else {
        try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
        return
    }
}
```

Refactor `prepareActiveBinaryLocked` to reuse the validated bundle and reconciliation helpers without changing its scheduled-pending-first semantics. Do not call public methods while holding `operationLock`; call private `...Locked` helpers only.

- [ ] **Step 5: Add stale and scheduled pending reconciliation tests**

Add:

```swift
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
    let store = CLIProxyAPIBinaryStore(paths: paths)
    try store.savePending(binaryURL: pending, manifest: try manifest(version: "7.2.80", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending)))
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
    let store = CLIProxyAPIBinaryStore(paths: paths)
    try store.savePending(binaryURL: pending, manifest: try manifest(version: "7.2.92", sourceKind: .userUpdated, binarySha: sha256(pending), size: fileSize(pending)))
    try store.schedulePendingForNextStart()

    _ = try store.reconcileBundledBinary(bundledBinaryURL: bundled, bundledManifestURL: bundledManifest)

    XCTAssertEqual(try store.activeManifest()?.version, "7.2.91")
    XCTAssertEqual(try store.pendingManifest()?.version, "7.2.92")
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path))
}
```

- [ ] **Step 6: Run core tests**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
swift test --filter ProxyServiceManagerTests
```

Expected: PASS. `prepareActiveBinary` still applies a scheduled newer pending; `reconcileBundledBinary` never does.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift
git commit -m "feat: reconcile bundled proxy binary on demand" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Reconcile the Bundle During App Startup

**Files:**
- Create: `Sources/CLIProxyManagerApp/Services/BundledProxyReconciliationService.swift`
- Modify: `Sources/CLIProxyManagerApp/BundledProxyBinary.swift:19-21`
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:112-329,480-484`
- Create: `Tests/CLIProxyManagerAppTests/BundledProxyReconciliationServiceTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:3709-3727,4888-4918,6074-6181`

**Interfaces:**
- Consumes: `CLIProxyAPIBinaryStore.reconcileBundledBinary(...)`
- Produces: `BundledProxyReconciling.reconcile() throws -> BundledProxyReconciliationResult`
- Changes: `DashboardViewModel.startApplication()` performs reconciliation before subscription setup/autostart

- [ ] **Step 1: Write failing service forwarding test**

Create `BundledProxyReconciliationServiceTests.swift`:

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class BundledProxyReconciliationServiceTests: XCTestCase {
    func testReconcileForwardsBundledURLsAndReturnsStoreResult() throws {
        let binary = URL(fileURLWithPath: "/tmp/bundle/cliproxyapi")
        let manifest = URL(fileURLWithPath: "/tmp/bundle/cliproxyapi.manifest.json")
        let store = BundledProxyBinaryStoreDouble(
            result: .installed(
                previousVersion: CLIProxyAPIVersion("7.2.72"),
                newVersion: CLIProxyAPIVersion("7.2.91")!
            )
        )
        let service = BundledProxyReconciliationService(
            store: store,
            bundledBinaryURL: binary,
            bundledManifestURL: manifest
        )

        let result = try service.reconcile()

        XCTAssertEqual(result.activeVersion.description, "7.2.91")
        XCTAssertEqual(store.binaryURLs, [binary])
        XCTAssertEqual(store.manifestURLs, [manifest])
    }
}

private final class BundledProxyBinaryStoreDouble: BundledProxyBinaryStoring, @unchecked Sendable {
    private(set) var binaryURLs: [URL?] = []
    private(set) var manifestURLs: [URL?] = []
    let result: BundledProxyReconciliationResult

    init(result: BundledProxyReconciliationResult) {
        self.result = result
    }

    func reconcileBundledBinary(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult {
        binaryURLs.append(bundledBinaryURL)
        manifestURLs.append(bundledManifestURL)
        return result
    }
}
```

- [ ] **Step 2: Run the service test and confirm missing types**

Run:

```bash
swift test --filter BundledProxyReconciliationServiceTests
```

Expected: FAIL because the app service and protocol do not exist.

- [ ] **Step 3: Implement the reconciliation service and factory**

Create `BundledProxyReconciliationService.swift`:

```swift
import CLIProxyManagerCore
import Foundation

protocol BundledProxyBinaryStoring: Sendable {
    func reconcileBundledBinary(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult
}

extension CLIProxyAPIBinaryStore: BundledProxyBinaryStoring {}

protocol BundledProxyReconciling: Sendable {
    func reconcile() throws -> BundledProxyReconciliationResult
}

struct BundledProxyReconciliationService: BundledProxyReconciling, Sendable {
    private let store: any BundledProxyBinaryStoring
    private let bundledBinaryURL: URL?
    private let bundledManifestURL: URL?

    init(
        store: any BundledProxyBinaryStoring,
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) {
        self.store = store
        self.bundledBinaryURL = bundledBinaryURL
        self.bundledManifestURL = bundledManifestURL
    }

    func reconcile() throws -> BundledProxyReconciliationResult {
        try store.reconcileBundledBinary(
            bundledBinaryURL: bundledBinaryURL,
            bundledManifestURL: bundledManifestURL
        )
    }
}
```

Add to `BundledProxyBinary`:

```swift
static func reconciliationService(paths: ManagedPaths = ManagedPaths()) -> BundledProxyReconciliationService {
    BundledProxyReconciliationService(
        store: CLIProxyAPIBinaryStore(paths: paths),
        bundledBinaryURL: url(),
        bundledManifestURL: manifestURL()
    )
}
```

- [ ] **Step 4: Write failing startup orchestration tests**

Extend the `subscriptionUsageViewModel` helper with:

```swift
bundledProxyReconciler: any BundledProxyReconciling = BundledProxyReconcilerDouble(result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!))
```

and pass it to `DashboardViewModel`.

Add:

```swift
func testStartApplicationRestartsRunningServerAfterBundledBinaryChanges() async {
    let config = AppConfig.default
    let proxyService = StubProxyServiceStarter()
    let reconciler = BundledProxyReconcilerDouble(
        result: .installed(
            previousVersion: CLIProxyAPIVersion("7.2.72"),
            newVersion: CLIProxyAPIVersion("7.2.91")!
        )
    )
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(),
        proxyService: proxyService,
        bundledProxyReconciler: reconciler
    )

    await viewModel.startApplication()

    XCTAssertEqual(reconciler.callCount, 1)
    XCTAssertEqual(proxyService.restartPorts, [config.port])
    XCTAssertTrue(proxyService.ports.isEmpty)
}

func testStartApplicationDoesNotRestartWhenBundledBinaryIsUnchanged() async {
    let config = AppConfig.default
    let proxyService = StubProxyServiceStarter()
    let reconciler = BundledProxyReconcilerDouble(
        result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!)
    )
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(),
        proxyService: proxyService,
        bundledProxyReconciler: reconciler
    )

    await viewModel.startApplication()

    XCTAssertTrue(proxyService.restartPorts.isEmpty)
}

func testStartApplicationKeepsRunningAfterBundledReconciliationFailure() async {
    let config = AppConfig.default
    let proxyService = StubProxyServiceStarter()
    let reconciler = BundledProxyReconcilerDouble(error: CocoaError(.fileReadCorruptFile))
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(),
        proxyService: proxyService,
        bundledProxyReconciler: reconciler
    )

    await viewModel.startApplication()

    XCTAssertTrue(proxyService.restartPorts.isEmpty)
    XCTAssertTrue(viewModel.settingsMessage?.contains("Bundled CLIProxyAPI update failed") == true)
}
```

Use the helper’s default successful `ProxyHealthClient` to represent an already-running server. Add this stopped-server test:

```swift
func testStartApplicationDoesNotRestartStoppedServerAfterBundledBinaryChanges() async {
    let config = AppConfig.default
    let proxyService = StubProxyServiceStarter()
    let reconciler = BundledProxyReconcilerDouble(
        result: .installed(
            previousVersion: CLIProxyAPIVersion("7.2.72"),
            newVersion: CLIProxyAPIVersion("7.2.91")!
        )
    )
    let healthClient = ProxyHealthClient(
        httpClient: StubHTTPClient(result: .failure(HTTPClientError.timedOut)),
        timeout: 0.01
    )
    let viewModel = subscriptionUsageViewModel(
        config: config,
        configStore: StubConfigStore(config: config),
        keyStore: SubscriptionUsageManagementKeyDouble(),
        proxyService: proxyService,
        proxyHealthClient: healthClient,
        bundledProxyReconciler: reconciler
    )

    await viewModel.startApplication()

    XCTAssertEqual(reconciler.callCount, 1)
    XCTAssertTrue(proxyService.restartPorts.isEmpty)
    XCTAssertTrue(proxyService.ports.isEmpty)
}
```

The unchanged and failure tests use the default successful health client so they verify that an already-running server is not restarted unless reconciliation actually changes the binary.

- [ ] **Step 5: Implement startup orchestration**

Add to `DashboardViewModel` properties and initializer:

```swift
private let bundledProxyReconciler: any BundledProxyReconciling
```

```swift
bundledProxyReconciler: (any BundledProxyReconciling)? = nil,
```

```swift
self.bundledProxyReconciler = bundledProxyReconciler
    ?? BundledProxyBinary.reconciliationService()
```

Replace `startApplication()` with:

```swift
func startApplication() async {
    await refresh()
    let wasRunning = serverControlState.isRunning
    var attemptedReconciliationRestart = false

    do {
        let result = try bundledProxyReconciler.reconcile()
        if result.didChangeBinary, wasRunning {
            attemptedReconciliationRestart = true
            if !await restartServerAfterRequiredChange() {
                settingsMessage = "Bundled CLIProxyAPI was installed, but the server could not be restarted: \(serverStatus.message)"
            }
        }
    } catch {
        settingsMessage = "Bundled CLIProxyAPI update failed: \(error.localizedDescription)"
    }

    await refresh()
    await prepareSubscriptionUsage()
    if !attemptedReconciliationRestart {
        await performAutostartIfEnabled()
    }
}
```

The `attemptedReconciliationRestart` guard prevents a failed automatic restart from being immediately retried by autostart. Existing subscription-usage configuration repair may still request its own restart because that is a separate required configuration change.

Add the test double:

```swift
private final class BundledProxyReconcilerDouble: BundledProxyReconciling, @unchecked Sendable {
    private let result: BundledProxyReconciliationResult?
    private let error: Error?
    private(set) var callCount = 0

    init(result: BundledProxyReconciliationResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func reconcile() throws -> BundledProxyReconciliationResult {
        callCount += 1
        if let error { throw error }
        return result!
    }
}
```

- [ ] **Step 6: Run app reconciliation tests**

Run:

```bash
swift test --filter BundledProxyReconciliationServiceTests
swift test --filter 'DashboardViewModelTests/testStartApplication'
```

Expected: PASS. Running server restarts exactly once on binary change; unchanged/stopped/error paths do not restart.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLIProxyManagerApp/Services/BundledProxyReconciliationService.swift \
  Sources/CLIProxyManagerApp/BundledProxyBinary.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Tests/CLIProxyManagerAppTests/BundledProxyReconciliationServiceTests.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "feat: reconcile bundled proxy during app startup" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Wire Pending Consent and Reload Update Status

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift:17-22,108-166,222-250`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:199-215`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:422-439`
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift:12-30`
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift:186-215,302-345`
- Modify: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift:130-185`

**Interfaces:**
- Consumes: `CLIProxyAPIBinaryStore.schedulePendingForNextStart()`
- Produces: `CLIProxyAPIUpdateService.schedulePendingForNextServerStart() -> Bool`
- Produces: `CLIProxyAPIUpdateService.reloadStoredStatus()`

- [ ] **Step 1: Write failing update-service tests**

Extend `CLIProxyAPIUpdateBinaryStoring` test double support and add:

```swift
func testSchedulePendingForNextServerStartCallsStoreAndKeepsPendingState() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
    let service = CLIProxyAPIUpdateService(
        paths: paths,
        checker: StubUpdateChecking(release: release("7.2.42")),
        downloader: StubUpdateDownloading(),
        store: store,
        now: { Date() }
    )

    XCTAssertTrue(service.schedulePendingForNextServerStart())

    XCTAssertEqual(store.schedulePendingCallCount, 1)
    XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
    XCTAssertEqual(service.state, .pending)
}

func testSchedulePendingForNextServerStartRecordsFailure() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = StubUpdateBinaryStore(
        currentVersion: "7.2.41",
        pending: manifest("7.2.42"),
        scheduleError: CocoaError(.fileWriteNoPermission)
    )
    let service = CLIProxyAPIUpdateService(
        paths: paths,
        checker: StubUpdateChecking(release: release("7.2.42")),
        downloader: StubUpdateDownloading(),
        store: store,
        now: { Date() }
    )

    XCTAssertFalse(service.schedulePendingForNextServerStart())

    XCTAssertEqual(store.schedulePendingCallCount, 1)
    if case .failed(let message) = service.state {
        XCTAssertFalse(message.isEmpty)
    } else {
        XCTFail("Expected failed state")
    }
}

func testReloadStoredStatusPublishesReconciledActiveAndPendingVersions() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    let store = StubUpdateBinaryStore(currentVersion: "7.2.72", pending: nil)
    let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.92")), downloader: StubUpdateDownloading(), store: store, now: { Date() })
    store.replaceState(currentVersion: "7.2.91", pending: manifest("7.2.92"))

    service.reloadStoredStatus()

    XCTAssertEqual(service.currentVersionText, "7.2.91")
    XCTAssertEqual(service.pendingUpdate?.version, "7.2.92")
}
```

- [ ] **Step 2: Run update-service tests and confirm failures**

Run:

```bash
swift test --filter 'CLIProxyAPIUpdateServiceTests/testSchedulePendingForNextServerStart|CLIProxyAPIUpdateServiceTests/testReloadStoredStatus'
```

Expected: FAIL because the protocol and service methods do not exist.

- [ ] **Step 3: Expose scheduling and reload APIs**

Extend `CLIProxyAPIUpdateBinaryStoring`:

```swift
func schedulePendingForNextStart() throws
```

Add to `CLIProxyAPIUpdateService`:

```swift
@discardableResult
func schedulePendingForNextServerStart() -> Bool {
    refreshStoredStatus()
    guard pendingUpdate != nil else {
        recordFailure(CLIProxyAPIBinaryStoreError.missingPendingManifest)
        return false
    }
    do {
        try store.schedulePendingForNextStart()
        refreshStoredStatus()
        state = .pending
        return true
    } catch {
        recordFailure(error)
        return false
    }
}

func reloadStoredStatus() {
    refreshStoredStatus()
}
```

Extend `StubUpdateBinaryStore` with `scheduleError`, `_schedulePendingCallCount`, a getter, and:

```swift
func schedulePendingForNextStart() throws {
    try lock.withLock {
        _schedulePendingCallCount += 1
        if let scheduleError { throw scheduleError }
    }
}
```

- [ ] **Step 4: Replace message-only pending buttons**

In both `DashboardView` and `GeneralSettingsView`, replace the `Apply on next server start` action with:

```swift
Button("Apply on next server start") {
    if cliProxyAPIUpdateService.schedulePendingForNextServerStart() {
        viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
    } else if case let .failed(message) = cliProxyAPIUpdateService.state {
        viewModel.settingsMessage = "CLIProxyAPI update failed: \(message)"
    }
}
```

Leave the cancel action exactly as:

```swift
Button("Cancel", role: .cancel) {}
```

This preserves pending files without creating the apply-on-next-start marker.

- [ ] **Step 5: Reload status after app startup reconciliation**

Reorder `CLIProxyManagerApp.init()` so the update service local exists before the startup Task:

```swift
init() {
    let config = LaunchAppearanceBootstrapper().applySavedDockVisibility()
    let viewModel = DashboardViewModel(config: config)
    let cliProxyAPIUpdateService = CLIProxyAPIUpdateService()
    _viewModel = StateObject(wrappedValue: viewModel)
    _cliProxyAPIUpdateService = StateObject(wrappedValue: cliProxyAPIUpdateService)
    _usageOverlayWindowController = StateObject(
        wrappedValue: UsageOverlayWindowController(
            viewModel: viewModel,
            placementPersistence: .userDefaults()
        )
    )
    Task {
        await viewModel.startApplication()
        cliProxyAPIUpdateService.reloadStoredStatus()
    }
    _quitCoordinator = StateObject(wrappedValue: QuitCoordinator(shouldStopServerBeforeQuit: {
        viewModel.serverControlState.shouldStopServerBeforeQuit
    }))
    _updaterService = StateObject(wrappedValue: UpdaterService())
}
```

Do not initialize `_cliProxyAPIUpdateService` a second time later in the initializer.

- [ ] **Step 6: Update UI wiring tests**

Replace the old assertions that only checked the status message with assertions that both view sources contain:

```swift
"cliProxyAPIUpdateService.schedulePendingForNextServerStart()"
```

Keep/assert:

```swift
"Button(\"Cancel\", role: .cancel) {}"
```

Add startup ordering assertions:

```swift
let appSource = try String(
    contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift"),
    encoding: .utf8
)
let startRange = try XCTUnwrap(appSource.range(of: "await viewModel.startApplication()"))
let reloadRange = try XCTUnwrap(appSource.range(of: "cliProxyAPIUpdateService.reloadStoredStatus()"))
XCTAssertLessThan(startRange.lowerBound, reloadRange.lowerBound)
```

- [ ] **Step 7: Run update and UI tests**

Run:

```bash
swift test --filter CLIProxyAPIUpdateServiceTests
swift test --filter CLIProxyAPIUpdateUITests
```

Expected: PASS. `Apply on next server start` records consent; `Cancel` does not; app startup reload occurs after reconciliation.

- [ ] **Step 8: Commit**

```bash
git add Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git commit -m "fix: persist pending proxy apply choice" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Verify the Integrated Update Flow

**Files:**
- Modify only if verification reveals a defect in files already listed above.

**Interfaces:**
- Consumes all prior task outputs.
- Produces a verified development build and clean implementation diff.

- [ ] **Step 1: Run all focused regression suites together**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
swift test --filter BundledProxyReconciliationServiceTests
swift test --filter 'DashboardViewModelTests/testStartApplication'
swift test --filter CLIProxyAPIUpdateServiceTests
swift test --filter CLIProxyAPIUpdateUITests
```

Expected: every command exits 0 with all selected tests passing.

- [ ] **Step 2: Run the complete test suite**

Run:

```bash
swift test
```

Expected: exit 0 and `All tests` passed. If any unrelated test fails, report its exact name and output before changing code.

- [ ] **Step 3: Build the development app product**

Run:

```bash
swift build -c debug --product CLIProxyManager
```

Expected: exit 0 and `Build complete!`.

- [ ] **Step 4: Inspect the final diff and repository state**

Run:

```bash
git diff --check
git status --short --branch
git diff HEAD~3 --stat
git log --oneline -5
```

Expected:

- `git diff --check` prints nothing.
- Only intended source, test, spec, and plan files are changed/committed.
- No generated `.build` artifacts are tracked.
- The implementation is represented by focused commits from Tasks 1–4.

- [ ] **Step 5: Perform a requirements audit**

Confirm from tests and code paths:

1. Active 7.2.72 + bundled 7.2.91 reconciles to active 7.2.91 on app start.
2. A running server restarts after that binary change.
3. Active 7.2.92 is not downgraded by bundled 7.2.91.
4. Unscheduled pending 7.2.92 remains pending across app startup and ordinary server restart.
5. `Apply on next server start` creates the marker and the next server prepare applies pending.
6. `Cancel` creates no marker.
7. Invalid bundle leaves active binary and running server untouched.
8. CLIProxyAPI update UI reloads the final active and pending versions.

Expected: each item maps to at least one passing automated test.

- [ ] **Step 6: Commit any verification-only correction, if one was required**

Only when Steps 1–5 required a code correction, commit that isolated correction:

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift \
  Sources/CLIProxyManagerApp/Services/BundledProxyReconciliationService.swift \
  Sources/CLIProxyManagerApp/BundledProxyBinary.swift \
  Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift \
  Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift \
  Tests/CLIProxyManagerAppTests/BundledProxyReconciliationServiceTests.swift \
  Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git diff --cached --check
git commit -m "fix: complete bundled proxy reconciliation" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

If no correction was required, do not create an empty commit.

- [ ] **Step 7: Hand off manual verification**

Report the development build path from:

```bash
swift build -c debug --show-bin-path
```

Ask the user to perform the project-owned manual check:

1. Install an older active CLIProxyAPI under `~/.cliproxy-manager/cliproxyapi`.
2. Launch the development app containing a newer bundled version.
3. Confirm the displayed current version updates without pressing server restart.
4. If the server was already running, confirm its process start time changes and it reports the bundled/newer version.
5. Download a newer pending version, press `Cancel`, restart the server, and confirm it remains pending.
6. Select `Apply on next server start`, restart, and confirm the pending version becomes active.

Do not launch the app or claim manual UI behavior was verified automatically.
