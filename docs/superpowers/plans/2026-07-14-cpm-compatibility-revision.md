# cpm Compatibility Revision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 업데이트로 cpm 바이너리 hash가 달라져도 cpm 동작 계약이 동일하면 최신으로 간주하고, 실제 cpm 변경 릴리스에서만 Update를 표시한다.

**Architecture:** `CPMInstallationService`에 명시적 compatibility revision을 주입하고 설치 기록에 app version과 revision을 저장한다. 설치 파일 소유권은 기존 digest로 검증하되 업데이트 필요 여부는 번들 hash가 아니라 revision으로 판정한다. 기존 revision 없는 기록은 한 번 업데이트하도록 legacy 상태로 처리한다.

**Tech Stack:** Swift 5.9+, Swift Package Manager, XCTest, CryptoKit SHA-256, macOS AppKit/SwiftUI

## Global Constraints

- cpm은 CLIProxyManager 앱과 함께 배포하며 독립 semantic version이나 독립 업데이트 채널을 추가하지 않는다.
- 초기 cpm compatibility revision은 `1`이다.
- cpm 명령, 출력 계약, exit code, 사용자 관찰 가능 동작 또는 필수 Core 동작이 바뀔 때만 revision을 증가시킨다.
- `/usr/local/bin/cpm`의 외부 변경은 기록된 digest로 계속 감지하고 `.unmanaged`로 처리한다.
- revision 없는 기존 설치 기록은 한 번 `.installedOutdated`로 처리한다.
- 앱 업데이트 중 관리자 권한을 자동 요청해 cpm을 교체하지 않는다.
- 이번 변경에는 CLIProxyAPI 번들 버전 `7.2.72`, upstream commit `6279bb8a`, SHA-256 `2a78bdd71a252b99f8ab4839bf5bee59f92fc84e2a62556812d2d8c8e07b5d60` 반영도 포함한다.

---

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift`
  - cpm revision 상수, revision-aware 설치 기록, legacy decoding, 상태 판정을 담당한다.
- Modify: `Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift`
  - revision 판정과 legacy migration의 회귀 테스트를 담당한다.
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - 상태 설명을 앱 전체 업데이트가 아닌 cpm 동기화 의미로 명확히 한다.
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
  - CLIProxyAPI 7.2.72 arm64 실행 파일이다.
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
  - CLIProxyAPI 7.2.72 출처와 checksum 메타데이터다.

---

### Task 1: Revision 기반 설치 기록과 상태 판정

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift:13-37,112-141`
- Modify: `Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift:100-210`

**Interfaces:**
- Consumes: `CPMInstallationStatus`, `ManagedPaths.cpmInstallationRecordFile`, `PrivilegedCPMCommandRunning`
- Produces: `CPMCompatibility.currentRevision: Int`, revision-aware `CPMInstallationService.status()`, JSON fields `digest`, `appVersion`, `cpmRevision`

- [ ] **Step 1: 같은 revision에서 번들 hash가 바뀌어도 current인 실패 테스트 작성**

`CPMInstallationServiceTests`의 기존 hash 변경 테스트를 revision 계약으로 교체한다.

```swift
func testStatusRemainsCurrentWhenBundledHelperChangesWithoutRevisionChange() async throws {
    let fixture = try Fixture()
    let service = fixture.makeService(runner: CopyingPrivilegedRunner(), currentRevision: 1)
    try await service.installOrUpdate()
    try Data("rebuilt cpm".utf8).write(to: fixture.source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.source.path)

    XCTAssertEqual(service.status(), .installedCurrent(version: "0.1.13"))
}
```

Fixture의 factory를 revision 주입형으로 변경한다.

```swift
func makeService(
    runner: any PrivilegedCPMCommandRunning = CopyingPrivilegedRunner(),
    bundledVersion: String = "0.1.13",
    currentRevision: Int = 1
) -> CPMInstallationService {
    CPMInstallationService(
        sourceURL: source,
        targetURL: target,
        bundledVersion: bundledVersion,
        availableVersion: { bundledVersion },
        currentRevision: currentRevision,
        paths: paths,
        runner: runner
    )
}
```

