# CLIProxyAPI Binary Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 배포 없이 CLIProxyManager가 상류 GitHub Releases에서 새 CLIProxyAPI macOS arm64 바이너리를 확인하고, 사용자 승인 후 검증·저장·즉시 적용 또는 다음 실행 적용을 지원한다.

**Architecture:** Core 레이어에 version/manifest/store/release-client를 추가해 파일 시스템, checksum, release 파싱, pending→active 승격을 분리한다. App 레이어의 `CLIProxyAPIUpdateService`는 자동/수동 확인, UI 상태, 사용자 선택 흐름만 조율한다. `ProxyServiceManager.prepare()`는 pending 승격과 bundled/user-updated 우선순위를 적용해 사용자 업데이트 바이너리를 번들 버전으로 되돌리지 않는다.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation `URLSession`, 기존 `HTTPClient`, 기존 `ProcessRunner`, Swift Package Manager, XCTest, GitHub Releases API.

## Global Constraints

- 지원 플랫폼은 기존과 동일하게 macOS 15 이상이다.
- 상류 저장소는 `router-for-me/CLIProxyAPI`다.
- stable latest release만 확인한다. prerelease, beta, nightly 채널은 지원하지 않는다.
- macOS arm64 asset 이름은 `CLIProxyAPI_<version>_darwin_aarch64.tar.gz` 형식을 기대한다.
- checksum 검증은 상류 `checksums.txt` 기준으로 수행한다.
- 사용자의 명시 승인 없이 CLIProxyAPI 바이너리를 자동 교체하지 않는다.
- 자동 확인은 앱 실행 시 백그라운드로 수행하고, 이후 24시간에 한 번만 수행한다.
- 수동 확인은 24시간 제한을 무시한다.
- “다음 실행에 적용”은 현재 실행 중인 서버를 건드리지 않는다.
- 기존 Sparkle 앱 업데이트 흐름은 변경하지 않는다.
- 기존 `scripts/vendor-cliproxyapi.sh`는 앱 번들 기본 바이너리 갱신용으로 유지한다.

---

## File Structure

- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIVersion.swift`
  - Semantic version parsing/comparison. `v` prefix를 정규화하고 prerelease/잘못된 버전을 stable 비교 대상에서 제외한다.
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift`
  - active/pending/bundled manifest schema와 JSON encode/decode.
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
  - active/pending 파일 경로 관리, manifest 검증, pending 저장, active 승격, bundled/user-updated 우선순위 적용.
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - active manifest, pending binary/manifest, update-state 경로 노출.
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
  - `installBundledBinaryIfNeeded()`를 store 기반 prepare로 교체.
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift`
  - GitHub latest release JSON과 `checksums.txt` 파싱, macOS arm64 asset metadata 산출.
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`
  - archive sha256 검증, tar 해제, `--version` metadata 파싱, pending manifest 생성용 검증 결과 산출.
- Create: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
  - 자동/수동 확인, 24시간 scheduling, published UI 상태, update-state 저장, 다운로드·검증·적용 orchestration.
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
  - `CLIProxyAPIUpdateService`를 `@StateObject`로 생성해 main/settings UI에 주입.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - 앱 실행 시 자동 확인 시작, 새 버전 발견/적용 방식 confirmation dialog 표시.
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
  - server settings에 update service 전달.
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - `ServerSettingsView`에 CLIProxyAPI binary row 추가.
- Modify: `README.md`
  - 앱 업데이트와 CLIProxyAPI 바이너리 업데이트 분리, checksum 검증, 적용 방식 설명.
- Add tests under `Tests/CLIProxyManagerCoreTests/` and `Tests/CLIProxyManagerAppTests/` for each unit.

---

### Task 1: Core path, version, and manifest primitives

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIVersion.swift`
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIVersionTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryManifestTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

**Interfaces:**
- Produces: `public struct CLIProxyAPIVersion: Comparable, Codable, Sendable`
- Produces: `public init?(_ rawValue: String)` on `CLIProxyAPIVersion`
- Produces: `public struct CLIProxyAPIBinaryManifest: Codable, Equatable, Sendable`
- Produces: `public enum CLIProxyAPIBinarySourceKind: String, Codable, Sendable { case bundled, userUpdated = "user-updated" }`
- Produces: `ManagedPaths.activeClipProxyManifest`, `pendingClipProxyDirectory`, `pendingClipProxyBinary`, `pendingClipProxyManifest`, `clipProxyUpdateStateFile`

- [ ] **Step 1: Write failing path tests**

Add this test to `ProxyServiceManagerTests` near the existing `testManagedPathsExposeAppManagedAuthDirectory`:

```swift
func testManagedPathsExposeCLIProxyAPIUpdatePaths() throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))

    XCTAssertEqual(paths.activeClipProxyManifest, sandbox.appendingPathComponent("managed/cliproxyapi/active-manifest.json"))
    XCTAssertEqual(paths.pendingClipProxyDirectory, sandbox.appendingPathComponent("managed/cliproxyapi/pending", isDirectory: true))
    XCTAssertEqual(paths.pendingClipProxyBinary, sandbox.appendingPathComponent("managed/cliproxyapi/pending/cliproxyapi"))
    XCTAssertEqual(paths.pendingClipProxyManifest, sandbox.appendingPathComponent("managed/cliproxyapi/pending/manifest.json"))
    XCTAssertEqual(paths.clipProxyUpdateStateFile, sandbox.appendingPathComponent("managed/cliproxyapi/update-state.json"))
}
```

- [ ] **Step 2: Run path test and verify it fails**

Run:

```bash
swift test --filter ProxyServiceManagerTests/testManagedPathsExposeCLIProxyAPIUpdatePaths
```

Expected: compile fails because `ManagedPaths` does not expose the new properties.

- [ ] **Step 3: Add ManagedPaths properties**

In `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`, add these computed properties after `clipProxyBinary`:

```swift
public var activeClipProxyManifest: URL {
    clipProxyDirectory.appendingPathComponent("active-manifest.json")
}

public var pendingClipProxyDirectory: URL {
    clipProxyDirectory.appendingPathComponent("pending", isDirectory: true)
}

public var pendingClipProxyBinary: URL {
    pendingClipProxyDirectory.appendingPathComponent("cliproxyapi")
}

public var pendingClipProxyManifest: URL {
    pendingClipProxyDirectory.appendingPathComponent("manifest.json")
}

public var clipProxyUpdateStateFile: URL {
    clipProxyDirectory.appendingPathComponent("update-state.json")
}
```

- [ ] **Step 4: Run path test and verify it passes**

Run:

```bash
swift test --filter ProxyServiceManagerTests/testManagedPathsExposeCLIProxyAPIUpdatePaths
```

Expected: PASS.

- [ ] **Step 5: Write failing version tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyAPIVersionTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedStableVersions() {
        XCTAssertEqual(CLIProxyAPIVersion("7.2.41")?.description, "7.2.41")
        XCTAssertEqual(CLIProxyAPIVersion("v7.2.41")?.description, "7.2.41")
    }

    func testComparesSemanticVersionsNumerically() throws {
        let old = try XCTUnwrap(CLIProxyAPIVersion("7.2.9"))
        let new = try XCTUnwrap(CLIProxyAPIVersion("7.2.10"))
        XCTAssertLessThan(old, new)
    }

    func testRejectsPrereleaseAndMalformedVersions() {
        XCTAssertNil(CLIProxyAPIVersion("7.2.41-beta.1"))
        XCTAssertNil(CLIProxyAPIVersion("latest"))
        XCTAssertNil(CLIProxyAPIVersion("7.2"))
    }
}
```

- [ ] **Step 6: Run version tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIVersionTests
```

Expected: compile fails because `CLIProxyAPIVersion` does not exist.

- [ ] **Step 7: Implement CLIProxyAPIVersion**

Create `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIVersion.swift`:

```swift
import Foundation

