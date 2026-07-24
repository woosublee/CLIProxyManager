# Usage HUD 계정 버튼 시각 개선 설계

**작성일:** 2026-07-25  
**상태:** 승인됨 — 구현 진행 중

## 배경

계정별 Usage HUD 표시 관리 기능은 정상적으로 동작하지만, 메인 계정 카드의 현재 버튼은 `chart.bar.xaxis` 아이콘과 선택 배경을 사용한다. 실제 development build 확인 결과 이 표현은 주변의 `gearshape`, `ellipsis`보다 시각적으로 강하고, 구독 통계 기능처럼 보여 “별도 HUD 창에 표시”한다는 의미도 충분히 전달하지 못한다.

또한 Expanded HUD에서 숨긴 계정을 다시 표시할 때 새로 추가되는 계정 행만 순간적으로 깜빡인다. 계정을 숨길 때는 문제가 없었다. Compact에서도 계정 추가 피드백이 Expanded와 일관되도록 동일한 insertion 전환을 적용한다.

## 목표

1. Usage HUD 버튼을 기존 계정 카드 action과 같은 위계로 정리한다.
2. 버튼이 통계 기능이 아니라 별도 HUD window 표시 설정임을 전달한다.
3. 표시 상태는 명확히 구분하되 선택 배경으로 과도하게 강조하지 않는다.
4. Expanded와 Compact HUD에서 계정을 다시 표시할 때 새 행에 동일한 짧은 fade-in을 적용한다.
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

Expanded HUD에서 계정을 다시 표시하면 기존 계정은 안정적으로 유지되지만 새로 추가되는 계정 행만 순간적으로 번쩍이거나 잘렸다 나타난다. 제거 시에는 문제가 없다.

Provider 목록은 계정 추가와 함께 자연 높이가 증가하고 AppKit panel이 fitting size로 조정된다. 새 행이 즉시 완전 불투명으로 그려지면 기존 panel 높이에서 새 높이로 맞춰지는 한 프레임의 시각 변화가 깜빡임처럼 보일 수 있다. Compact에서도 같은 조작에 같은 시각 피드백을 제공한다.

### 채택 동작

- Expanded와 Compact provider ID 목록에 새 ID가 추가될 때 새 계정 행에만 opacity insertion transition을 적용한다.
- duration: `0.12`초
- timing: `easeOut`
- removal transition: identity — 숨길 때는 두 모드 모두 현재처럼 즉시 제거한다.
- 기존 계정 행과 header에는 opacity 변화를 적용하지 않는다.
- layout space와 panel fitting resize는 즉시 새 상태를 반영한다.
- 이동, scale, blur 또는 전체 목록 crossfade를 추가하지 않는다.

SwiftUI 구현은 stack-level implicit animation을 사용하지 않고, 각 모드의 새 account row에 적용되는 insertion transition 자체에 animation을 결합한다.

```swift
private var accountTransition: AnyTransition {
    reduceMotion
        ? .identity
        : .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12)),
            removal: .identity
        )
}
```

이 transition만 새 행에 적용하면 기존 행의 위치·사용량 값과 removal reflow는 animation transaction의 영향을 받지 않는다. empty state에서 첫 provider가 추가될 때도 새 행이 자체 transition을 소유한다. Compact의 숨겨진 measurement stack에는 `.identity` transition을 전달하고 Usage HUD의 기존 display-mode blur/opacity transition에는 영향을 주지 않는다.

## Reduce Motion

`accessibilityReduceMotion`이 활성화되면 Expanded와 Compact 모두 insertion animation을 사용하지 않는다. 계정 행과 panel size는 최종 상태로 즉시 갱신한다.

기존 mode transition의 Reduce Motion 정책은 변경하지 않는다.

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

- Expanded와 Compact account row에 같은 asymmetric transition이 존재한다.
- insertion은 opacity이고 removal은 identity다.
- animation duration은 `0.12`, timing은 `easeOut`이다.
- animation은 stack이 아니라 insertion transition 자체에만 결합한다.
- 기존 행의 위치·값, 전체 HUD, header에는 implicit animation을 적용하지 않는다.
- Compact의 measurement stack에는 identity transition만 사용한다.
- Reduce Motion에서는 두 모드의 account transition이 identity다.

### 최종 검증

1. 관련 focused tests
2. 전체 `swift test`
3. `CONFIGURATION=debug` development app bundle build
4. 앱 실행과 수동 확인은 사용자가 수행

수동 확인 항목은 다음과 같다.

- `macwindow` 아이콘이 gear 및 ellipsis와 자연스럽게 어울리는지
- 표시 중과 숨김 상태가 배경 없이도 구분되는지
- 계정을 숨길 때 기존 즉시 제거 동작이 유지되는지
- Expanded와 Compact에서 다시 켤 때 새 계정만 같은 속도로 부드럽게 나타나고 기존 계정은 깜빡이지 않는지
- 두 모드에서 계정을 숨길 때 기존처럼 즉시 제거되는지
- Reduce Motion에서 계정이 즉시 나타나는지

## 완료 조건

- 계정 카드 HUD 버튼이 `macwindow`를 사용한다.
- 버튼의 선택 배경이 제거된다.
- active/inactive 상태가 foreground와 opacity로 구분된다.
- 모든 account status의 버튼 위치와 click target이 유지된다.
- Expanded와 Compact에서 새로 추가되는 계정 행만 동일한 120ms fade-in을 사용한다.
- 제거는 두 모드 모두 즉시 처리되고 Reduce Motion에서는 insertion도 즉시 처리된다.
- 저장·필터·메뉴바·usage backend 동작에 회귀가 없다.
- 자동 테스트와 debug development bundle build가 통과한다.