- [ ] **Step 2: 테스트가 현재 hash 비교 때문에 실패하는지 확인**

Run:

```bash
swift test --filter CPMInstallationServiceTests/testStatusRemainsCurrentWhenBundledHelperChangesWithoutRevisionChange
```

Expected: FAIL. 현재 구현은 source digest와 target digest가 다르면 `.installedOutdated`를 반환한다.

- [ ] **Step 3: revision 증가와 legacy 기록 테스트 추가**

```swift
func testStatusReportsOutdatedWhenBundledRevisionIncreases() async throws {
    let fixture = try Fixture()
    try await fixture.makeService(
        runner: CopyingPrivilegedRunner(),
        bundledVersion: "0.1.13",
        currentRevision: 1
    ).installOrUpdate()

    let newer = fixture.makeService(
        bundledVersion: "0.1.14",
        currentRevision: 2
    )

    XCTAssertEqual(
        newer.status(),
        .installedOutdated(installedVersion: "0.1.13", availableVersion: "0.1.14")
    )
}

func testStatusKeepsNewerInstalledRevisionCurrent() async throws {
    let fixture = try Fixture()
    try await fixture.makeService(
        runner: CopyingPrivilegedRunner(),
        bundledVersion: "0.1.14",
        currentRevision: 2
    ).installOrUpdate()

    let olderBundle = fixture.makeService(
        bundledVersion: "0.1.13",
        currentRevision: 1
    )

    XCTAssertEqual(olderBundle.status(), .installedCurrent(version: "0.1.14"))
}

func testLegacyRecordWithoutRevisionRequiresOneUpdate() throws {
    let fixture = try Fixture()
    try Data("installed cpm".utf8).write(to: fixture.target)
    let digest = try fixture.sha256(of: fixture.target)
    try FileManager.default.createDirectory(
        at: fixture.paths.rootDirectory,
        withIntermediateDirectories: true
    )
    let legacy = """
    {"digest":"\(digest)","version":"0.1.15"}
    """
    try Data(legacy.utf8).write(to: fixture.paths.cpmInstallationRecordFile)

    XCTAssertEqual(
        fixture.makeService(bundledVersion: "0.1.17", currentRevision: 1).status(),
        .installedOutdated(installedVersion: "0.1.15", availableVersion: "0.1.17")
    )
}
```

Fixture에 test-only digest helper를 추가한다.

```swift
func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}
```

테스트 파일에 `import CryptoKit`을 추가한다.

- [ ] **Step 4: revision 관련 테스트가 실패하는지 확인**

Run:

```bash
swift test --filter CPMInstallationServiceTests
```

Expected: 새 revision initializer가 없거나 기존 hash 판정 때문에 FAIL.

- [ ] **Step 5: 최소 revision 모델과 호환 설치 기록 구현**

`CPMInstallationService.swift`에 상수를 추가한다.

```swift
enum CPMCompatibility {
    static let currentRevision = 1
}
```

설치 기록은 legacy `version`을 fallback으로 읽도록 구현한다.

```swift
private struct InstallationRecord: Codable {
    let digest: String
    let appVersion: String
    let cpmRevision: Int?

    private enum CodingKeys: String, CodingKey {
        case digest
        case appVersion
        case cpmRevision
        case version
    }

    init(digest: String, appVersion: String, cpmRevision: Int) {
        self.digest = digest
        self.appVersion = appVersion
        self.cpmRevision = cpmRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        digest = try container.decode(String.self, forKey: .digest)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
            ?? container.decode(String.self, forKey: .version)
        cpmRevision = try container.decodeIfPresent(Int.self, forKey: .cpmRevision)
    }
}
```

서비스에 revision을 저장하고 production initializer에서 현재 상수를 주입한다.

```swift
private let currentRevision: Int
```

```swift
self.currentRevision = CPMCompatibility.currentRevision
```

internal initializer에는 `currentRevision: Int` parameter를 추가한다.

상태 판정을 revision 중심으로 변경한다.