public struct CLIProxyAPIVersion: Codable, Comparable, CustomStringConvertible, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ rawValue: String) {
        let normalized = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0,
              minor >= 0,
              patch >= 0,
              String(major) == parts[0],
              String(minor) == parts[1],
              String(patch) == parts[2] else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: CLIProxyAPIVersion, rhs: CLIProxyAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 8: Run version tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIVersionTests
```

Expected: PASS.

- [ ] **Step 9: Write failing manifest tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryManifestTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIBinaryManifestTests: XCTestCase {
    func testDecodesExistingBundledManifestWithDefaultSourceKind() throws {
        let json = Data("""
        {
          "name": "cliproxyapi",
          "version": "7.2.41",
          "commit": "65f2288a",
          "builtAt": "2026-06-25T17:56:53Z",
          "source": "https://example.com/archive.tar.gz",
          "upstreamRepository": "router-for-me/CLIProxyAPI",
          "upstreamTag": "v7.2.41",
          "upstreamAsset": "CLIProxyAPI_7.2.41_darwin_aarch64.tar.gz",
          "upstreamAssetSha256": "archive-sha",
          "vendoredBinaryName": "cliproxyapi",
          "vendoredBinarySha256": "binary-sha",
          "vendoredBinarySizeBytes": 123,
          "vendoredFromArchivePath": "cli-proxy-api"
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: json)

        XCTAssertEqual(manifest.version, "7.2.41")
        XCTAssertEqual(manifest.sourceKind, .bundled)
        XCTAssertEqual(manifest.parsedVersion?.description, "7.2.41")
    }

    func testEncodesUserUpdatedManifestWithSourceKindAndDates() throws {
        let manifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: "7.2.42",
            commit: "abcdef12",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: .userUpdated,
            source: "https://example.com/archive.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v7.2.42",
            upstreamAsset: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive-sha",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: "binary-sha",
            vendoredBinarySizeBytes: 456,
            vendoredFromArchivePath: "cli-proxy-api",
            downloadedAt: "2026-07-01T00:05:00Z",
            appliedAt: "2026-07-01T00:06:00Z"
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.sourceKind, .userUpdated)
    }
}
```

- [ ] **Step 10: Run manifest tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIBinaryManifestTests
```

Expected: compile fails because manifest types do not exist.

- [ ] **Step 11: Implement manifest types**

Create `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift`:

```swift
import Foundation

public enum CLIProxyAPIBinarySourceKind: String, Codable, Equatable, Sendable {
    case bundled
    case userUpdated = "user-updated"
}

public struct CLIProxyAPIBinaryManifest: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var commit: String
    public var builtAt: String
    public var sourceKind: CLIProxyAPIBinarySourceKind
    public var source: String
    public var upstreamRepository: String
    public var upstreamTag: String
    public var upstreamAsset: String
    public var upstreamAssetSha256: String
    public var vendoredBinaryName: String
    public var vendoredBinarySha256: String
    public var vendoredBinarySizeBytes: Int
    public var vendoredFromArchivePath: String
    public var downloadedAt: String?
    public var appliedAt: String?

    public init(
        name: String,
        version: String,
        commit: String,
        builtAt: String,
        sourceKind: CLIProxyAPIBinarySourceKind,
        source: String,
        upstreamRepository: String,
        upstreamTag: String,
        upstreamAsset: String,
        upstreamAssetSha256: String,
        vendoredBinaryName: String,
        vendoredBinarySha256: String,
        vendoredBinarySizeBytes: Int,
        vendoredFromArchivePath: String,
        downloadedAt: String? = nil,
        appliedAt: String? = nil
    ) {
        self.name = name
        self.version = version
        self.commit = commit
        self.builtAt = builtAt
        self.sourceKind = sourceKind
        self.source = source
        self.upstreamRepository = upstreamRepository
        self.upstreamTag = upstreamTag
        self.upstreamAsset = upstreamAsset
        self.upstreamAssetSha256 = upstreamAssetSha256
        self.vendoredBinaryName = vendoredBinaryName
        self.vendoredBinarySha256 = vendoredBinarySha256
        self.vendoredBinarySizeBytes = vendoredBinarySizeBytes
        self.vendoredFromArchivePath = vendoredFromArchivePath
        self.downloadedAt = downloadedAt
        self.appliedAt = appliedAt
    }

    public var parsedVersion: CLIProxyAPIVersion? {
        CLIProxyAPIVersion(version)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, commit, builtAt, sourceKind, source
        case upstreamRepository, upstreamTag, upstreamAsset, upstreamAssetSha256
        case vendoredBinaryName, vendoredBinarySha256, vendoredBinarySizeBytes, vendoredFromArchivePath
        case downloadedAt, appliedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.commit = try c.decode(String.self, forKey: .commit)
        self.builtAt = try c.decode(String.self, forKey: .builtAt)
        self.sourceKind = try c.decodeIfPresent(CLIProxyAPIBinarySourceKind.self, forKey: .sourceKind) ?? .bundled
        self.source = try c.decode(String.self, forKey: .source)
        self.upstreamRepository = try c.decode(String.self, forKey: .upstreamRepository)
        self.upstreamTag = try c.decode(String.self, forKey: .upstreamTag)
        self.upstreamAsset = try c.decode(String.self, forKey: .upstreamAsset)
        self.upstreamAssetSha256 = try c.decode(String.self, forKey: .upstreamAssetSha256)
        self.vendoredBinaryName = try c.decode(String.self, forKey: .vendoredBinaryName)
        self.vendoredBinarySha256 = try c.decode(String.self, forKey: .vendoredBinarySha256)
        self.vendoredBinarySizeBytes = try c.decode(Int.self, forKey: .vendoredBinarySizeBytes)
        self.vendoredFromArchivePath = try c.decode(String.self, forKey: .vendoredFromArchivePath)
        self.downloadedAt = try c.decodeIfPresent(String.self, forKey: .downloadedAt)
        self.appliedAt = try c.decodeIfPresent(String.self, forKey: .appliedAt)
    }
}
```

- [ ] **Step 12: Run primitive tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIVersionTests
swift test --filter CLIProxyAPIBinaryManifestTests
swift test --filter ProxyServiceManagerTests/testManagedPathsExposeCLIProxyAPIUpdatePaths
```

Expected: all PASS.

