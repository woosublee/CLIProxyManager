# Usage Warning Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용량 stale 경고를 expanded HUD와 메뉴바의 첫 usage row에 수직 중앙 정렬하고, compact HUD에서는 기존 avatar 위치를 유지한 채 avatar 우측에 표시한다.

**Architecture:** snapshot window별 경고 배치 정책을 순수 presentation 타입으로 분리해 첫 행만 아이콘을 표시하고 모든 행이 동일한 trailing 공간을 예약하도록 한다. 공통 SwiftUI row wrapper가 usage line과 고정 크기 warning slot을 중앙 정렬하며, compact presentation은 header indicator와 placeholder indicator를 명시적으로 구분한다.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- `SubscriptionUsageWarningIcon`의 색상, tooltip, accessibility label 의미를 유지한다.
- compact provider avatar의 기존 위치와 정상 snapshot의 레이아웃 크기를 유지한다.
- loading, disabled, unavailable 및 empty snapshot placeholder indicator 동작은 유지한다.
- window geometry, HUD 전환 애니메이션, 사용량 조회·cache 로직은 변경하지 않는다.
- 자동 검증은 전체 `swift test`와 격리된 development app bundle 생성까지 수행한다.
- 앱 실행 및 최종 수동 UI 확인은 사용자가 수행한다.

## File Structure

- `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift`: 공통 warning row presentation, 고정 warning slot, 중앙 정렬 wrapper를 소유한다.
- `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`: row가 있는 snapshot용 header indicator와 placeholder용 inline indicator를 구분한다.
- `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`: expanded snapshot row에 공통 warning wrapper를 적용한다.
- `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift`: 메뉴바 snapshot row에 공통 warning wrapper를 적용한다.
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`: header indicator를 avatar 우측 overlay로 표시하고 row 아래 indicator를 제거한다.
- `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift`: 첫 행 warning 및 trailing 공간 예약 정책을 검증한다.
- `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`: header/placeholder indicator 분기와 정상 상태 회귀를 검증한다.

---

### Task 1: Snapshot warning row 정책과 공통 정렬 wrapper

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift`

**Interfaces:**
- Produces: `SubscriptionUsageWarningRowPresentation`, `subscriptionUsageWarningRows(snapshot:warning:)`, `SubscriptionUsageWarningAlignedRow<Content>`
- Consumes: `SubscriptionUsageSnapshot`, `UsageWindow`, `SubscriptionUsageIssue`, 기존 `SubscriptionUsageWarningIcon`

- [ ] **Step 1: 첫 행 warning 배치와 정상 상태 회귀 테스트를 작성한다**

`SubscriptionUsageWarningIconTests`에 다음 테스트를 추가한다.

```swift
func testWarningRowsShowIconOnlyOnFirstRowAndReserveEqualTrailingSpace() {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [
            .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
            .init(id: "secondary", label: "Secondary", usedPercent: 30, resetAt: nil)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let rows = subscriptionUsageWarningRows(snapshot: snapshot, warning: .credentialExpired)

    XCTAssertEqual(rows.map(\.window.id), ["primary", "secondary"])
    XCTAssertEqual(rows.map(\.warning), [.credentialExpired, nil])
    XCTAssertEqual(rows.map(\.reservesWarningSpace), [true, true])
}

func testAvailableRowsDoNotReserveWarningSpace() {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [
            .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
            .init(id: "secondary", label: "Secondary", usedPercent: 30, resetAt: nil)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let rows = subscriptionUsageWarningRows(snapshot: snapshot, warning: nil)

    XCTAssertEqual(rows.map(\.warning), [nil, nil])
    XCTAssertEqual(rows.map(\.reservesWarningSpace), [false, false])
}
```

- [ ] **Step 2: 새 테스트가 실패하는지 확인한다**

Run:

```bash
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: `subscriptionUsageWarningRows` 또는 `SubscriptionUsageWarningRowPresentation`을 찾을 수 없어 compile failure.

- [ ] **Step 3: 최소 presentation 정책과 공통 warning row를 구현한다**

`SubscriptionUsageWarningIcon.swift`에 다음 타입을 추가한다.

```swift
struct SubscriptionUsageWarningRowPresentation: Equatable, Identifiable {
    let window: UsageWindow
    let warning: SubscriptionUsageIssue?
    let reservesWarningSpace: Bool

    var id: String { window.id }
}