```swift
func status() -> CPMInstallationStatus {
    guard fileManager.fileExists(atPath: targetURL.path) else {
        return .notInstalled
    }
    guard let record = readRecord(),
          let targetDigest = try? digest(of: targetURL),
          targetDigest == record.digest else {
        return .unmanaged
    }
    guard let installedRevision = record.cpmRevision,
          installedRevision >= 0 else {
        return .installedOutdated(
            installedVersion: record.appVersion,
            availableVersion: availableVersion()
        )
    }
    if installedRevision < currentRevision {
        return .installedOutdated(
            installedVersion: record.appVersion,
            availableVersion: availableVersion()
        )
    }
    return .installedCurrent(version: record.appVersion)
}
```

설치 기록 쓰기를 변경한다.

```swift
let record = InstallationRecord(
    digest: targetDigest,
    appVersion: bundledVersion,
    cpmRevision: currentRevision
)
```

- [ ] **Step 6: cpm 설치 서비스 테스트 통과 확인**

Run:

```bash
swift test --filter CPMInstallationServiceTests
```

Expected: 모든 `CPMInstallationServiceTests` PASS.

- [ ] **Step 7: revision 기록 JSON을 직접 검증하는 테스트 추가**

```swift
func testInstallRecordsAppVersionAndCompatibilityRevision() async throws {
    let fixture = try Fixture()
    try await fixture.makeService(
        runner: CopyingPrivilegedRunner(),
        bundledVersion: "0.1.17",
        currentRevision: 3
    ).installOrUpdate()

    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.cpmInstallationRecordFile)
        ) as? [String: Any]
    )
    XCTAssertEqual(object["appVersion"] as? String, "0.1.17")
    XCTAssertEqual(object["cpmRevision"] as? Int, 3)
    XCTAssertNil(object["version"])
}
```

- [ ] **Step 8: 기록 형식 테스트 통과 확인**

Run:

```bash
swift test --filter CPMInstallationServiceTests/testInstallRecordsAppVersionAndCompatibilityRevision
```

Expected: PASS.

- [ ] **Step 9: 서비스 구현 커밋**

```bash
git add Sources/CLIProxyManagerApp/Services/CPMInstallationService.swift Tests/CLIProxyManagerAppTests/CPMInstallationServiceTests.swift
git commit -m "fix: gate cpm updates by compatibility revision" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: cpm 동기화 UI 문구 정리

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift:97-106`
- Create: `Tests/CLIProxyManagerAppTests/CPMInstallationPresentationTests.swift`

**Interfaces:**
- Consumes: `CPMInstallationStatus`
- Produces: `CPMInstallationPresentation.description(for:) -> String`

- [ ] **Step 1: UI 문구를 독립 테스트할 실패 테스트 작성**

새 파일 `CPMInstallationPresentationTests.swift`를 만든다.

```swift
import XCTest
@testable import CLIProxyManagerApp

final class CPMInstallationPresentationTests: XCTestCase {
    func testCurrentDescriptionReferencesSourceAppVersion() {
        XCTAssertEqual(
            CPMInstallationPresentation.description(
                for: .installedCurrent(version: "0.1.17")
            ),
            "Installed at /usr/local/bin/cpm (from app 0.1.17)."
        )
    }

    func testOutdatedDescriptionExplainsCpmSync() {
        XCTAssertEqual(
            CPMInstallationPresentation.description(
                for: .installedOutdated(
                    installedVersion: "0.1.15",
                    availableVersion: "0.1.17"
                )
            ),
            "Installed from app 0.1.15; cpm update included with app 0.1.17."
        )
    }
}
```

- [ ] **Step 2: presentation type 부재로 실패하는지 확인**

Run:

```bash
swift test --filter CPMInstallationPresentationTests
```

Expected: compile FAIL with `cannot find 'CPMInstallationPresentation' in scope`.

- [ ] **Step 3: 최소 presentation helper 구현**

`GeneralSettingsView.swift`에서 private computed property의 switch를 helper로 이동한다.

```swift
enum CPMInstallationPresentation {
    static func description(for status: CPMInstallationStatus) -> String {
        switch status {
        case .notInstalled:
            "Install cpm so it is available in Terminal and SSH sessions."
        case .installedCurrent(let version):
            "Installed at /usr/local/bin/cpm (from app \(version))."
        case .installedOutdated(let installedVersion, let availableVersion):
            "Installed from app \(installedVersion); cpm update included with app \(availableVersion)."
        case .unmanaged:
            "An existing cpm file is managed outside CLIProxyManager."
        }
    }
}
```