- [ ] **Step 13: Commit Task 1**

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIVersion.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryManifest.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIVersionTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryManifestTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "Add CLIProxyAPI binary update primitives" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Binary store and ProxyServiceManager integration

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
- Modify: `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`
- Modify test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift`

**Interfaces:**
- Consumes: `CLIProxyAPIVersion`, `CLIProxyAPIBinaryManifest`, new `ManagedPaths` properties.
- Produces: `public enum CLIProxyAPIBinaryStoreError: Error, Equatable`
- Produces: `public struct CLIProxyAPIBinaryStore: Sendable`
- Produces: `public func prepareActiveBinary(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws`
- Produces: `public func activeManifest() throws -> CLIProxyAPIBinaryManifest?`
- Produces: `public func pendingManifest() throws -> CLIProxyAPIBinaryManifest?`
- Produces: `public func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws`
- Produces: `public func applyPending() throws`

- [ ] **Step 1: Write failing store tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`:

```swift
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
        let store = CLIProxyAPIBinaryStore(paths: paths)

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
        let pendingManifest = manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: sha256(pendingBinary), size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: pendingManifest)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho pending\n")
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingClipProxyBinary.path))
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
        let store = CLIProxyAPIBinaryStore(paths: paths)

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
        let store = CLIProxyAPIBinaryStore(paths: paths)

        try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(try store.activeManifest()?.sourceKind, .bundled)
        XCTAssertEqual(try store.activeManifest()?.version, "7.2.42")
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
        let badManifest = manifest(version: "7.2.42", sourceKind: .userUpdated, binarySha: "bad-sha", size: fileSize(pendingBinary))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        try store.savePending(binaryURL: pendingBinary, manifest: badManifest, validate: false)

        XCTAssertThrowsError(try store.prepareActiveBinary(bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifest)) { error in
            XCTAssertEqual(error as? CLIProxyAPIBinaryStoreError, .binaryChecksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
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

    private func writeManifest(version: String, sourceKind: CLIProxyAPIBinarySourceKind, binarySha: String, size: Int, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest(version: version, sourceKind: sourceKind, binarySha: binarySha, size: size))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func manifest(version: String, sourceKind: CLIProxyAPIBinarySourceKind, binarySha: String, size: Int) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: version,
            commit: "commit-\(version)",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: sourceKind,
            source: "https://example.com/CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v\(version)",
            upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive-sha-\(version)",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: binarySha,
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api"
        )
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return data.sha256HexDigest()
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }
}
```

- [ ] **Step 2: Add a small SHA-256 helper for tests and implementation**

Because both tests and store need the same hash operation, add this internal extension at the bottom of `CLIProxyAPIBinaryStore.swift` in Step 4, not in tests:

```swift
import CryptoKit

extension Data {
    func sha256HexDigest() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
```

If `CryptoKit` import creates a platform issue, use the existing `/usr/bin/shasum` only inside tests and store. Prefer `CryptoKit` because macOS 15 supports it and avoids process spawning for hashing.

- [ ] **Step 3: Run store tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
```

Expected: compile fails because `CLIProxyAPIBinaryStore` and `Data.sha256HexDigest()` do not exist.

- [ ] **Step 4: Implement CLIProxyAPIBinaryStore**

Create `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift` with these public signatures and behavior:

```swift
import CryptoKit
import Foundation

public enum CLIProxyAPIBinaryStoreError: Error, Equatable {
    case missingBundledBinary
    case missingBundledManifest
    case invalidManifestVersion(String)
    case binaryChecksumMismatch
    case binarySizeMismatch
    case missingPendingBinary
    case missingPendingManifest
}

public struct CLIProxyAPIBinaryStore: Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ManagedPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func activeManifest() throws -> CLIProxyAPIBinaryManifest? {
        try readManifestIfExists(paths.activeClipProxyManifest)
    }

    public func pendingManifest() throws -> CLIProxyAPIBinaryManifest? {
        try readManifestIfExists(paths.pendingClipProxyManifest)
    }

    public func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        try savePending(binaryURL: binaryURL, manifest: manifest, validate: true)
    }

    public func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest, validate: Bool) throws {
        if validate {
            try validateBinary(at: binaryURL, manifest: manifest)
        }
        try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
        try replaceFile(from: binaryURL, to: paths.pendingClipProxyBinary)
        try writeManifest(manifest, to: paths.pendingClipProxyManifest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.pendingClipProxyBinary.path)
    }

    public func applyPending() throws {
        guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) else { throw CLIProxyAPIBinaryStoreError.missingPendingBinary }
        guard var manifest = try pendingManifest() else { throw CLIProxyAPIBinaryStoreError.missingPendingManifest }
        try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
        manifest.appliedAt = Self.iso8601Now()
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        let backup = paths.clipProxyDirectory.appendingPathComponent("cliproxyapi.backup")
        if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: paths.clipProxyBinary, to: backup)
        }
        do {
            try fileManager.moveItem(at: paths.pendingClipProxyBinary, to: paths.clipProxyBinary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
            try writeManifest(manifest, to: paths.activeClipProxyManifest)
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                try? fileManager.moveItem(at: backup, to: paths.clipProxyBinary)
            }
            throw error
        }
    }

    public func prepareActiveBinary(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws {
        if fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) || fileManager.fileExists(atPath: paths.pendingClipProxyManifest.path) {
            try applyPending()
            return
        }

        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            if fileManager.fileExists(atPath: paths.clipProxyBinary.path) { return }
            throw CLIProxyAPIBinaryStoreError.missingBundledBinary
        }
        guard let bundledManifestURL, let bundledManifest = try readManifestIfExists(bundledManifestURL) else {
            throw CLIProxyAPIBinaryStoreError.missingBundledManifest
        }
        guard let bundledVersion = bundledManifest.parsedVersion else {
            throw CLIProxyAPIBinaryStoreError.invalidManifestVersion(bundledManifest.version)
        }

        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path), let active = try activeManifest() else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            return
        }
        guard let activeVersion = active.parsedVersion else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            return
        }

        switch active.sourceKind {
        case .bundled:
            if activeVersion < bundledVersion || try !binaryMatches(paths.clipProxyBinary, manifest: active) {
                try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            }
        case .userUpdated:
            if activeVersion < bundledVersion {
                try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            }
        }
    }

    private func installBundled(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        try replaceFile(from: binaryURL, to: paths.clipProxyBinary)
        var active = manifest
        active.sourceKind = .bundled
        active.appliedAt = Self.iso8601Now()
        try writeManifest(active, to: paths.activeClipProxyManifest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
    }

    private func readManifestIfExists(_ url: URL) throws -> CLIProxyAPIBinaryManifest? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(CLIProxyAPIBinaryManifest.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ manifest: CLIProxyAPIBinaryManifest, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func validateBinary(at url: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        if try Data(contentsOf: url).sha256HexDigest() != manifest.vendoredBinarySha256 {
            throw CLIProxyAPIBinaryStoreError.binaryChecksumMismatch
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        if size != manifest.vendoredBinarySizeBytes {
            throw CLIProxyAPIBinaryStoreError.binarySizeMismatch
        }
    }

    private func binaryMatches(_ url: URL, manifest: CLIProxyAPIBinaryManifest) throws -> Bool {
        do {
            try validateBinary(at: url, manifest: manifest)
            return true
        } catch {
            return false
        }
    }

    private func replaceFile(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: source, to: temporary)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

extension Data {
    func sha256HexDigest() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run store tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
```

Expected: PASS.

- [ ] **Step 6: Write failing ProxyServiceManager integration test**

Add this to `ProxyServiceManagerTests` near bundled binary tests:

```swift
func testStartKeepsUserUpdatedBinaryWhenBundledBinaryIsOlder() async throws {
    let sandbox = try makeSandbox()
    let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
    try createBinary(at: paths.clipProxyBinary, contents: "#!/bin/sh\necho active\n")
    let activeManifest = CLIProxyAPIBinaryManifest(
        name: "cliproxyapi",
        version: "7.2.42",
        commit: "active",
        builtAt: "2026-07-01T00:00:00Z",
        sourceKind: .userUpdated,
        source: "https://example.com/active.tar.gz",
        upstreamRepository: "router-for-me/CLIProxyAPI",
        upstreamTag: "v7.2.42",
        upstreamAsset: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
        upstreamAssetSha256: "archive",
        vendoredBinaryName: "cliproxyapi",
        vendoredBinarySha256: try Data(contentsOf: paths.clipProxyBinary).sha256HexDigest(),
        vendoredBinarySizeBytes: try XCTUnwrap(paths.clipProxyBinary.resourceValues(forKeys: [.fileSizeKey]).fileSize),
        vendoredFromArchivePath: "cli-proxy-api"
    )
    try JSONEncoder().encode(activeManifest).write(to: paths.activeClipProxyManifest)
    let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
    let bundledManifestURL = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
    try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho bundled\n")
    let bundledManifest = CLIProxyAPIBinaryManifest(
        name: "cliproxyapi",
        version: "7.2.41",
        commit: "bundled",
        builtAt: "2026-06-25T17:56:53Z",
        sourceKind: .bundled,
        source: "https://example.com/bundled.tar.gz",
        upstreamRepository: "router-for-me/CLIProxyAPI",
        upstreamTag: "v7.2.41",
        upstreamAsset: "CLIProxyAPI_7.2.41_darwin_aarch64.tar.gz",
        upstreamAssetSha256: "archive",
        vendoredBinaryName: "cliproxyapi",
        vendoredBinarySha256: try Data(contentsOf: bundledBinary).sha256HexDigest(),
        vendoredBinarySizeBytes: try XCTUnwrap(bundledBinary.resourceValues(forKeys: [.fileSizeKey]).fileSize),
        vendoredFromArchivePath: "cli-proxy-api"
    )
    try FileManager.default.createDirectory(at: bundledManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(bundledManifest).write(to: bundledManifestURL)
    let launcher = FakeProcessLauncher()
    let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifestURL, launcher: launcher)

    try await manager.start(port: 8317)

    XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho active\n")
    XCTAssertEqual(launcher.invocations.first?.executable, paths.clipProxyBinary.path)
}
```

- [ ] **Step 7: Run integration test and verify it fails**

Run:

```bash
swift test --filter ProxyServiceManagerTests/testStartKeepsUserUpdatedBinaryWhenBundledBinaryIsOlder
```

Expected: compile fails because `ProxyServiceManager` initializer does not accept `bundledManifestURL`.

- [ ] **Step 8: Integrate store into ProxyServiceManager**

Modify `Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift`:

1. Add stored properties:

```swift
private let bundledManifestURL: URL?
private let binaryStore: CLIProxyAPIBinaryStore
```

2. Update public initializer signature:

```swift
public init(
    paths: ManagedPaths,
    bundledBinaryURL: URL? = nil,
    bundledManifestURL: URL? = nil,
    launcher: any ProcessLaunching = ProcessLauncher(),
    fileManager: FileManager = .default
)
```

3. Thread `bundledManifestURL` through the internal initializer and initialize:

```swift
self.bundledManifestURL = bundledManifestURL
self.binaryStore = CLIProxyAPIBinaryStore(paths: paths, fileManager: fileManager)
```

4. Replace the body of `installBundledBinaryIfNeeded()` with:

```swift
private func installBundledBinaryIfNeeded() throws {
    do {
        try binaryStore.prepareActiveBinary(
            bundledBinaryURL: bundledBinaryURL,
            bundledManifestURL: bundledManifestURL
        )
    } catch CLIProxyAPIBinaryStoreError.missingBundledBinary {
        if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
            return
        }
        throw ProxyServiceError.missingBinary(paths.clipProxyBinary.path)
    } catch {
        throw error
    }
}
```

5. Keep existing behavior where an already-installed binary allows startup even if the app has no bundled binary URL.

- [ ] **Step 9: Update BundledProxyBinary to pass manifest URL**

Modify `Sources/CLIProxyManagerApp/BundledProxyBinary.swift`:

```swift
static func manifestURL(bundle: Bundle? = nil, appBundle: Bundle = .main) -> URL? {
    if let url = appBundle.url(forResource: "cliproxyapi", withExtension: "manifest.json", subdirectory: "cliproxyapi") {
        return url
    }
    return (bundle ?? .module).url(forResource: "cliproxyapi", withExtension: "manifest.json", subdirectory: "cliproxyapi")
}

static func serviceManager(paths: ManagedPaths = ManagedPaths()) -> ProxyServiceManager {
    ProxyServiceManager(paths: paths, bundledBinaryURL: url(), bundledManifestURL: manifestURL())
}
```

- [ ] **Step 10: Run integration and existing proxy tests**

Run:

```bash
swift test --filter ProxyServiceManagerTests
swift test --filter CLIProxyAPIBinaryStoreTests
```

Expected: PASS.

- [ ] **Step 11: Commit Task 2**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift \
  Sources/CLIProxyManagerCore/Proxy/ProxyServiceManager.swift \
  Sources/CLIProxyManagerApp/BundledProxyBinary.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift \
  Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift
git commit -m "Add CLIProxyAPI binary store" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 3: GitHub release client and archive verifier

**Files:**
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift`
- Create: `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift`

**Interfaces:**
- Consumes: existing `HTTPClient`, existing `ProcessRunning`, `CLIProxyAPIVersion`, `CLIProxyAPIBinaryManifest`, `CLIProxyAPIBinaryStore`.
- Produces: `public struct CLIProxyAPIRelease: Equatable, Sendable`
- Produces: `public enum CLIProxyAPIReleaseClientError: Error, Equatable`
- Produces: `public struct CLIProxyAPIReleaseClient: Sendable`
- Produces: `public func latestRelease() async throws -> CLIProxyAPIRelease`
- Produces: `public func downloadArchive(for release: CLIProxyAPIRelease) async throws -> Data`
- Produces: `public struct CLIProxyAPIArchiveVerifier: Sendable`
- Produces: `public func verify(archiveData: Data, release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult`

- [ ] **Step 1: Write failing release client tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift`:

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyAPIReleaseClientTests: XCTestCase {
    func testParsesLatestReleaseAndChecksumForDarwinArm64Asset() async throws {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let checksumURL = URL(string: "https://downloads.example/checksums.txt")!
        let archiveURL = URL(string: "https://downloads.example/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            {
              "tag_name": "v7.2.42",
              "prerelease": false,
              "assets": [
                { "name": "checksums.txt", "browser_download_url": "\(checksumURL.absoluteString)" },
                { "name": "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz", "browser_download_url": "\(archiveURL.absoluteString)" }
              ]
            }
            """.utf8),
            checksumURL: Data("archive-sha  CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz\n".utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        let release = try await client.latestRelease()

        XCTAssertEqual(release.version.description, "7.2.42")
        XCTAssertEqual(release.tagName, "v7.2.42")
        XCTAssertEqual(release.assetName, "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")
        XCTAssertEqual(release.assetURL, archiveURL)
        XCTAssertEqual(release.assetSha256, "archive-sha")
        XCTAssertEqual(http.requestedURLs, [latestURL, checksumURL])
    }

    func testRejectsPrereleaseLatestRelease() async {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            { "tag_name": "v7.2.42", "prerelease": true, "assets": [] }
            """.utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        await XCTAssertThrowsErrorAsync(try await client.latestRelease()) { error in
            XCTAssertEqual(error as? CLIProxyAPIReleaseClientError, .prereleaseUnsupported("v7.2.42"))
        }
    }

    func testReportsMissingDarwinArm64Asset() async {
        let latestURL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        let http = StubReleaseHTTPClient(responses: [
            latestURL: Data("""
            { "tag_name": "v7.2.42", "prerelease": false, "assets": [{ "name": "checksums.txt", "browser_download_url": "https://downloads.example/checksums.txt" }] }
            """.utf8)
        ])
        let client = CLIProxyAPIReleaseClient(httpClient: http)

        await XCTAssertThrowsErrorAsync(try await client.latestRelease()) { error in
            XCTAssertEqual(error as? CLIProxyAPIReleaseClientError, .missingAsset("CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz"))
        }
    }

    func testDownloadsArchiveDataFromReleaseAssetURL() async throws {
        let archiveURL = URL(string: "https://downloads.example/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz")!
        let data = Data("archive".utf8)
        let http = StubReleaseHTTPClient(responses: [archiveURL: data])
        let client = CLIProxyAPIReleaseClient(httpClient: http)
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: archiveURL,
            assetSha256: data.sha256HexDigest()
        )

        let downloaded = try await client.downloadArchive(for: release)

        XCTAssertEqual(downloaded, data)
    }
}

private final class StubReleaseHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [URL: Data]
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] { lock.withLock { _requestedURLs } }

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        lock.withLock { _requestedURLs.append(url) }
        guard let data = responses[url] else { throw HTTPClientError.badStatus(404) }
        return data
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
```

- [ ] **Step 2: Run release client tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIReleaseClientTests
```

Expected: compile fails because release client types do not exist.

- [ ] **Step 3: Implement release client**

Create `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift`:

```swift
import Foundation

public struct CLIProxyAPIRelease: Equatable, Sendable {
    public let version: CLIProxyAPIVersion
    public let tagName: String
    public let assetName: String
    public let assetURL: URL
    public let assetSha256: String

    public init(version: CLIProxyAPIVersion, tagName: String, assetName: String, assetURL: URL, assetSha256: String) {
        self.version = version
        self.tagName = tagName
        self.assetName = assetName
        self.assetURL = assetURL
        self.assetSha256 = assetSha256
    }
}

public enum CLIProxyAPIReleaseClientError: Error, Equatable {
    case invalidVersion(String)
    case prereleaseUnsupported(String)
    case missingAsset(String)
    case missingChecksumAsset
    case missingChecksumEntry(String)
    case invalidAssetURL(String)
}

public struct CLIProxyAPIReleaseClient: Sendable {
    private let httpClient: any HTTPClient
    private let latestReleaseURL: URL

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
    ) {
        self.httpClient = httpClient
        self.latestReleaseURL = latestReleaseURL
    }

    public func latestRelease() async throws -> CLIProxyAPIRelease {
        let data = try await httpClient.get(latestReleaseURL, headers: ["Accept": "application/vnd.github+json"])
        let githubRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = CLIProxyAPIVersion(githubRelease.tagName) else {
            throw CLIProxyAPIReleaseClientError.invalidVersion(githubRelease.tagName)
        }
        guard githubRelease.prerelease == false else {
            throw CLIProxyAPIReleaseClientError.prereleaseUnsupported(githubRelease.tagName)
        }
        let assetName = "CLIProxyAPI_\(version.description)_darwin_aarch64.tar.gz"
        guard let archiveAsset = githubRelease.assets.first(where: { $0.name == assetName }) else {
            throw CLIProxyAPIReleaseClientError.missingAsset(assetName)
        }
        guard let checksumAsset = githubRelease.assets.first(where: { $0.name == "checksums.txt" }) else {
            throw CLIProxyAPIReleaseClientError.missingChecksumAsset
        }
        guard let archiveURL = URL(string: archiveAsset.browserDownloadURL) else {
            throw CLIProxyAPIReleaseClientError.invalidAssetURL(archiveAsset.browserDownloadURL)
        }
        guard let checksumURL = URL(string: checksumAsset.browserDownloadURL) else {
            throw CLIProxyAPIReleaseClientError.invalidAssetURL(checksumAsset.browserDownloadURL)
        }
        let checksums = try await httpClient.get(checksumURL, headers: [:])
        guard let assetSha = Self.checksum(for: assetName, in: checksums) else {
            throw CLIProxyAPIReleaseClientError.missingChecksumEntry(assetName)
        }
        return CLIProxyAPIRelease(
            version: version,
            tagName: githubRelease.tagName,
            assetName: assetName,
            assetURL: archiveURL,
            assetSha256: assetSha
        )
    }

    public func downloadArchive(for release: CLIProxyAPIRelease) async throws -> Data {
        try await httpClient.get(release.assetURL, headers: [:])
    }

    static func checksum(for assetName: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts[1] == assetName {
                return parts[0]
            }
        }
        return nil
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let assets: [GitHubAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
```

- [ ] **Step 4: Run release client tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIReleaseClientTests
```

Expected: PASS.

- [ ] **Step 5: Write failing archive verifier tests**

Create `Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift`:

```swift
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
```

- [ ] **Step 6: Run archive verifier tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIArchiveVerifierTests
```

Expected: compile fails because verifier types do not exist.

- [ ] **Step 7: Implement archive verifier**

Create `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift`:

```swift
import Foundation

public enum CLIProxyAPIArchiveVerifierError: Error, Equatable {
    case archiveChecksumMismatch
    case extractionFailed(String)
    case missingExtractedBinary
    case versionCommandFailed(String)
    case versionMetadataMissing(String)
    case versionMismatch(expected: String, actual: String)
}

public struct CLIProxyAPIBinaryVerificationResult: Equatable, Sendable {
    public let binaryURL: URL
    public let manifest: CLIProxyAPIBinaryManifest
}

public struct CLIProxyAPIArchiveVerifier: Sendable {
    private let runner: any ProcessRunning
    private let fileManager: FileManager
    private let extractedBinaryLocator: @Sendable (URL) throws -> URL

    public init(
        runner: any ProcessRunning = ProcessRunner(timeout: 30),
        fileManager: FileManager = .default,
        extractedBinaryLocator: @escaping @Sendable (URL) throws -> URL = { $0.appendingPathComponent("cli-proxy-api") }
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.extractedBinaryLocator = extractedBinaryLocator
    }

    public func verify(archiveData: Data, release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        guard archiveData.sha256HexDigest() == release.assetSha256 else {
            throw CLIProxyAPIArchiveVerifierError.archiveChecksumMismatch
        }
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxyapi-update")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let archiveURL = tempDirectory.appendingPathComponent(release.assetName)
        try archiveData.write(to: archiveURL, options: .atomic)

        let extraction = await runner.run("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", tempDirectory.path])
        guard extraction.exitCode == 0 else {
            throw CLIProxyAPIArchiveVerifierError.extractionFailed(extraction.stderr)
        }
        let binaryURL = try extractedBinaryLocator(tempDirectory)
        guard fileManager.fileExists(atPath: binaryURL.path) else {
            throw CLIProxyAPIArchiveVerifierError.missingExtractedBinary
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let version = await runner.run(binaryURL.path, ["--version"])
        guard version.exitCode == 0 else {
            throw CLIProxyAPIArchiveVerifierError.versionCommandFailed(version.stderr)
        }
        guard let metadata = Self.parseVersionLine(version.stdout + "\n" + version.stderr) else {
            throw CLIProxyAPIArchiveVerifierError.versionMetadataMissing(version.stdout)
        }
        guard metadata.version == release.version.description else {
            throw CLIProxyAPIArchiveVerifierError.versionMismatch(expected: release.version.description, actual: metadata.version)
        }
        let binaryData = try Data(contentsOf: binaryURL)
        let size = try binaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? binaryData.count
        let manifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: metadata.version,
            commit: metadata.commit,
            builtAt: metadata.builtAt,
            sourceKind: .userUpdated,
            source: release.assetURL.absoluteString,
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: release.tagName,
            upstreamAsset: release.assetName,
            upstreamAssetSha256: release.assetSha256,
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: binaryData.sha256HexDigest(),
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api",
            downloadedAt: ISO8601DateFormatter().string(from: Date())
        )
        return CLIProxyAPIBinaryVerificationResult(binaryURL: binaryURL, manifest: manifest)
    }

    static func parseVersionLine(_ output: String) -> (version: String, commit: String, builtAt: String)? {
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init) {
            guard line.contains("CLIProxyAPI Version:") else { continue }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            let version = parts[0].replacingOccurrences(of: "CLIProxyAPI Version:", with: "").trimmingCharacters(in: .whitespaces)
            let commit = parts[1].replacingOccurrences(of: "Commit:", with: "").trimmingCharacters(in: .whitespaces)
            let builtAt = parts[2].replacingOccurrences(of: "BuiltAt:", with: "").trimmingCharacters(in: .whitespaces)
            guard version.isEmpty == false, commit.isEmpty == false, builtAt.isEmpty == false else { return nil }
            return (version, commit, builtAt)
        }
        return nil
    }
}
```

- [ ] **Step 8: Run Task 3 tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIReleaseClientTests
swift test --filter CLIProxyAPIArchiveVerifierTests
```

Expected: PASS.

- [ ] **Step 9: Commit Task 3**

```bash
git add Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIReleaseClient.swift \
  Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIArchiveVerifier.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIReleaseClientTests.swift \
  Tests/CLIProxyManagerCoreTests/CLIProxyAPIArchiveVerifierTests.swift
git commit -m "Add CLIProxyAPI release verification" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: App update service and persisted update state

**Files:**
- Create: `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
- Test: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`

**Interfaces:**
- Consumes: `CLIProxyAPIReleaseClient`, `CLIProxyAPIArchiveVerifier`, `CLIProxyAPIBinaryStore`.
- Produces: `@MainActor final class CLIProxyAPIUpdateService: ObservableObject`
- Produces: published properties `state`, `availableUpdate`, `pendingUpdate`, `isChecking`, `isUpdating`, `lastErrorMessage`
- Produces: `func checkAutomaticallyOnLaunch() async`
- Produces: `func checkNow() async`
- Produces: `func deferAvailableUpdate()`
- Produces: `func downloadAvailableUpdate() async`
- Produces: `func applyPendingNow() throws`

- [ ] **Step 1: Write failing update service tests**

Create `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`:

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class CLIProxyAPIUpdateServiceTests: XCTestCase {
    func testAutomaticCheckSkipsWhenLastCheckIsWithin24Hours() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeState(lastCheckedAt: Date(), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() })

        await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 0)
        XCTAssertNil(service.availableUpdate)
    }

    func testAutomaticCheckPublishesNewerReleaseWhenLastCheckIsOld() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let oldDate = Date(timeIntervalSince1970: 0)
        try writeState(lastCheckedAt: oldDate, to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 90_000) })

        await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testManualCheckIgnoresLastCheckThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeState(lastCheckedAt: Date(), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() })

        await service.checkNow()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testDeferredVersionSuppressesRepeatedAutomaticPrompt() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 100_000) })

        await service.checkNow()
        service.deferAvailableUpdate()
        service.availableUpdate = nil
        await service.checkAutomaticallyOnLaunch()

        XCTAssertNil(service.availableUpdate)
    }

    func testDownloadAvailableUpdateSavesPendingBinary() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let release = release("7.2.42")
        let checker = StubUpdateChecking(release: release)
        let downloader = StubUpdateDownloading(result: CLIProxyAPIBinaryVerificationResult(
            binaryURL: sandbox.appendingPathComponent("verified/cliproxyapi"),
            manifest: manifest("7.2.42")
        ))
        try writeExecutable("#!/bin/sh\n", to: downloader.result!.binaryURL)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: downloader, store: store, now: { Date() })
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(store.savedPendingVersions, ["7.2.42"])
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
    }

    func testApplyPendingNowCallsStore() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() })

        try service.applyPendingNow()

        XCTAssertEqual(store.applyPendingCallCount, 1)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("CLIProxyAPIUpdateServiceTests").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func release(_ version: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(version: CLIProxyAPIVersion(version)!, tagName: "v\(version)", assetName: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", assetURL: URL(string: "https://example.com/archive.tar.gz")!, assetSha256: "archive-sha")
    }

    private func manifest(_ version: String) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: .userUpdated, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api")
    }

    private func writeState(lastCheckedAt: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "{\"lastCheckedAt\":\"\(ISO8601DateFormatter().string(from: lastCheckedAt))\"}"
        try Data(text.utf8).write(to: url)
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
```

- [ ] **Step 2: Run update service tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIUpdateServiceTests
```

Expected: compile fails because service/test protocols do not exist.

- [ ] **Step 3: Implement service protocols and update state**

At the top of `CLIProxyAPIUpdateService.swift`, define these protocols and state types:

```swift
import CLIProxyManagerCore
import Foundation

protocol CLIProxyAPIUpdateChecking: Sendable {
    func latestRelease() async throws -> CLIProxyAPIRelease
}

protocol CLIProxyAPIUpdateDownloading: Sendable {
    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult
}

protocol CLIProxyAPIUpdateBinaryStoring: Sendable {
    func currentVersion() throws -> CLIProxyAPIVersion?
    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest?
    func applyPending() throws
}

struct CLIProxyAPIUpdateState: Codable, Equatable {
    var lastCheckedAt: String?
    var lastAvailableVersion: String?
    var lastDeferredVersion: String?
    var pendingVersion: String?
    var lastFailureMessage: String?
    var lastFailureAt: String?
}

enum CLIProxyAPIUpdateServiceState: Equatable {
    case idle
    case checking
    case updateAvailable
    case downloading
    case pending
    case upToDate
    case failed(String)
}
```

- [ ] **Step 4: Add concrete adapters**

In the same file, add concrete adapters:

```swift
extension CLIProxyAPIReleaseClient: CLIProxyAPIUpdateChecking {}

struct CLIProxyAPIUpdateDownloader: CLIProxyAPIUpdateDownloading {
    let client: CLIProxyAPIReleaseClient
    let verifier: CLIProxyAPIArchiveVerifier

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        let data = try await client.downloadArchive(for: release)
        return try await verifier.verify(archiveData: data, release: release)
    }
}

extension CLIProxyAPIBinaryStore: CLIProxyAPIUpdateBinaryStoring {
    public func currentVersion() throws -> CLIProxyAPIVersion? {
        try activeManifest()?.parsedVersion
    }
}
```

- [ ] **Step 5: Implement CLIProxyAPIUpdateService**

Add the service implementation:

```swift
@MainActor
final class CLIProxyAPIUpdateService: ObservableObject {
    @Published var state: CLIProxyAPIUpdateServiceState = .idle
    @Published var availableUpdate: CLIProxyAPIRelease?
    @Published var pendingUpdate: CLIProxyAPIBinaryManifest?
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var lastErrorMessage: String?

    private let paths: ManagedPaths
    private let checker: any CLIProxyAPIUpdateChecking
    private let downloader: any CLIProxyAPIUpdateDownloading
    private let store: any CLIProxyAPIUpdateBinaryStoring
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        paths: ManagedPaths = ManagedPaths(),
        checker: any CLIProxyAPIUpdateChecking = CLIProxyAPIReleaseClient(),
        downloader: (any CLIProxyAPIUpdateDownloading)? = nil,
        store: (any CLIProxyAPIUpdateBinaryStoring)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.checker = checker
        let concreteClient = CLIProxyAPIReleaseClient()
        self.downloader = downloader ?? CLIProxyAPIUpdateDownloader(client: concreteClient, verifier: CLIProxyAPIArchiveVerifier())
        self.store = store ?? CLIProxyAPIBinaryStore(paths: paths)
        self.now = now
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.pendingUpdate = try? self.store.pendingManifest()
    }

    func checkAutomaticallyOnLaunch() async {
        let state = loadState()
        if let lastCheckedAt = state.lastCheckedAt.flatMap(Self.parseDate), now().timeIntervalSince(lastCheckedAt) < 86_400 {
            return
        }
        await check(suppressDeferredVersion: true)
    }

    func checkNow() async {
        await check(suppressDeferredVersion: false)
    }

    func deferAvailableUpdate() {
        guard let availableUpdate else { return }
        var state = loadState()
        state.lastDeferredVersion = availableUpdate.version.description
        saveState(state)
        self.availableUpdate = nil
        self.state = .idle
    }

    func downloadAvailableUpdate() async {
        guard let release = availableUpdate, !isUpdating else { return }
        isUpdating = true
        state = .downloading
        defer { isUpdating = false }
        do {
            let result = try await downloader.downloadAndVerify(release)
            try store.savePending(binaryURL: result.binaryURL, manifest: result.manifest)
            pendingUpdate = result.manifest
            var updateState = loadState()
            updateState.pendingVersion = result.manifest.version
            saveState(updateState)
            state = .pending
        } catch {
            recordFailure(error)
        }
    }

    func applyPendingNow() throws {
        try store.applyPending()
        pendingUpdate = nil
        var updateState = loadState()
        updateState.pendingVersion = nil
        saveState(updateState)
        state = .idle
    }

    private func check(suppressDeferredVersion: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        state = .checking
        defer { isChecking = false }
        do {
            let release = try await checker.latestRelease()
            var updateState = loadState()
            updateState.lastCheckedAt = Self.formatDate(now())
            updateState.lastAvailableVersion = release.version.description
            saveState(updateState)
            let current = try store.currentVersion()
            if let current, release.version <= current {
                availableUpdate = nil
                state = .upToDate
                return
            }
            if suppressDeferredVersion, updateState.lastDeferredVersion == release.version.description {
                availableUpdate = nil
                state = .idle
                return
            }
            availableUpdate = release
            state = .updateAvailable
        } catch {
            recordFailure(error)
        }
    }

    private func recordFailure(_ error: Error) {
        let message = error.localizedDescription
        lastErrorMessage = message
        var state = loadState()
        state.lastFailureMessage = message
        state.lastFailureAt = Self.formatDate(now())
        saveState(state)
        self.state = .failed(message)
    }

    private func loadState() -> CLIProxyAPIUpdateState {
        guard fileManager.fileExists(atPath: paths.clipProxyUpdateStateFile.path),
              let data = try? Data(contentsOf: paths.clipProxyUpdateStateFile),
              let state = try? decoder.decode(CLIProxyAPIUpdateState.self, from: data) else {
            return CLIProxyAPIUpdateState()
        }
        return state
    }

    private func saveState(_ state: CLIProxyAPIUpdateState) {
        do {
            try fileManager.createDirectory(at: paths.clipProxyUpdateStateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: paths.clipProxyUpdateStateFile, options: .atomic)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
```

- [ ] **Step 6: Add test doubles at bottom of test file**

Append to `CLIProxyAPIUpdateServiceTests.swift`:

```swift
private final class StubUpdateChecking: CLIProxyAPIUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let release: CLIProxyAPIRelease
    private var _invocationCount = 0
    var invocationCount: Int { lock.withLock { _invocationCount } }

    init(release: CLIProxyAPIRelease) { self.release = release }

    func latestRelease() async throws -> CLIProxyAPIRelease {
        lock.withLock { _invocationCount += 1 }
        return release
    }
}

private final class StubUpdateDownloading: CLIProxyAPIUpdateDownloading, @unchecked Sendable {
    let result: CLIProxyAPIBinaryVerificationResult?

    init(result: CLIProxyAPIBinaryVerificationResult? = nil) {
        self.result = result
    }

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        if let result { return result }
        throw NSError(domain: "test", code: 1)
    }
}

private final class StubUpdateBinaryStore: CLIProxyAPIUpdateBinaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let current: CLIProxyAPIVersion?
    private var _savedPendingVersions: [String] = []
    private var _applyPendingCallCount = 0

    var savedPendingVersions: [String] { lock.withLock { _savedPendingVersions } }
    var applyPendingCallCount: Int { lock.withLock { _applyPendingCallCount } }

    init(currentVersion: String?) {
        self.current = currentVersion.flatMap(CLIProxyAPIVersion.init)
    }

    func currentVersion() throws -> CLIProxyAPIVersion? { current }
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? { nil }

    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        lock.withLock { _savedPendingVersions.append(manifest.version) }
    }

    func applyPending() throws {
        lock.withLock { _applyPendingCallCount += 1 }
    }
}
```

- [ ] **Step 7: Run update service tests and verify they pass**

Run:

```bash
swift test --filter CLIProxyAPIUpdateServiceTests
```

Expected: PASS.

- [ ] **Step 8: Commit Task 4**

```bash
git add Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift
git commit -m "Add CLIProxyAPI update service" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Task 5: SwiftUI integration and apply/restart flow

