# Usage HUD 계정 버튼 시각 개선 설계

**작성일:** 2026-07-25  
**상태:** 구현 및 자동 검증 완료 — 수동 UI 확인 대기

## 배경

계정별 Usage HUD 표시 관리 기능은 정상적으로 동작하지만, 메인 계정 카드의 현재 버튼은 `chart.bar.xaxis` 아이콘과 선택 배경을 사용한다. 실제 development build 확인 결과 이 표현은 주변의 `gearshape`, `ellipsis`보다 시각적으로 강하고, 구독 통계 기능처럼 보여 “별도 HUD 창에 표시”한다는 의미도 충분히 전달하지 못한다.

또한 Expanded HUD에서 숨긴 계정을 다시 표시할 때 새로 추가되는 계정 행만 순간적으로 깜빡인다. 계정을 숨길 때는 문제가 없었다. 원인은 새 행이 자연 높이 stack에 즉시 들어가며 opacity transition을 시작한 뒤, main queue에 예약된 AppKit fitting-size resize가 panel을 정착시키는 순서 충돌이다. Compact는 별도 measurement/viewport 경로와 기존 transition-local fade를 유지하며 이번 수정 범위에서 변경하지 않는다.

## 목표

1. Usage HUD 버튼을 기존 계정 카드 action과 같은 위계로 정리한다.
2. 버튼이 통계 기능이 아니라 별도 HUD window 표시 설정임을 전달한다.
3. 표시 상태는 명확히 구분하되 선택 배경으로 과도하게 강조하지 않는다.
4. Expanded HUD에서는 새 행의 layout을 먼저 투명하게 준비하고 다음 main-queue tick에서만 짧게 reveal하여 panel resize 전 깜빡임을 없앤다. Compact는 현재 transition-local fade 동작을 유지한다.
5. 두 모드의 즉시 숨김 동작과 저장·필터·오류 처리 동작은 변경하지 않는다.
6. Reduce Motion 설정을 존중한다.

## 범위 밖

- 계정별 HUD 표시 설정의 저장 모델 변경
- HUD account filtering 또는 empty-state 변경
- 메뉴바 계정 표시 변경
- HUD window resize 정책 변경
- 계정 제거 animation 변경
- 기존 privacy `eye` 버튼 변경
- 카드 전체 action layout 재설계
- 사운드, 햅틱, bounce 또는 이동 animation 추가

## 검토한 버튼 표현

### 조용한 창 아이콘

`macwindow` SF Symbol을 사용하고 선택 배경을 제거한다. 표시 중에는 accent 색상, 숨김 상태에서는 낮은 secondary opacity로 표현한다. 기존 gear 및 more action과 가장 자연스럽게 어울리면서 HUD window라는 의미가 명확하다. 이 설계의 채택안이다.

### HUD 상태 칩

`HUD` text와 상태 dot을 작은 capsule에 표시한다. 의미는 가장 명확하지만 우측 action 영역을 넓히고, 표시 중 상태가 다른 control보다 강하게 보인다.

### 상세 정보 행에 통합

HUD control을 account detail과 privacy control 근처로 이동한다. 우측 action 영역은 단정하지만 계정 표시 설정의 발견성과 click target이 약해지며, detail visibility와 HUD visibility의 역할이 섞인다.

## 버튼 presentation

`UsageOverlayAccountButtonPresentation`은 저장 상태를 UI에 필요한 값으로 변환한다.

```swift
UsageOverlayAccountButtonPresentation(
    symbolName: "macwindow",
    accessibilityLabel: String,
    isHighlighted: Bool
)
```

상태별 표현은 다음과 같다.

### HUD 표시 중

- symbol: `macwindow`
- foreground: `BrandPalette.accent`
- opacity: `1`
- background: 없음
- help/accessibility label: `Hide from Usage HUD`

### HUD에서 숨김

- symbol: `macwindow`
- foreground: secondary 계열
- 기본 opacity: 낮게 표시
- 카드 hover 시 opacity를 높여 조작 가능한 action임을 드러냄
- background: 없음
- help/accessibility label: `Show in Usage HUD`

26×26 click target과 action 순서는 유지한다.

- Connected: `[HUD] [Settings] […]`
- Disabled: `[HUD] [Settings] […]`
- Disconnected: `[HUD] [Connect] […]`

별도의 pressed animation, scale, bounce, sound 또는 haptic feedback은 추가하지 않는다. SwiftUI Button의 기본 pointer-down interaction과 상태 색상 변경만 사용한다.

## 계정 insertion 전환

### 관찰된 증상

Expanded HUD에서 계정을 다시 표시하면 기존 계정은 안정적으로 유지되지만 새로 추가되는 계정 행만 panel이 정착하기 전에 번쩍이거나 잘렸다 나타난다. 제거 시에는 문제가 없다.

`DashboardViewModel.objectWillChange`은 `UsageOverlayWindowController.resizeToFittingContent(animated: false)`를 main queue에 예약한다. Expanded는 같은 SwiftUI update에서 새 행을 자연 높이 `VStack`에 삽입하고 opacity transition을 시작했으므로, 예약된 AppKit fitting-size resize보다 먼저 행이 부분적으로 보일 수 있었다. Compact는 별도 measurement/viewport 경로를 사용한다.

### 채택 동작