View는 helper를 호출한다.

```swift
private var cpmDescription: String {
    CPMInstallationPresentation.description(for: viewModel.cpmInstallationStatus)
}
```

- [ ] **Step 4: UI 문구 테스트 통과 확인**

Run:

```bash
swift test --filter CPMInstallationPresentationTests
```

Expected: 2 tests PASS.

- [ ] **Step 5: 관련 ViewModel 테스트 회귀 확인**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: 모든 `DashboardViewModelTests` PASS.

- [ ] **Step 6: UI 문구 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift Tests/CLIProxyManagerAppTests/CPMInstallationPresentationTests.swift
git commit -m "refactor: clarify cpm sync status copy" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: CLIProxyAPI 7.2.72 번들 변경 커밋

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`

**Interfaces:**
- Consumes: `scripts/vendor-cliproxyapi.sh 7.2.72`
- Produces: 앱 리소스에 포함된 CLIProxyAPI 7.2.72 및 검증 metadata

- [ ] **Step 1: vendored binary metadata 재검증**

Run:

```bash
Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi --version 2>&1 | grep 'CLIProxyAPI Version:'
shasum -a 256 Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi
python3 -m json.tool Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

Expected:

```text
CLIProxyAPI Version: 7.2.72, Commit: 6279bb8a, BuiltAt: 2026-07-13T10:24:29Z
2a78bdd71a252b99f8ab4839bf5bee59f92fc84e2a62556812d2d8c8e07b5d60
```

Manifest의 `version`, `commit`, `upstreamAssetSha256`, `vendoredBinarySha256`, `vendoredBinarySizeBytes`가 binary와 일치해야 한다.

- [ ] **Step 2: 바이너리 저장소 테스트 실행**

Run:

```bash
swift test --filter CLIProxyAPIBinaryStoreTests
```

Expected: 14 tests PASS.

- [ ] **Step 3: 바이너리 변경 커밋**

```bash
git add Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
git commit -m "chore: update bundled CLIProxyAPI to 7.2.72" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 전체 회귀와 development bundle 검증

**Files:**
- Verify only; no source files expected

**Interfaces:**
- Consumes: Tasks 1-3의 committed changes
- Produces: 전체 테스트와 실제 앱 번들 검증 증거

- [ ] **Step 1: 전체 테스트 실행**

Run:

```bash
swift test
```

Expected: 900개 이상 tests, 0 failures. 정확한 개수는 새 presentation tests 추가로 기존 900보다 증가한다.

- [ ] **Step 2: clean development app bundle 생성**

Run:

```bash
make distclean BUILD_DIR=build-development
make sign CONFIGURATION=debug BUILD_DIR=build-development
```

Expected: `build-development/CLIProxyManager.app` 생성 및 signing 성공.

- [ ] **Step 3: 앱 번들 내부 CLIProxyAPI 검증**

Run:

```bash
binary=$(find build-development/CLIProxyManager.app/Contents/Resources -type f -path '*/cliproxyapi/cliproxyapi' -print -quit)
"$binary" --version 2>&1 | grep 'CLIProxyAPI Version: 7.2.72'
shasum -a 256 "$binary" | grep '^2a78bdd71a252b99f8ab4839bf5bee59f92fc84e2a62556812d2d8c8e07b5d60 '
xattr -cr build-development/CLIProxyManager.app
codesign --verify --deep --strict build-development/CLIProxyManager.app
```

Expected: version과 checksum 일치, codesign exit 0.

- [ ] **Step 4: build artifact 정리와 repository 상태 확인**

Run:

```bash
rm -rf build-development
git diff --check
git status --short --branch
```

Expected: untracked build artifact 없음, source working tree clean.

- [ ] **Step 5: 최종 이력 확인**

Run:

```bash
git log --oneline -5
```

Expected: 설계 문서, cpm revision, UI copy, CLIProxyAPI binary 커밋이 분리되어 표시된다.