**Files:**
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Test: `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`

**Interfaces:**
- Consumes: `CLIProxyAPIUpdateService` from Task 4.
- Produces: `cliproxyAPIUpdateDescription(currentVersion:state:availableUpdate:pendingUpdate:) -> String`
- Produces: `cliproxyAPIUpdateActionTitle(state:availableUpdate:pendingUpdate:) -> String`
- Produces: `DashboardView(viewModel:cliProxyAPIUpdateService:openSettings:quit:)`
- Produces: `SettingsView(viewModel:updaterService:cliProxyAPIUpdateService:)`
- Produces: `ServerSettingsView(viewModel:cliProxyAPIUpdateService:)`

- [ ] **Step 1: Write failing UI copy tests**

Create `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class CLIProxyAPIUpdateUITests: XCTestCase {
    func testServerSettingsDescriptionShowsCurrentVersionByDefault() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .idle,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41"
        )
    }

    func testServerSettingsDescriptionShowsAvailableVersion() {
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )

        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .updateAvailable,
                availableUpdate: release,
                pendingUpdate: nil
            ),
            "Version 7.2.42 is available."
        )
    }

    func testServerSettingsDescriptionShowsPendingVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .pending,
                availableUpdate: nil,
                pendingUpdate: manifest("7.2.42")
            ),
            "Version 7.2.42 will be applied on next server start."
        )
    }

    func testServerSettingsActionTitleReflectsState() {
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )

        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .idle, availableUpdate: nil, pendingUpdate: nil), "Check now")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .checking, availableUpdate: nil, pendingUpdate: nil), "Checking…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .updateAvailable, availableUpdate: release, pendingUpdate: nil), "Update…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .pending, availableUpdate: nil, pendingUpdate: manifest("7.2.42")), "Apply now")
    }

    func testDashboardViewSourceStartsAutomaticCLIProxyAPICheckAndShowsConfirmationDialogs() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("await cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()"))
        XCTAssertTrue(source.contains("showCLIProxyAPIUpdatePrompt"))
        XCTAssertTrue(source.contains("showCLIProxyAPIApplyPrompt"))
        XCTAssertTrue(source.contains("Apply now and restart server"))
        XCTAssertTrue(source.contains("Apply on next server start"))
    }

    private func manifest(_ version: String) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: .userUpdated, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api")
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }
}
```

