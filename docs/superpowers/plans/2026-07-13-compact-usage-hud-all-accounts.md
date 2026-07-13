# Compact Usage HUD 전체 계정 표시 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** compact Usage HUD가 측정 전부터 계정 수에 맞는 높이를 확보하고, 화면 최대 높이를 넘으면 모든 계정에 접근할 수 있도록 기본 세로 스크롤을 활성화한다.

**Architecture:** `CompactUsageMeasurementState`가 provider ID 목록과 실제 측정 높이를 함께 관리하고, 실제 측정 전에는 계정당 120pt 추정 높이를 사용한다. `CompactUsageOverlayView`는 같은 상태 객체에서 viewport 높이와 스크롤 필요 여부를 받아 표시하며, 기존 measurement preference와 panel resize callback은 유지한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, Swift Package Manager

## Global Constraints

- Usage HUD 전체 최대 높이는 기존 `720pt`를 유지한다.
- compact 계정 viewport는 기존 `maximumAccountHeight`를 넘지 않는다.
- 계정 1개 이상은 실제 측정 전 계정당 `120pt`를 추정 높이로 사용한다.
- 실제 측정이 완료되면 추정값 대신 측정된 자연 높이를 사용한다.
- overflow 표시는 SwiftUI 기본 세로 스크롤바만 사용한다.
- expanded HUD와 관련 없는 UI 스타일 및 구조는 변경하지 않는다.
- 자동 검증은 development build까지 수행하며 앱 실행과 수동 UI 확인은 사용자가 담당한다.

---

## 파일 구조

- `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`: compact 계정 수, 추정 높이, 측정 높이, viewport 및 overflow 판단을 담당한다.
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`: 측정 상태에서 계산된 viewport와 overflow를 SwiftUI `ScrollView`에 연결한다.
- `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`: 0개, 1개, 여러 개, 작은 화면, 측정 완료, 계정 추가·삭제 회귀를 검증한다.

### Task 1: 계정 수 기반 compact viewport 계산

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift:47-96`
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift:20-41`

**Interfaces:**
- Consumes: `updateProviderIDs(_ newProviderIDs: [String]) -> Bool`, `record(height:) -> Bool`
- Produces: `viewportHeight(maximumHeight:) -> CGFloat`, `needsScrolling(maximumHeight:) -> Bool`

- [ ] **Step 1: 측정 전 계정 수와 작은 화면 동작을 검증하는 실패 테스트 작성**

`UsageOverlayPresentationStateTests`의 기존 compact measurement 테스트를 아래 사례로 정리한다.

```swift
func testCompactViewportIsZeroWithoutProviders() {
    let state = CompactUsageMeasurementState()

    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 0)
    XCTAssertFalse(state.needsScrolling(maximumHeight: 500))
}

func testCompactViewportEstimatesHeightForOneProvider() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one"]))

    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
    XCTAssertFalse(state.needsScrolling(maximumHeight: 500))
}

func testCompactViewportEstimatesHeightForMultipleProviders() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))

    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 360)
    XCTAssertFalse(state.needsScrolling(maximumHeight: 500))
}

func testCompactViewportClampsEstimateAndEnablesScrollingOnSmallScreen() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one", "two", "three", "four"]))

    XCTAssertEqual(state.viewportHeight(maximumHeight: 300), 300)
    XCTAssertTrue(state.needsScrolling(maximumHeight: 300))
}
```

측정 및 identity 변경 테스트는 다음 기대값을 사용한다.

```swift
func testCompactViewportUsesMeasuredHeightAfterMeasurement() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one", "two"]))
    XCTAssertTrue(state.record(height: 220))

    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 220)
    XCTAssertEqual(state.viewportHeight(maximumHeight: 180), 180)
    XCTAssertTrue(state.needsScrolling(maximumHeight: 180))
}

func testProviderAdditionResetsMeasurementAndUsesNewEstimate() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one"]))
    XCTAssertTrue(state.record(height: 110))

    XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))
    XCTAssertEqual(state.height, 0)
    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 360)
}

func testProviderRemovalResetsMeasurementAndUsesNewEstimate() {
    var state = CompactUsageMeasurementState()
    XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))
    XCTAssertTrue(state.record(height: 330))

    XCTAssertTrue(state.updateProviderIDs(["one"]))
    XCTAssertEqual(state.height, 0)
    XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
}
```

- [ ] **Step 2: focused test를 실행해 실패 확인**

Run:

```bash
swift test --filter UsageOverlayPresentationStateTests
```

Expected: `needsScrolling(maximumHeight:)`가 없고 측정 전 viewport가 계정 수를 반영하지 않아 FAIL.

- [ ] **Step 3: 최소 측정 상태 구현**

`CompactUsageMeasurementState`를 다음처럼 변경한다.

```swift
struct CompactUsageMeasurementState {
    static let estimatedAccountHeight: CGFloat = 120
    private(set) var height: CGFloat = 0
    private var providerIDs: [String] = []

    mutating func updateProviderIDs(_ newProviderIDs: [String]) -> Bool {
        guard providerIDs != newProviderIDs else { return false }
        providerIDs = newProviderIDs
        height = 0
        return true
    }