- Expanded에서 새 provider ID는 첫 render pass에 layout에 즉시 참여하되 opacity `0`으로 준비한다.
- 같은 ID는 다음 main-queue tick에서만 `easeOut(duration: 0.12)`으로 reveal한다. 이미 예약된 fitting-size resize가 먼저 정착할 수 있도록 한다.
- 초기 Expanded presentation 및 Compact에서 Expanded로 전환할 때 이미 존재하는 ID는 즉시 revealed 상태로 초기화하여 전체 목록을 fade하지 않는다.
- 기존 Expanded 행은 완전히 보이는 상태로 유지하며 opacity animation을 받지 않는다.
- 제거와 남은 행의 reflow는 즉시 처리한다. pending reveal 전에 ID가 제거되면 generation으로 예약 작업을 무효화하고 revealed state에 남기지 않는다.
- Compact는 기존 transition-local opacity fade 및 identity measurement transition을 유지하며 source와 동작을 변경하지 않는다.
- 이동, scale, blur, panel-size animation 또는 stack-level implicit animation은 추가하지 않는다.

Expanded는 순수 `ExpandedUsageOverlayInsertionState`로 revealed ID만 추적한다. provider ID 변경 시 먼저 제거된 ID를 prune하고 새 ID를 pending으로 남긴 뒤, `DispatchQueue.main.async`에서 현재 generation과 present ID를 다시 확인한다. row는 `.opacity(insertionState.isRevealed(provider.id) ? 1 : 0)` 및 `.transition(.identity)`를 사용한다.

## Reduce Motion

`accessibilityReduceMotion`이 활성화되면 Expanded도 같은 다음 main-queue tick에서 reveal하되 `withAnimation` 없이 상태만 갱신한다. Compact의 기존 Reduce Motion transition 정책과 mode transition 정책은 변경하지 않는다.

## 데이터 및 오류 처리

다음 경로는 변경하지 않는다.

- `setAccountVisibleInUsageOverlay(_:isVisible:)`
- `hiddenAccountIDs`
- 저장 실패 rollback
- usage polling과 cache
- menu bar presentation
- account deletion cleanup

저장이 성공해 provider 목록이 바뀐 뒤에만 visual transition이 발생한다. 저장 실패 시 기존 rollback 경로가 provider 목록과 버튼 상태를 되돌리므로 새 animation 전용 오류 처리는 필요하지 않다.

## 테스트 전략

### 버튼 presentation

- symbol이 `macwindow`인지 확인한다.
- 표시 중 label이 `Hide from Usage HUD`인지 확인한다.
- 숨김 상태 label이 `Show in Usage HUD`인지 확인한다.
- 표시 중 상태만 highlighted인지 확인한다.

### 카드 UI 계약

- Connected, Disabled, Disconnected branch 모두 HUD 버튼을 유지한다.
- 버튼의 26×26 frame을 유지한다.
- `.help`와 `.accessibilityLabel`을 유지한다.
- 버튼에 selected background shape/fill을 추가하지 않는다.
- active는 accent, inactive는 secondary opacity presentation을 사용한다.

### 계정 insertion

- `ExpandedUsageOverlayInsertionState`의 초기 ID는 즉시 revealed 상태다.
- `prepare`는 제거된 ID를 즉시 prune하고 새 ID만 pending으로 반환하며, `reveal`은 아직 present인 pending ID만 revealed로 만든다.
- Expanded row는 opacity `0` 상태로 layout에 먼저 참여하고 `.transition(.identity)`를 사용한다.
- provider ID 변경은 `DispatchQueue.main.async` reveal을 예약하며 generation으로 오래된 예약을 무효화한다.
- regular motion reveal만 `easeOut(duration: 0.12)` `withAnimation`으로 감싸고 Reduce Motion은 다음 tick에서 animation 없이 reveal한다.
- Expanded stack, 기존 행, header, removal reflow에는 implicit animation이 없다.
- Compact의 source와 동작은 변경하지 않으며 기존 visible transition-local fade 및 measurement identity transition을 유지한다.

### 최종 검증

1. 관련 focused tests
2. 전체 `swift test`
3. `CONFIGURATION=debug` development app bundle build
4. 앱 실행과 수동 확인은 사용자가 수행

수동 확인 항목은 다음과 같다.

- `macwindow` 아이콘이 gear 및 ellipsis와 자연스럽게 어울리는지
- 표시 중과 숨김 상태가 배경 없이도 구분되는지
- 계정을 숨길 때 기존 즉시 제거 동작이 유지되는지
- Expanded에서 다시 켤 때 새 계정 행의 layout이 먼저 안정화된 뒤 120ms reveal되고 기존 계정은 깜빡이지 않는지
- Compact의 현재 fade 동작이 유지되는지
- 두 모드에서 계정을 숨길 때 기존처럼 즉시 제거되는지
- Reduce Motion에서 Expanded 계정이 다음 run-loop tick에 animation 없이 나타나는지

## 완료 조건

- 계정 카드 HUD 버튼이 `macwindow`를 사용한다.
- 버튼의 선택 배경이 제거된다.
- active/inactive 상태가 foreground와 opacity로 구분된다.
- 모든 account status의 버튼 위치와 click target이 유지된다.
- Expanded의 새 계정 행은 transparent layout 준비 후 다음 main-queue tick에서만 120ms reveal한다.
- Compact의 기존 transition-local fade source와 동작은 변경하지 않는다.
- 제거는 두 모드 모두 즉시 처리되고 Reduce Motion에서는 Expanded reveal도 다음 tick에 animation 없이 처리된다.
- 저장·필터·메뉴바·usage backend 동작에 회귀가 없다.
- 자동 테스트와 debug development bundle build가 통과한다.