- [ ] **Step 2: Run UI tests and verify they fail**

Run:

```bash
swift test --filter CLIProxyAPIUpdateUITests
```

Expected: compile fails because UI helper functions and view integration do not exist.

- [ ] **Step 3: Add UI helper functions**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, add these functions near `aboutVersionText`:

```swift
func cliproxyAPIUpdateDescription(
    currentVersion: String,
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String {
    if let pendingUpdate {
        return "Version \(pendingUpdate.version) will be applied on next server start."
    }
    if let availableUpdate {
        return "Version \(availableUpdate.version.description) is available."
    }
    switch state {
    case .checking:
        return "Checking for CLIProxyAPI updates…"
    case .failed:
        return "Last check failed."
    default:
        return "Current version: \(currentVersion)"
    }
}

func cliproxyAPIUpdateActionTitle(
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String {
    if pendingUpdate != nil { return "Apply now" }
    if availableUpdate != nil { return "Update…" }
    if state == .checking { return "Checking…" }
    return "Check now"
}
```

- [ ] **Step 4: Modify ServerSettingsView to show CLIProxyAPI binary row**

Change `ServerSettingsView` signature:

```swift
struct ServerSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    @State private var showApplyPrompt = false
```

Inside the `SettingsGroup(title: "Server")` after `Start server on launch`, add:

```swift
SettingsRow(
    label: "CLIProxyAPI binary",
    description: cliproxyAPIUpdateDescription(
        currentVersion: cliProxyAPIUpdateService.currentVersionText,
        state: cliProxyAPIUpdateService.state,
        availableUpdate: cliProxyAPIUpdateService.availableUpdate,
        pendingUpdate: cliProxyAPIUpdateService.pendingUpdate
    ),
    isEnabled: !cliProxyAPIUpdateService.isChecking && !cliProxyAPIUpdateService.isUpdating
) {
    Button(cliproxyAPIUpdateActionTitle(
        state: cliProxyAPIUpdateService.state,
        availableUpdate: cliProxyAPIUpdateService.availableUpdate,
        pendingUpdate: cliProxyAPIUpdateService.pendingUpdate
    )) {
        if cliProxyAPIUpdateService.pendingUpdate != nil {
            showApplyPrompt = true
        } else if cliProxyAPIUpdateService.availableUpdate != nil {
            Task {
                await cliProxyAPIUpdateService.downloadAvailableUpdate()
                if cliProxyAPIUpdateService.pendingUpdate != nil {
                    showApplyPrompt = true
                }
            }
        } else {
            Task { await cliProxyAPIUpdateService.checkNow() }
        }
    }
    .controlSize(.small)
}
```

