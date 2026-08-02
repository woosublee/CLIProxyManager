# Legacy Artifact Target 경고 숨김 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 정상 legacy CLIProxyAPI artifact의 `legacyArtifactTargetInferred` 상태를 모든 사용자-facing compatibility 출력에서 제거하면서 실제 호환성 차단과 내부 migration 판단은 보존한다.

**Architecture:** `RuntimeCompatibilityReport`와 binary store는 legacy finding을 계속 생성·사용한다. `CPMStatus.Compatibility`를 presentation boundary로 삼아 legacy finding을 제외하고, 제외 후 finding이 없으면 표시용 disposition을 `.allowed`로 정규화한다. Dashboard와 Settings는 이미 공통 ViewModel presentation을 사용하므로 이를 `CPMStatus.Compatibility` 기반으로 전환해 CLI와 같은 필터 규칙을 공유한다.

**Tech Stack:** Swift 6, XCTest, Swift Package Manager, SwiftUI

## Global Constraints

- `legacyArtifactTargetInferred`는 internal `RuntimeCompatibilityReport`와 `CLIProxyAPIBinaryStore`의 target 추론·backfill 흐름에 남겨야 한다.
- target mismatch, OS/architecture mismatch, translated execution, shell, Claude Code 관련 actionable finding은 계속 사용자에게 표시해야 한다.
- 사용자-facing compatibility finding이 legacy-only filtering 후 비어 있으면 표시용 disposition은 반드시 `.allowed`여야 한다.
- 외부에 공개되는 테스트 fixture와 문자열에는 실제 이메일 대신 `example.com` 기반 값을 사용한다.

---

## File Structure

- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift` — `RuntimeCompatibilityReport`를 public CLI/UI status model로 변환할 때 legacy-only finding과 warning disposition을 정규화한다.
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift` — Dashboard와 General Settings가 공유하는 compatibility presentation이 정규화된 `CPMStatus.Compatibility`를 사용하게 한다.
- Modify: `Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift` — internal legacy finding 보존과 public status filtering·disposition 정규화를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` — legacy-only 상태가 Dashboard 및 Settings 공통 presentation에서 사라지고 실제 blocker는 남는지 검증한다.

### Task 1: CLI/UI status용 legacy finding 필터와 disposition 정규화

**Files:**
- Modify: `Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift:171-235`
- Test: `Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift:116-143`

**Interfaces:**
- Consumes: `RuntimeCompatibilityReport.findings: [CompatibilityFinding]`, `RuntimeCompatibilityReport.decision(for: .startProxy)`.
- Produces: `CPMStatus.Compatibility.init(report:)`가 public `findings`에서 `legacyArtifactTargetInferred`를 제외하고, 제외 후 finding이 없을 때 `disposition == .allowed`를 보장한다.
- Preserves: `RuntimeCompatibilityPolicy.current.report(...)`는 legacy artifact에서 `.legacyArtifactTargetInferred` finding 및 `.allowedWithWarnings` start decision을 계속 반환한다.

- [ ] **Step 1: legacy-only public status가 warning을 노출하지 않는 failing test를 작성한다**

`Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift`의 `testLegacyArtifactInferenceWarnsUntilExplicitTargetBackfill`에서 public status assertion을 다음으로 바꾼다. internal report assertion은 유지한다.

```swift
let compatibility = CPMStatus.Compatibility(report: legacy)
XCTAssertEqual(compatibility.disposition, .allowed)
XCTAssertTrue(compatibility.findings.isEmpty)
```

같은 테스트의 기존 internal assertions는 유지한다.

```swift
XCTAssertEqual(legacy.decision(for: .startProxy).disposition, .allowedWithWarnings)
XCTAssertTrue(legacy.findings.contains(.legacyArtifactTargetInferred))
```

- [ ] **Step 2: 변경한 테스트가 실패하는지 확인한다**

Run:

```bash
swift test --filter RuntimeCompatibilityTests/testLegacyArtifactInferenceWarnsUntilExplicitTargetBackfill
```

Expected: FAIL because `CPMStatus.Compatibility(report:)` still returns `allowedWithWarnings` and a `legacyArtifactTargetInferred` public finding.

- [ ] **Step 3: 최소 filtering 구현을 작성한다**

`CPMStatus.Compatibility.init(report:)`에서 legacy finding을 제외한 목록을 먼저 만든 뒤, 그 목록으로 public finding을 생성한다. filtered finding이 없으면 disposition을 `.allowed`로 설정한다.

```swift
public init(report: RuntimeCompatibilityReport) {
    let visibleFindings = report.findings.filter { finding in
        if case .legacyArtifactTargetInferred = finding {
            return false
        }
        return true
    }
    disposition = visibleFindings.isEmpty
        ? .allowed
        : report.decision(for: .startProxy).disposition
    findings = visibleFindings.map { Self.finding($0, report: report) }
}
```

`private static func finding(_:report:)`의 `.legacyArtifactTargetInferred` case를 삭제한다. filtering contract상 도달 불가능하며, user-facing recovery copy도 더 이상 유지하지 않는다.

- [ ] **Step 4: legacy finding과 실제 blocker가 공존할 때 blocker를 보존하는 테스트를 추가한다**

같은 test file에 direct report fixture로 blocker와 legacy finding을 함께 제공하는 테스트를 추가한다.

```swift
func testStatusCompatibilityHidesLegacyFindingButKeepsBlocker() {
    let report = RuntimeCompatibilityReport(
        findings: [
            .legacyArtifactTargetInferred,
            .unsupportedArchitecture(expected: .arm64, actual: .x86_64),
        ],
        decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
            (action, CompatibilityDecision(action: action, disposition: .blocked))
        })
    )

    let compatibility = CPMStatus.Compatibility(report: report)

    XCTAssertEqual(compatibility.disposition, .blocked)
    XCTAssertEqual(compatibility.findings.map(\.code), ["unsupportedArchitecture"])
}
```

- [ ] **Step 5: Core compatibility tests가 통과하는지 확인한다**

Run:

```bash
swift test --filter RuntimeCompatibilityTests
```

Expected: PASS. The legacy policy finding remains internally observable, but its public status representation is empty and `allowed`; an actual blocker remains visible.

- [ ] **Step 6: 변경 사항을 커밋한다**

```bash
git add Sources/CLIProxyManagerCore/CLI/RuntimeCommandServices.swift Tests/CLIProxyManagerCoreTests/RuntimeCompatibilityTests.swift
git commit -m "fix: hide inferred legacy target warning"
```

### Task 2: Dashboard 및 Settings 공통 presentation을 정규화된 status에 연결

**Files:**
- Modify: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift:270-276`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:102-129`

**Interfaces:**
- Consumes: `CPMStatus.Compatibility(report: compatibilityReport)` from Task 1.
- Produces: `DashboardViewModel.compatibilityPresentation: (isBlocked: Bool, text: String)?` returns `nil` for legacy-only reports; Dashboard and `GeneralSettingsView` consequently render no warning row or banner.
- Preserves: `DashboardViewModel.compatibilityReport` and all `can*ForCompatibility` action gates continue to consume the unmodified `RuntimeCompatibilityReport`.

- [ ] **Step 1: legacy-only Dashboard/Settings presentation이 없는 failing test로 교체한다**

`Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`의 `testLegacyInferencePresentationIncludesSanitizedFindingCode` 이름을 `testLegacyInferenceDoesNotCreateUserFacingCompatibilityPresentation`으로 바꾸고 assertions를 다음으로 교체한다.

```swift
XCTAssertNil(viewModel.compatibilityPresentation)
XCTAssertTrue(viewModel.compatibilityReport.findings.contains(.legacyArtifactTargetInferred))
XCTAssertEqual(
    viewModel.compatibilityReport.decision(for: .startProxy).disposition,
    .allowedWithWarnings
)
```

이렇게 하면 internal policy state는 유지하지만 Dashboard와 Settings가 공유하는 presentation만 없어지는 결과를 검증한다.

- [ ] **Step 2: 변경한 App test가 실패하는지 확인한다**

Run:

```bash
swift test --filter DashboardViewModelTests/testLegacyInferenceDoesNotCreateUserFacingCompatibilityPresentation
```

Expected: FAIL because `compatibilityPresentation` currently reads the raw report and returns legacy finding text.

- [ ] **Step 3: ViewModel이 public compatibility status를 사용하도록 최소 구현을 작성한다**

`DashboardViewModel.compatibilityPresentation`에서 raw report finding을 직접 읽는 대신 `CPMStatus.Compatibility(report: compatibilityReport)`를 만든다. status findings가 비어 있으면 `nil`을 반환하고, 첫 public finding만 text에 사용한다.

```swift
var compatibilityPresentation: (isBlocked: Bool, text: String)? {
    let summary = CPMStatus.Compatibility(report: compatibilityReport)
    guard let finding = summary.findings.first else { return nil }
    return (
        isBlocked: summary.disposition == .blocked,
        text: "\(finding.code): \(finding.recovery)"
    )
}
```

`GeneralSettingsView`와 `DashboardView`는 이 property를 이미 공유하므로 수정하지 않는다.

- [ ] **Step 4: raw report blocker가 Dashboard/Settings presentation에 남는 regression test를 추가한다**

`DashboardViewModelTests`에 `FixedCompatibilityAuthorizer`로 blocker report를 주입하는 테스트를 추가한다.

```swift
func testCompatibilityPresentationKeepsActualBlocker() async {
    let report = RuntimeCompatibilityReport(
        findings: [.unsupportedArchitecture(expected: .arm64, actual: .x86_64)],
        decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
            (action, CompatibilityDecision(action: action, disposition: .blocked))
        })
    )
    let viewModel = DashboardViewModel(/* existing stub dependencies */, compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: report), claudeConnector: connectedClaudeConnector())

    await viewModel.refresh()

    XCTAssertEqual(viewModel.compatibilityPresentation?.isBlocked, true)
    XCTAssertTrue(viewModel.compatibilityPresentation?.text.contains("unsupportedArchitecture") == true)
}
```

Use the same `DashboardViewModel` initializer dependencies and stubs as the renamed legacy test rather than introducing new test doubles.

- [ ] **Step 5: focused App tests가 통과하는지 확인한다**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: PASS. A legacy-only report creates no Dashboard banner or Settings warning row through the shared `compatibilityPresentation`; actual blockers remain presented.

- [ ] **Step 6: 변경 사항을 커밋한다**

```bash
git add Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift
git commit -m "fix: suppress legacy compatibility presentation"
```

### Task 3: CLI status JSON과 전체 관련 테스트 검증

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift:625-656`