func subscriptionUsageWarningRows(
    snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?
) -> [SubscriptionUsageWarningRowPresentation] {
    snapshot.windows.enumerated().map { index, window in
        SubscriptionUsageWarningRowPresentation(
            window: window,
            warning: index == snapshot.windows.startIndex ? warning : nil,
            reservesWarningSpace: warning != nil
        )
    }
}

enum SubscriptionUsageWarningLayout {
    static let iconFrameSize = CGSize(width: 12, height: 12)
    static let inlineSpacing: CGFloat = 6
    static let compactAvatarTrailingOffset: CGFloat = 10
}

struct SubscriptionUsageWarningAlignedRow<Content: View>: View {
    let warning: SubscriptionUsageIssue?
    let reservesWarningSpace: Bool
    let lastUpdatedAt: Date
    @ViewBuilder let content: Content

    init(
        warning: SubscriptionUsageIssue?,
        reservesWarningSpace: Bool,
        lastUpdatedAt: Date,
        @ViewBuilder content: () -> Content
    ) {
        self.warning = warning
        self.reservesWarningSpace = reservesWarningSpace
        self.lastUpdatedAt = lastUpdatedAt
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if reservesWarningSpace {
            HStack(spacing: SubscriptionUsageWarningLayout.inlineSpacing) {
                content
                warningSlot
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var warningSlot: some View {
        if let warning {
            SubscriptionUsageWarningIcon(
                issue: warning,
                lastUpdatedAt: lastUpdatedAt
            )
            .frame(
                width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                height: SubscriptionUsageWarningLayout.iconFrameSize.height
            )
        } else {
            Color.clear
                .frame(
                    width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                    height: SubscriptionUsageWarningLayout.iconFrameSize.height
                )
                .accessibilityHidden(true)
        }
    }
}
```

`Foundation`의 `CGSize`와 `CGFloat`은 기존 SwiftUI import로 사용할 수 있다. `HStack` 기본 vertical alignment인 `.center`가 usage line과 warning slot을 중앙 정렬한다.

- [ ] **Step 4: focused test를 통과시킨다**

Run:

```bash
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: 모든 `SubscriptionUsageWarningIconTests` PASS.

- [ ] **Step 5: Task 1을 커밋한다**

```bash
git add Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift Tests/CLIProxyManagerAppTests/SubscriptionUsageWarningIconTests.swift
git commit -m "refactor: model usage warning row placement

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Compact snapshot indicator를 avatar overlay로 분리

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`

**Interfaces:**
- Consumes: `CompactUsagePresentation.indicator`, `CompactUsageIndicator`, `SubscriptionUsageWarningLayout.compactAvatarTrailingOffset`
- Produces: `CompactUsagePresentation.headerIndicator`, `CompactUsagePresentation.placeholderIndicator`

- [ ] **Step 1: compact indicator 위치 정책 테스트를 작성한다**

`CompactUsagePresentationTests`에 다음 테스트를 추가한다.

```swift
func testStaleSnapshotRoutesWarningToHeaderWithoutPlaceholderIndicator() {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )
    let presentation = compactUsagePresentation(
        for: .stale(snapshot, .credentialExpired),
        now: Date(timeIntervalSince1970: 780)
    )

    XCTAssertEqual(
        presentation.headerIndicator,
        .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
    )
    XCTAssertNil(presentation.placeholderIndicator)
}

func testPlaceholderRoutesIndicatorInlineWithoutHeaderOverlay() {
    let presentation = compactUsagePresentation(for: .loading)

    XCTAssertNil(presentation.headerIndicator)
    XCTAssertEqual(
        presentation.placeholderIndicator,
        .loading(message: "Checking subscription usage…")
    )
}

func testAvailableSnapshotHasNoHeaderOrPlaceholderIndicator() {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )
    let presentation = compactUsagePresentation(for: .available(snapshot))

    XCTAssertNil(presentation.headerIndicator)
    XCTAssertNil(presentation.placeholderIndicator)
}
```

- [ ] **Step 2: 새 테스트가 실패하는지 확인한다**

Run:

```bash
swift test --filter CompactUsagePresentationTests
```

Expected: `headerIndicator`와 `placeholderIndicator`가 없어 compile failure.

- [ ] **Step 3: indicator 위치 계산 속성을 구현한다**

`CompactUsagePresentation`에 다음 computed properties를 추가한다.

```swift
var headerIndicator: CompactUsageIndicator? {
    rows.isEmpty ? nil : indicator
}

var placeholderIndicator: CompactUsageIndicator? {
    rows.isEmpty ? indicator : nil
}
```

- [ ] **Step 4: compact view에서 snapshot warning을 avatar 우측으로 이동한다**

`CompactUsageAccountView`의 provider header를 다음처럼 변경한다.

```swift
VStack(spacing: 4) {
    ProviderAvatar(providerID: provider.id, size: 26)
        .overlay(alignment: .trailing) {
            if let indicator = presentation.headerIndicator {
                CompactUsageIndicatorView(indicator: indicator)
                    .frame(
                        width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                        height: SubscriptionUsageWarningLayout.iconFrameSize.height
                    )
                    .offset(x: SubscriptionUsageWarningLayout.compactAvatarTrailingOffset)
            }
        }
    Text(provider.usageOverlayDisplayName)
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(provider.usageOverlayDisplayName)
        .accessibilityLabel(provider.usageOverlayDisplayName)
}
```

snapshot row card 다음의 아래 블록을 삭제한다.

```swift
if let indicator = presentation.indicator {
    CompactUsageIndicatorView(indicator: indicator)
}
```

`CompactUsagePlaceholderRow`에서는 `presentation.indicator` 대신 `presentation.placeholderIndicator`를 사용한다.

```swift
if let indicator = presentation.placeholderIndicator {
    CompactUsageIndicatorView(indicator: indicator)
}
```

- [ ] **Step 5: compact focused tests를 통과시킨다**

Run:

```bash
swift test --filter CompactUsagePresentationTests
```

Expected: 모든 `CompactUsagePresentationTests` PASS.

- [ ] **Step 6: Task 2를 커밋한다**

```bash
git add Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift
git commit -m "fix: move compact usage warning beside avatar

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Expanded HUD와 메뉴바의 첫 usage line에 warning 정렬

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift`

**Interfaces:**
- Consumes: `subscriptionUsageWarningRows(snapshot:warning:)`, `SubscriptionUsageWarningAlignedRow`
- Produces: expanded/menu snapshot의 첫 행 중앙 정렬과 행별 동일 trailing 공간

- [ ] **Step 1: expanded HUD snapshot rendering을 row presentation 기반으로 변경한다**

`usageContent`의 `.snapshot` branch를 다음으로 단순화한다.

```swift
case .snapshot(let snapshot, let warning):
    snapshotUsage(snapshot, warning: warning)
```

`snapshotUsage`를 다음 signature와 구조로 변경한다.

```swift
@ViewBuilder
private func snapshotUsage(
    _ snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?
) -> some View {
    if snapshot.windows.isEmpty {
        SubscriptionUsageWarningAlignedRow(
            warning: warning,
            reservesWarningSpace: warning != nil,
            lastUpdatedAt: snapshot.fetchedAt
        ) {
            Text("Usage details unavailable")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    } else {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(subscriptionUsageWarningRows(snapshot: snapshot, warning: warning)) { row in
                ExpandedUsageOverlayProgressRow(
                    row: row,
                    lastUpdatedAt: snapshot.fetchedAt
                )
            }
        }
    }
}
```

`ExpandedUsageOverlayProgressRow`는 `window` 대신 row presentation과 fetched date를 받고 main usage line만 warning wrapper로 감싼다.

```swift
private struct ExpandedUsageOverlayProgressRow: View {
    let row: SubscriptionUsageWarningRowPresentation
    let lastUpdatedAt: Date

    var body: some View {
        let window = row.window
        let percent = min(max(window.usedPercent, 0), 100)
        VStack(alignment: .leading, spacing: 2) {
            SubscriptionUsageWarningAlignedRow(
                warning: row.warning,
                reservesWarningSpace: row.reservesWarningSpace,
                lastUpdatedAt: lastUpdatedAt
            ) {
                HStack(spacing: 8) {
                    Text(subscriptionUsageDisplayLabel(for: window))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    ProgressView(value: percent, total: 100)
                        .tint(subscriptionUsageProgressTone(for: percent).color)
                        .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if let resetAt = window.resetAt {
                Text("Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 36)
            }
        }
    }
}
```

- [ ] **Step 2: 메뉴바 snapshot rendering을 같은 정책으로 변경한다**

`.snapshot` branch를 다음으로 변경한다.

```swift
case .snapshot(let snapshot, let warning):
    snapshotUsage(snapshot, warning: warning)
```

`snapshotUsage`는 expanded와 동일하게 empty state를 공통 wrapper로 감싸고, window가 있으면 row presentation을 순회한다.

```swift
@ViewBuilder
private func snapshotUsage(
    _ snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?
) -> some View {
    if snapshot.windows.isEmpty {
        SubscriptionUsageWarningAlignedRow(
            warning: warning,
            reservesWarningSpace: warning != nil,
            lastUpdatedAt: snapshot.fetchedAt
        ) {
            Text("Usage details unavailable")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    } else {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(subscriptionUsageWarningRows(snapshot: snapshot, warning: warning)) { row in
                usageWindow(row, lastUpdatedAt: snapshot.fetchedAt)
            }
        }
    }
}
```

`usageWindow`의 main line에 wrapper를 적용한다.

```swift
private func usageWindow(
    _ row: SubscriptionUsageWarningRowPresentation,
    lastUpdatedAt: Date
) -> some View {
    let window = row.window
    let percent = min(max(window.usedPercent, 0), 100)
    return VStack(alignment: .leading, spacing: 2) {
        SubscriptionUsageWarningAlignedRow(
            warning: row.warning,
            reservesWarningSpace: row.reservesWarningSpace,
            lastUpdatedAt: lastUpdatedAt
        ) {
            HStack(spacing: 7) {
                Text(subscriptionUsageDisplayLabel(for: window))
                    .frame(width: 24, alignment: .leading)
                    .foregroundStyle(.secondary)
                ProgressView(value: percent, total: 100)
                    .tint(subscriptionUsageProgressTone(for: percent).color)
                    .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
                    .frame(minWidth: 72, maxWidth: .infinity)
                    .layoutPriority(1)
                Text("\(Int(percent.rounded()))%")
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10.5, design: .monospaced))
        }

        if let resetAt = window.resetAt {
            Text("Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}
```

기존 outer `HStack(alignment: .top)`과 warning `.padding(.top, 1)`은 두 화면 모두 삭제한다.

- [ ] **Step 3: 관련 focused tests와 compile을 확인한다**

Run:

```bash
swift test --filter 'SubscriptionUsageWarningIconTests|CompactUsagePresentationTests|UsageOverlaySurfaceLayoutTests'
```

Expected: 관련 테스트 전체 PASS, app target compile 성공.

- [ ] **Step 4: Task 3을 커밋한다**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift
git commit -m "fix: align usage warnings with first row

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 전체 회귀 및 development bundle 검증

**Files:**
- Verify only; source 변경 없음

**Interfaces:**
- Consumes: Tasks 1~3의 최종 구현
- Produces: 테스트와 development app bundle 검증 근거

- [ ] **Step 1: diff 형식을 점검한다**

Run:

```bash
git diff --check main...HEAD
git status --short
```

Expected: whitespace error 없음. 계획된 파일 외 예상하지 못한 변경 없음.

- [ ] **Step 2: 전체 테스트를 실행한다**

Run:

```bash
swift test
```

Expected: 모든 test PASS. 기존 Swift 6 `Sendable` 및 deprecated API warning은 별도 이슈이며 실패로 취급하지 않는다.

- [ ] **Step 3: 격리된 development app bundle을 생성한다**

Run:

```bash
BUILD_DIR=$(mktemp -d /tmp/cliproxymanager-issue82.XXXXXX)
make bundle CONFIGURATION=debug BUILD_DIR="$BUILD_DIR"
test -x "$BUILD_DIR/CLIProxyManager.app/Contents/MacOS/CLIProxyManager"
printf 'Development bundle: %s\n' "$BUILD_DIR/CLIProxyManager.app"
```

Expected: `Bundled .../CLIProxyManager.app`와 development bundle 경로 출력.

- [ ] **Step 4: 최종 상태를 확인한다**

Run:

```bash
git status --short
git log --oneline main..HEAD
```

Expected: working tree clean. 설계, 계획, presentation 정책, compact 배치, expanded/menu 정렬 커밋이 표시됨.

- [ ] **Step 5: 사용자 수동 확인 항목을 보고한다**

사용자에게 development app에서 다음 항목을 확인하도록 안내한다.

1. stale 상태에서 expanded HUD 경고가 첫 usage line과 수직 중앙 정렬되는지
2. 메뉴바 경고가 첫 usage line과 수직 중앙 정렬되는지
3. compact HUD 경고가 avatar 오른쪽에 있고 avatar 위치가 정상 상태와 동일한지
4. compact HUD 높이가 stale 경고 때문에 늘어나지 않는지
5. 정상 사용량 상태의 세 화면 레이아웃에 회귀가 없는지