Add a confirmation dialog to `ServerSettingsView.body` after the outer `VStack` modifiers:

```swift
.confirmationDialog(
    "Apply CLIProxyAPI update now?",
    isPresented: $showApplyPrompt,
    titleVisibility: .visible
) {
    Button(viewModel.serverControlState.isRunning ? "Apply now and restart server" : "Apply now") {
        Task {
            do {
                try cliProxyAPIUpdateService.applyPendingNow()
                if viewModel.serverControlState.isRunning {
                    await viewModel.restartServer()
                }
                viewModel.settingsMessage = "CLIProxyAPI update applied."
            } catch {
                viewModel.settingsMessage = "CLIProxyAPI update failed: \(error.localizedDescription)"
            }
        }
    }
    Button("Apply on next server start") {
        viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
    }
    Button("Cancel", role: .cancel) {}
}
```

- [ ] **Step 5: Add currentVersionText to update service**

In `CLIProxyAPIUpdateService`, add:

```swift
@Published var currentVersionText: String = "Unknown"
```

In `init`, after `pendingUpdate` assignment:

```swift
self.currentVersionText = (try? self.store.currentVersion()?.description) ?? "Unknown"
```

In `check` before comparing release versions, refresh it:

```swift
let current = try store.currentVersion()
currentVersionText = current?.description ?? "Unknown"
```

In `downloadAvailableUpdate()` after pending state:

```swift
currentVersionText = (try? store.currentVersion()?.description) ?? currentVersionText
```

In `applyPendingNow()` after `try store.applyPending()`:

```swift
currentVersionText = (try? store.currentVersion()?.description) ?? currentVersionText
```

- [ ] **Step 6: Wire SettingsView and app root**

Modify `Sources/CLIProxyManagerApp/Views/SettingsView.swift`:

```swift
@ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
```

Change server tab:

```swift
case .server:
    ServerSettingsView(viewModel: viewModel, cliProxyAPIUpdateService: cliProxyAPIUpdateService)
```

Modify `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`:

```swift
@StateObject private var cliProxyAPIUpdateService = CLIProxyAPIUpdateService()
```

Pass it to views:

```swift
DashboardView(
    viewModel: viewModel,
    cliProxyAPIUpdateService: cliProxyAPIUpdateService,
    openSettings: { appWindowController.openSettings() },
    quit: { quitCoordinator.requestQuit() }
)
```

```swift
SettingsView(
    viewModel: viewModel,
    updaterService: updaterService,
    cliProxyAPIUpdateService: cliProxyAPIUpdateService
)
```

- [ ] **Step 7: Wire Dashboard automatic prompt flow**

Modify `Sources/CLIProxyManagerApp/Views/DashboardView.swift` signature and state:

```swift
@ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
@State private var showCLIProxyAPIUpdatePrompt = false
@State private var showCLIProxyAPIApplyPrompt = false
```

In `.task` after autostart:

```swift
await cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()
```

Add `onChange`:

```swift
.onChange(of: cliProxyAPIUpdateService.availableUpdate?.tagName) { tag in
    showCLIProxyAPIUpdatePrompt = tag != nil
}
.onChange(of: cliProxyAPIUpdateService.pendingUpdate?.version) { version in
    if version != nil {
        showCLIProxyAPIApplyPrompt = true
    }
}
```

Add confirmation dialogs to the root `VStack` chain:

```swift
.confirmationDialog(
    cliProxyAPIUpdateService.availableUpdate.map { "CLIProxyAPI \($0.version.description) is available" } ?? "CLIProxyAPI update available",
    isPresented: $showCLIProxyAPIUpdatePrompt,
    titleVisibility: .visible
) {
    Button("Update") {
        Task { await cliProxyAPIUpdateService.downloadAvailableUpdate() }
    }
    Button("Later", role: .cancel) {
        cliProxyAPIUpdateService.deferAvailableUpdate()
    }
}
.confirmationDialog(
    cliProxyAPIUpdateService.pendingUpdate.map { "Apply CLIProxyAPI \($0.version) now?" } ?? "Apply CLIProxyAPI update now?",
    isPresented: $showCLIProxyAPIApplyPrompt,
    titleVisibility: .visible
) {
    Button(viewModel.serverControlState.isRunning ? "Apply now and restart server" : "Apply now") {
        Task {
            do {
                try cliProxyAPIUpdateService.applyPendingNow()
                if viewModel.serverControlState.isRunning {
                    await viewModel.restartServer()
                }
                viewModel.settingsMessage = "CLIProxyAPI update applied."
            } catch {
                viewModel.settingsMessage = "CLIProxyAPI update failed: \(error.localizedDescription)"
            }
        }
    }
    Button("Apply on next server start") {
        viewModel.settingsMessage = "CLIProxyAPI update will be applied on next server start."
    }
    Button("Cancel", role: .cancel) {}
}
```