    mutating func record(height newHeight: CGFloat) -> Bool {
        guard newHeight > 0, abs(newHeight - height) > 0.5 else { return false }
        height = newHeight
        return true
    }

    func viewportHeight(maximumHeight: CGFloat) -> CGFloat {
        min(contentHeight, maximumHeight)
    }

    func needsScrolling(maximumHeight: CGFloat) -> Bool {
        contentHeight > maximumHeight
    }

    private var contentHeight: CGFloat {
        if height > 0 {
            return height
        }
        return CGFloat(providerIDs.count) * Self.estimatedAccountHeight
    }
}
```

- [ ] **Step 4: focused test 통과 확인**

Run:

```bash
swift test --filter UsageOverlayPresentationStateTests
```

Expected: `UsageOverlayPresentationStateTests` 전체 PASS.

- [ ] **Step 5: 변경 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift
git commit -m "fix: estimate compact HUD account height"
```

### Task 2: compact ScrollView에 overflow 상태 연결

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:64-70`

**Interfaces:**
- Consumes: `CompactUsageMeasurementState.needsScrolling(maximumHeight:) -> Bool`
- Produces: overflow일 때만 활성화되는 SwiftUI vertical `ScrollView`와 기본 indicator

- [ ] **Step 1: 기존 view 계산을 새 상태 API로 연결**

`needsScrolling`을 직접 `height`와 비교하지 않고 measurement state에 위임한다.

```swift
private var needsScrolling: Bool {
    measurementState.needsScrolling(maximumHeight: maximumAccountHeight)
}
```

기존 코드는 그대로 유지한다.

```swift
ScrollView(.vertical, showsIndicators: needsScrolling) {
    visibleAccountStack
}
.scrollDisabled(!needsScrolling)
.frame(height: viewportHeight)
```

- [ ] **Step 2: focused test와 compile 검증**

Run:

```bash
swift test --filter UsageOverlayPresentationStateTests
swift build -c debug --product CLIProxyManager
```

Expected: 두 명령 모두 exit code 0. `CompactUsageOverlayView`가 private `height` 비교 없이 새 overflow API를 사용해 compile됨.

- [ ] **Step 3: 변경 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift
git commit -m "fix: enable compact HUD overflow scrolling"
```

### Task 3: 전체 회귀 및 development bundle 검증

**Files:**
- No source changes expected
- Verify: all files changed by Tasks 1-2

**Interfaces:**
- Consumes: completed compact measurement and ScrollView changes
- Produces: issue #71 완료 조건에 대한 자동 검증 결과와 development app bundle

- [ ] **Step 1: 전체 테스트 실행**

Run:

```bash
swift test
```

Expected: 전체 XCTest suite PASS, failure 0.

- [ ] **Step 2: development app bundle 생성**

Run:

```bash
make bundle CONFIGURATION=debug BUILD_DIR=build/debug
```

Expected: exit code 0 및 마지막 출력에 다음 문구 포함.

```text
Bundled build/debug/CLIProxyManager.app
```

- [ ] **Step 3: development bundle 산출물 확인**

Run:

```bash
test -x build/debug/CLIProxyManager.app/Contents/MacOS/CLIProxyManager
test -x build/debug/CLIProxyManager.app/Contents/Helpers/cpm
test -x build/debug/CLIProxyManager.app/Contents/Helpers/cliproxy-manager
```

Expected: 세 명령 모두 exit code 0.

- [ ] **Step 4: diff와 작업 상태 검증**

Run:

```bash
git diff --check
git status --short
git log --oneline -3
```

Expected: whitespace 오류 없음. source/test 변경은 모두 커밋되어 있고 `build/debug`이 ignore된 상태이며, 이슈 #71과 무관한 tracked 변경이 없음.

- [ ] **Step 5: 사용자 수동 확인 항목 전달**

사용자가 `build/debug/CLIProxyManager.app`을 실행해 다음만 확인하도록 안내한다.

1. 계정 0개에서 기존 empty state가 유지된다.
2. 계정 1개에서 compact HUD 높이가 과도하게 늘어나지 않는다.
3. 계정 2~5개에서 화면 공간이 충분하면 모든 계정이 바로 보인다.
4. 작은 화면 또는 많은 계정에서 기본 세로 스크롤바가 보이고 마지막 계정까지 스크롤된다.
5. 계정 추가·삭제와 expanded/compact 전환 후 높이가 최신 목록에 맞게 갱신된다.

## 자체 검토

- Spec coverage: Task 1이 계정 수 기반 초기 높이, 실제 측정 대체, 계정 추가·삭제, 작은 화면 clamp를 검증한다. Task 2가 기본 스크롤바와 scroll enablement를 연결한다. Task 3이 전체 테스트와 development bundle 검증을 수행한다.
- Placeholder scan: 미완성 표식이나 구체화되지 않은 구현 단계 없음.
- Type consistency: plan 전체에서 `viewportHeight(maximumHeight:)`와 `needsScrolling(maximumHeight:)` 시그니처를 동일하게 사용한다.