**Interfaces:**
- Consumes: filtered `CPMStatus.Compatibility` from Task 1 and existing `RuntimeServicesDouble(compatibility:)` command injection.
- Produces: `cpm status --json` includes `compatibility.disposition: "allowed"` and an empty `findings` array for a legacy-only report, never serializing `legacyArtifactTargetInferred`.

- [ ] **Step 1: CLI JSON output의 legacy warning 제거를 검증하는 failing test를 추가한다**

`Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`의 status JSON tests 근처에 다음 테스트를 추가한다.

```swift
func testStatusJSONHidesLegacyArtifactTargetInference() async throws {
    let output = OutputDouble(isInteractive: false)
    let report = RuntimeCompatibilityPolicy.current.report(
        environment: .init(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .arm64,
            loginShell: "/bin/zsh"
        ),
        artifacts: .init(bundled: .legacy, active: nil, pending: nil),
        claude: .notChecked
    )
    let command = makeRuntimeCommand(
        output: output,
        services: RuntimeServicesDouble(compatibility: CPMStatus.Compatibility(report: report))
    )

    try await command.run(arguments: ["status", "--json"])

    let text = output.stdout.joined()
    XCTAssertFalse(text.contains("legacyArtifactTargetInferred"))
    XCTAssertTrue(text.contains("\"disposition\" : \"allowed\""))
    XCTAssertTrue(text.contains("\"findings\" : [\n\n    ]"))
}
```

If the repository JSON encoder formats an empty array differently, parse the output with `JSONSerialization` and assert the nested `compatibility` dictionary fields instead of relying on whitespace.

- [ ] **Step 2: 새 CLI test가 Task 1 구현 전에는 실패하고 Task 1 이후 통과하는지 확인한다**

Run:

```bash
swift test --filter CLIProxyManagerCommandTests/testStatusJSONHidesLegacyArtifactTargetInference
```

Expected: PASS after Task 1. The JSON contains no legacy code, its compatibility disposition is `allowed`, and `findings` is empty.

- [ ] **Step 3: 모든 영향 범위 테스트를 실행한다**

Run:

```bash
swift test --filter RuntimeCompatibilityTests && swift test --filter DashboardViewModelTests && swift test --filter CLIProxyManagerCommandTests
```

Expected: PASS. The internal report still tests legacy inference, while Dashboard, Settings, and CLI status share the filtered user-facing output.

- [ ] **Step 4: 변경 사항을 커밋한다**

```bash
git add Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift
git commit -m "test: cover hidden legacy status warning"
```