- [ ] **Step 8: Update tests that instantiate changed views**

Search for `DashboardView(` and `SettingsView(` in tests. For each initializer, pass a test service:

```swift
cliProxyAPIUpdateService: CLIProxyAPIUpdateService(
    checker: StubUpdateChecking(release: CLIProxyAPIRelease(
        version: CLIProxyAPIVersion("7.2.42")!,
        tagName: "v7.2.42",
        assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
        assetURL: URL(string: "https://example.com/archive.tar.gz")!,
        assetSha256: "sha"
    )),
    downloader: StubUpdateDownloading(),
    store: StubUpdateBinaryStore(currentVersion: "7.2.41")
)
```

If those stub types are private to `CLIProxyAPIUpdateServiceTests`, either make equivalent local stubs in the affected test file or avoid constructing these views in tests.

- [ ] **Step 9: Run UI tests and app tests**

Run:

```bash
swift test --filter CLIProxyAPIUpdateUITests
swift test --filter SettingsNavigationTests
swift test --filter DashboardViewModelRefreshTests
```

Expected: PASS.

- [ ] **Step 10: Commit Task 5**

```bash
git add Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift \
  Sources/CLIProxyManagerApp/Views/SettingsView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift \
  Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift
git commit -m "Add CLIProxyAPI update UI" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Documentation, full regression, and final review

**Files:**
- Modify: `README.md`
- Read/verify: `docs/superpowers/specs/2026-07-01-cliproxyapi-binary-self-update-design.md`
- Verify all files changed by Tasks 1-5.

**Interfaces:**
- Consumes all previous task outputs.
- Produces documented user-facing behavior and a verified working tree.

- [ ] **Step 1: Update README release/update sections**

Modify `README.md` under `## Releases and automatic updates` after the Sparkle paragraph. Add:

```markdown
CLIProxyAPI binary updates are separate from CLIProxyManager app updates. On launch, CLIProxyManager checks the upstream `router-for-me/CLIProxyAPI` GitHub Releases feed in the background at most once every 24 hours. If a newer stable macOS arm64 CLIProxyAPI release is available, the app asks before downloading or applying it.

When the user accepts a CLIProxyAPI binary update, the app downloads `CLIProxyAPI_<version>_darwin_aarch64.tar.gz` and verifies it against upstream `checksums.txt` before storing it. The user can apply the verified binary immediately, which restarts the app-managed server if it is running, or defer it until the next server start. Checksum mismatches, missing assets, extraction failures, and version metadata mismatches keep the existing binary unchanged.
```

Also update `## Updating the bundled CLIProxyAPI binary` by adding this paragraph before “Use the vendoring script”:

```markdown
This vendoring flow changes the default binary shipped inside the app. It is still useful for release baselines, but day-to-day CLIProxyAPI updates can also be applied by the installed app through the in-app CLIProxyAPI binary updater.
```

- [ ] **Step 2: Run documentation-focused tests**

Run:

```bash
swift test --filter UpdaterConfigurationTests
swift test --filter LicenseResourceTests
```

Expected: PASS. If README wording causes an existing assertion to fail, adjust the README to include the exact phrase required by that test without removing the new CLIProxyAPI binary update explanation.

- [ ] **Step 3: Run all new focused test suites**

Run:

```bash
swift test --filter CLIProxyAPIVersionTests
swift test --filter CLIProxyAPIBinaryManifestTests
swift test --filter CLIProxyAPIBinaryStoreTests
swift test --filter CLIProxyAPIReleaseClientTests
swift test --filter CLIProxyAPIArchiveVerifierTests
swift test --filter CLIProxyAPIUpdateServiceTests
swift test --filter CLIProxyAPIUpdateUITests
```

Expected: all PASS.

- [ ] **Step 4: Run affected existing test suites**

Run:

```bash
swift test --filter ProxyServiceManagerTests
swift test --filter DashboardViewModelRefreshTests
swift test --filter SettingsNavigationTests
swift test --filter UpdaterConfigurationTests
```

Expected: all PASS.

- [ ] **Step 5: Run the full Swift test suite**

Run:

```bash
swift test
```

Expected: exits with status 0 and ends with a passing test summary.

- [ ] **Step 6: Run script regression for vendoring path**

Run:

```bash
Tests/ScriptTests/vendor-cliproxyapi-tests.sh
```

Expected: exits with status 0 and prints no `FAIL:` line. This confirms the developer vendoring path remains intact.

- [ ] **Step 7: Build the development app bundle**

Run:

```bash
make bundle
```

Expected: exits with status 0 and produces `build/CLIProxyManager.app`. This follows the project memory that app verification should use development builds.

- [ ] **Step 8: Inspect final diff**

Run:

```bash
git status --short
git diff --stat
git diff -- Sources/CLIProxyManagerCore/Proxy Sources/CLIProxyManagerApp README.md Tests
```

Expected:

- Changed files are limited to the planned source, test, README, spec, and plan files.
- Pre-existing untracked files under `docs/superpowers/...` may still appear and must not be staged unless they belong to this feature.
- No generated build artifacts are staged.

- [ ] **Step 9: Commit documentation and any final fixes**

```bash
git add README.md
git commit -m "Document CLIProxyAPI binary updates" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

If previous tasks left uncommitted source fixes because tests required small corrections, include only those relevant files in this final commit and change the commit subject to:

```bash
git commit -m "Finish CLIProxyAPI binary self-update" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 10: Request code review**

After all tests and build pass, invoke the `superpowers:requesting-code-review` skill before claiming completion. Ask the reviewer to focus on:

- pending→active atomicity and rollback behavior
- checksum and version verification boundaries
- 24-hour automatic check throttling
- UI flows for “지금 적용” vs “다음 실행에 적용”
- ensuring user-updated binaries are not overwritten by older bundled binaries

---

## Self-Review

### Spec coverage

- 앱 실행 시와 24시간마다 백그라운드 확인: Task 4 service tests and Task 5 app `.task` integration.
- 수동 확인: Task 4 `checkNow()` and Task 5 Server settings row.
- 상류 GitHub Releases 직접 확인: Task 3 `CLIProxyAPIReleaseClient`.
- `checksums.txt` 검증: Task 3 release client and archive verifier.
- pending 저장: Task 2 store and Task 4 service.
- “지금 적용 후 재시작”: Task 5 Dashboard/Server confirmation dialog.
- “다음 실행에 적용”: Task 2 pending promotion and Task 5 dialog.
- 실행 중 서버를 건드리지 않는 deferred flow: Task 5 only records message, Task 2 applies on next prepare.
- user-updated 바이너리를 오래된 bundled 바이너리로 되돌리지 않음: Task 2 tests.
- 기존 Sparkle 앱 업데이트 유지: Task 5 only adds new service and preserves `UpdaterService`; Task 6 runs `UpdaterConfigurationTests`.
- README 문서화: Task 6.

### Placeholder scan

금지된 미완성 표식과 포괄적 지시를 검색했고, 실제 작업 단계에는 발견되지 않았다. 각 코드 변경 단계는 구체적인 파일, 코드, 명령, 기대 결과를 포함한다.

### Type consistency

- `CLIProxyAPIVersion`, `CLIProxyAPIBinaryManifest`, `CLIProxyAPIBinaryStore`, `CLIProxyAPIReleaseClient`, `CLIProxyAPIArchiveVerifier`, `CLIProxyAPIUpdateService` names are consistent across task interfaces and usage.
- `CLIProxyAPIUpdateServiceState` is introduced in Task 4 and consumed by Task 5 helper functions.
- `ManagedPaths` new properties are introduced in Task 1 and consumed by Tasks 2 and 4.
- `ProxyServiceManager` receives `bundledManifestURL` in Task 2, and `BundledProxyBinary.serviceManager()` passes it.

