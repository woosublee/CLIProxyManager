# Usage HUD 계정 콘텐츠 전환 설계

**작성일:** 2026-07-25  
**상태:** 구현 완료 · 자동 검증 완료 · development 앱 수동 확인 대기

## 배경

Expanded Usage HUD에서 숨긴 계정을 다시 표시하면 새 계정 행이 SwiftUI layout과 AppKit fitting size 계산에 즉시 참여한다. 행 자체를 opacity로 숨기거나 다음 main queue tick까지 reveal을 늦춰도 기존 행과 panel frame이 먼저 이동하므로 깜빡이는 것처럼 보였다.

Compact에도 동일한 row transition을 적용한 뒤 새로운 깜빡임이 관찰됐다. 이에 모든 계정 행 animation을 commit `bff2bf9`에서 롤백했다. 후속 구현은 행 단위 animation이나 queue timing 보정이 아니라, Expanded↔Compact mode 전환과 같은 전체 콘텐츠 concealment를 사용한다.

## 목표

계정 목록의 추가·제거와 그에 따른 panel 크기 변경을 사용자에게 한 번의 안정적인 전환으로 보여 준다.

- Expanded와 Compact가 동일한 account content transaction을 사용한다.
- Chrome은 항상 선명하고 조작 가능한 상태로 유지한다.
- 제목, 갱신 시각, 빈 상태, 계정 행을 포함한 Chrome 아래 콘텐츠 전체를 숨긴다.
- 기존 콘텐츠를 먼저 숨긴 뒤 최신 목록으로 교체한다.
- 숨겨진 상태에서 최종 fitting size로 panel을 resize한다.
- 최종 frame이 적용된 뒤 콘텐츠를 한 번만 다시 표시한다.
- 빠른 연속 변경에서는 중간 목록을 노출하지 않고 최신 상태만 표시한다.

## 비목표

- 계정 행별 insertion/removal animation을 추가하지 않는다.
- HUD 전용 계정 순서를 만들지 않는다. 기존 `accountOrder`에서 파생된 provider 순서를 유지한다.
- `hiddenAccountIDs`, 저장 형식, usage polling, management key, cache 수명주기를 변경하지 않는다.
- 메뉴바 렌더링이나 메뉴바 provider filtering을 변경하지 않는다.
- Chrome의 배치, 버튼 action, accessibility label을 변경하지 않는다.
- panel placement와 top-right anchor 정책을 변경하지 않는다.

## 핵심 원칙

### Desired와 presented를 분리한다

현재 `UsageOverlayView`는 ViewModel에서 계산한 `UsageOverlayAccountPresentation`을 즉시 렌더링한다. 새 구조에서는 같은 모델을 두 역할로 분리한다.

- **desired presentation:** ViewModel의 최신 상태에서 계산한 목표 목록과 빈 상태 메시지
- **presented presentation:** HUD의 visible SwiftUI tree가 실제로 렌더링하는 snapshot

별도 `UsageOverlayAccountContentSnapshot`을 중복 정의하지 않고 기존 `UsageOverlayAccountPresentation`을 snapshot 경계로 재사용한다. 이 모델은 이미 `[MenuBarConnectedProvider]`와 `emptyMessage`를 함께 가지며 `Equatable`이다.

`UsageOverlayView`는 `presentationState.presentedAccountPresentation`만 렌더링한다. ViewModel 변경이 발생해도 controller가 presented 값을 commit하기 전에는 새 provider가 visible tree와 fitting size 계산에 참여하지 않는다.

### Identity 변경과 값 변경을 구분한다

계정 콘텐츠 identity는 순서를 포함한 provider ID 배열이다.

```swift
presentation.providers.map(\.id)
```

- ordered ID 배열이 같으면 transaction을 시작하지 않는다.
- 표시 이름, usage snapshot, warning, 연결 상세 등 값만 바뀌면 presented presentation을 즉시 최신 값으로 교체하고 기존 non-animated content resize 흐름을 사용한다.
- ordered ID 배열이 달라지면 전체 account content transaction을 시작한다.
- provider 순서 변경도 identity 변경으로 취급한다.
- provider가 모두 비어 있는 상태에서 `emptyMessage`만 달라지는 경우에는 transaction 없이 즉시 갱신한다.

## 구성 요소

### `UsageOverlayPresentationState`

다음 UI-facing 상태를 게시한다.

- `presentedAccountPresentation`
- 기존 `isContentHiddenForModeTransition`
- coordinator의 account transition phase projection

Account phase는 다음 enum으로 표현한다. `UsageOverlayAccountTransitionCoordinator`가 authoritative phase를 소유하고, `UsageOverlayPresentationState`는 View가 관찰할 수 있도록 controller가 반영한 phase projection을 게시한다.

```swift
enum UsageOverlayAccountTransitionPhase: Equatable {
    case visible
    case concealing
    case swapping
    case resizing
    case revealing
}
```

Controller는 coordinator가 반환한 action을 적용할 때 phase projection도 같은 transaction 안에서 갱신한다. Account 콘텐츠 concealment는 `.concealing`, `.swapping`, `.resizing`에서 활성화하고 `.revealing`, `.visible`에서 해제한다.

최종 콘텐츠 표현은 mode와 account transition을 합성한다.

```swift
isContentConcealed =
    isContentHiddenForModeTransition || isContentHiddenForAccountTransition

contentBlurRadius = isContentConcealed ? 8 : 0
contentOpacity = isContentConcealed ? 0 : 1
```

따라서 한 transition이 concealment를 해제해도 다른 transition이 진행 중이면 콘텐츠가 잘못 나타나지 않는다. Chrome에는 이 값들을 적용하지 않는다.

### `UsageOverlayAccountTransitionCoordinator`

순수 상태 구조체로 다음을 소유한다.

- 증가하는 generation
- 현재 phase
- 최신 desired presentation
- transaction 활성 여부

Coordinator는 AppKit이나 SwiftUI를 직접 호출하지 않는다. 입력된 presentation과 lifecycle event에 따라 controller가 수행할 action을 결정하고, 이전 generation의 callback을 거부한다.

### `UsageOverlayWindowController`

Controller가 transaction의 유일한 실행 주체다.

- ViewModel 변경 후 최신 desired presentation 계산
- identity 비교
- conceal/reveal scheduler 실행
- hidden 상태에서 presented presentation commit
- `contentView.layoutSubtreeIfNeeded()` 이후 fitting size 계산
- 기존 `UsageOverlayFrameLayout`을 통한 top-right anchored target frame 계산
- 기존 `frameAnimator`를 통한 0.25초 panel resize
- mode transition, window lifecycle, screen geometry event와의 직렬화

`UsageOverlayView`는 snapshot 렌더링만 담당하며 timer, generation, panel resize를 소유하지 않는다.

## 정상 상태 흐름

```text
visible
  → concealing
  → swapping
  → resizing
  → revealing
  → visible
```

### 1. `visible → concealing`

ordered provider ID가 달라지면 generation을 증가시키고 최신 desired presentation을 저장한다. 기존 presented presentation은 그대로 유지한 채 account phase를 `.concealing`으로 변경한다.

SwiftUI는 Chrome 아래 콘텐츠에 0.14초 `easeInOut` blur+fade를 적용한다.

### 2. `concealing → swapping`

Conceal scheduler가 0.14초 뒤 실행된다. Callback generation이 최신 generation과 다르면 무시한다.

최신 callback이면 phase를 `.swapping`으로 바꾸고, 그 시점의 최신 desired presentation을 presented presentation에 commit한다. 이 교체는 opacity가 0이고 blur가 적용된 상태에서만 발생한다.

### 3. `swapping → resizing`

Presented snapshot 교체 후 hidden SwiftUI tree를 layout한다. 최종 `fittingSize`를 계산하고 phase를 `.resizing`으로 변경한다.

Panel frame은 현재 mode와 visible screen 범위를 사용해 top-right anchor를 유지한 target으로 계산한다. Reduce Motion이 꺼져 있으면 기존 0.25초 `easeInEaseOut` frame animation을 사용한다.

### 4. `resizing → revealing`

최신 generation의 frame completion만 phase를 `.revealing`으로 변경한다. 이때 account concealment를 해제해 최종 frame에서 0.14초 `easeInOut` blur+fade reveal을 시작한다.

### 5. `revealing → visible`

Reveal scheduler가 0.14초 뒤 최신 generation을 확인하고 `.visible`로 종료한다. 이미 화면에 나타난 snapshot이나 panel frame을 다시 변경하지 않는다.

## 빠른 연속 변경과 interrupt

모든 비동기 conceal, frame, reveal callback은 생성 당시 generation을 캡처한다. Desired presentation이 바뀌면 generation을 증가시키므로 오래된 callback은 아무 상태도 변경하지 못한다.

### Concealing 중 변경

- 최신 desired presentation만 교체한다.
- presented presentation은 계속 유지한다.
- concealment가 완료되면 중간 상태가 아니라 최신 desired presentation으로 한 번만 swap한다.
- 최신 desired의 ordered IDs가 현재 presented IDs로 돌아오면 transaction을 취소하고 현재 콘텐츠를 reveal한다.

### Swapping 또는 resizing 중 변경

- 콘텐츠는 계속 hidden 상태로 유지한다.
- 진행 중인 frame animation completion을 generation으로 무효화한다.
- 필요하면 현재 presentation frame에서 frame animation을 interrupt한다.
- presented presentation을 최신 desired 값으로 다시 교체한다.
- 최신 fitting size를 다시 계산해 같은 top-right anchor로 retarget한다.

### Revealing 중 변경

- 현재 on-screen opacity/blur 값에서 다시 concealing으로 전환한다.
- 기존 snapshot을 즉시 교체하지 않는다.
- 최신 generation의 hide→swap→resize→show 흐름을 다시 수행한다.

이 동작은 입력을 잠그지 않으며, 계정 카드 버튼은 transition 중에도 계속 조작할 수 있다.

## Mode transition과의 충돌

Mode transition이 account transaction보다 우선한다.

Mode 전환이 시작되면 다음 순서를 적용한다.

1. Account generation을 증가시켜 account scheduler와 frame completion을 무효화한다.
2. Mode concealment를 활성화한다.
3. Account concealment가 합성 상태에서 해제되어도 전체 콘텐츠는 계속 hidden 상태로 남는다.
4. Presented account presentation을 최신 desired presentation으로 commit한다.
5. Mode 전환의 hidden measurement와 fitting resize가 최신 계정 목록을 사용한다.
6. Mode resize가 끝나면 mode transition이 콘텐츠를 한 번만 reveal한다.
7. 흡수된 account transaction은 별도로 다시 실행하지 않는다.

Account transition 중 시작된 panel frame animation이 있으면 현재 presentation frame에서 interrupt하고 mode target으로 retarget한다. 기존 mode persistence 성공·실패 처리에는 관여하지 않는다.

## 저장 실패와 rollback

계정 표시 저장은 기존 `DashboardViewModel`의 optimistic update와 rollback을 그대로 사용한다. Account transition controller는 저장 결과를 알 필요가 없으며 ViewModel에서 들어오는 최신 desired presentation만 따른다.

- rollback이 concealing 중 도착해 현재 presented IDs와 다시 같아지면 swap과 resize를 생략하고 reveal한다.
- rollback이 swapping/resizing 중 도착하면 hidden 상태에서 rollback snapshot으로 다시 swap하고 fitting size를 retarget한다.
- rollback이 transaction 완료 후 도착하면 반대 방향의 새 transaction으로 처리한다.

따라서 저장 경로와 animation 경로 사이에 별도 결합을 추가하지 않는다.

## Window lifecycle과 화면 변경

### HUD 숨김 또는 session close

- 모든 account callback을 generation으로 무효화한다.
- 최신 desired presentation을 presented presentation에 즉시 commit한다.
- account phase를 `.visible`로 정리한다.
- 숨겨진 panel에는 animation을 실행하지 않는다.
- 다음 show에서 기존 unanimated fitting resize를 수행한다.

### HUD가 보이지 않는 동안 ViewModel 변경

Presented presentation을 즉시 최신 desired 값으로 유지한다. 다음 show 시 account transition 없이 최신 snapshot과 fitting size를 사용한다.

### 사용자의 panel 이동

사용자 이동이 account frame animation을 interrupt하면 콘텐츠를 hidden 상태로 유지한다. `windowDidMove`에서 사용자가 선택한 위치를 기준으로 최신 fitting size를 animation 없이 적용한 뒤 reveal한다. Programmatic frame 변경은 사용자 이동으로 취급하지 않는 기존 판별을 유지한다.

### Screen geometry 변경

Account callback과 frame completion을 무효화하고 최신 desired presentation을 commit한다. 기존 placement 복원과 screen clamp가 끝난 후 최신 fitting size를 animation 없이 적용하고 한 번만 reveal한다.

## Reduce Motion

`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`이 활성화되어 있으면 시각적 transaction을 생략한다.

1. 최신 desired presentation을 presented presentation에 즉시 commit한다.
2. SwiftUI blur/fade를 실행하지 않는다.
3. Panel fitting frame을 animation 없이 즉시 적용한다.
4. Account phase를 `.visible`로 유지한다.
5. Generation 정리와 stale callback 무효화 규칙은 동일하게 적용한다.

## Animation 값

기존 mode transition과 시각적 언어를 맞춘다.

- conceal blur+fade: `0.14`초 `easeInOut`
- blur radius: `8`
- hidden opacity: `0`
- panel resize: `0.25`초 `easeInEaseOut`
- reveal blur+fade: `0.14`초 `easeInOut`

고정 지연은 SwiftUI conceal/reveal animation 완료 시점을 controller state machine과 맞추는 용도로만 사용한다. 모든 callback은 generation guard를 가져야 한다.

## 테스트 전략

### Coordinator 단위 테스트

- 같은 ordered IDs는 transaction을 시작하지 않는다.
- 추가와 제거가 모두 `.concealing`에서 시작한다.
- provider 순서 변경을 identity 변경으로 처리한다.
- 같은 IDs의 값 변경은 immediate presented update로 처리한다.
- empty message만 바뀌면 transaction을 시작하지 않는다.
- concealing 중 여러 변경에서 마지막 desired만 남긴다.
- stale conceal/reveal callback을 거부한다.
- desired가 현재 presented IDs로 돌아오면 transaction을 취소한다.

### Presentation state 테스트

- mode concealment만 활성화된 경우 콘텐츠를 숨긴다.
- account concealment만 활성화된 경우 콘텐츠를 숨긴다.
- 둘 중 하나가 남아 있으면 다른 하나가 끝나도 콘텐츠를 표시하지 않는다.
- `.resizing → .revealing`에서만 account concealment가 해제된다.
- Chrome opacity는 모든 phase에서 `1`이다.

### Window controller 통합 테스트

주입 가능한 scheduler, `fittingSizeProvider`, `frameAnimator`, `frameAnimationInterrupter`를 사용한다.

1. 계정 identity 변경 직후 기존 presented snapshot이 유지된다.
2. Conceal 완료 전에는 snapshot과 panel frame이 바뀌지 않는다.
3. Conceal 완료 후 hidden 상태에서만 최신 snapshot으로 교체된다.
4. Snapshot 교체 후 layout과 fitting size 계산이 실행된다.
5. Frame completion 전에는 reveal하지 않는다.
6. Frame completion 후 최종 snapshot을 한 번만 reveal한다.
7. 추가와 제거가 동일한 순서를 사용한다.
8. 빠른 연속 변경에서 오래된 completion이 무시되고 마지막 목록만 표시된다.
9. Resizing 중 변경이 최신 fitting size로 retarget된다.
10. Mode 전환이 account transaction을 흡수하고 한 번만 reveal한다.
11. HUD 숨김, 사용자 이동, screen geometry 변경이 stale callback을 남기지 않는다.
12. Reduce Motion 경로가 snapshot과 frame을 즉시 적용한다.

### 기존 회귀 테스트

- `UsageOverlayAccountAnimationTests`는 row animation 부재 계약을 유지하면서 buffered content transaction 계약으로 갱신한다.
- Compact hidden measurement stack과 empty-state 실제 높이 재측정 테스트를 유지한다.
- `UsageOverlayPresentationStateTests`
- `UsageOverlayWindowControllerTests`
- 버튼 presentation 및 accessibility 테스트
- 저장 실패 rollback 테스트
- 메뉴바 provider filtering 테스트
- 전체 `swift test`
- `CONFIGURATION=debug`, `BUILD_DIR=build-development`, bundle ID `com.woosublee.CLIProxyManager.dev` development bundle 생성 및 codesign 검증

## 수동 확인 기준

수동 평가는 development 앱에서 사용자가 수행한다.

- 추가와 제거 모두 Chrome이 선명하게 유지된다.
- 콘텐츠 전체가 mode 전환과 같은 톤으로 숨겨진다.
- 새 계정 행이나 빈 상태가 panel resize 전에 나타나지 않는다.
- 숨겨진 동안 panel 크기가 top-right anchor를 유지하며 변경된다.
- 최종 frame에서 최신 콘텐츠가 한 번만 나타난다.
- Expanded와 Compact의 전환 감각이 동일하다.
- 빠르게 여러 계정을 변경해도 중간 목록이 번쩍이지 않는다.
- Mode 전환과 계정 변경이 겹쳐도 중복 reveal이 없다.

## 안전 및 검증 제약

- production bundle ID `com.woosublee.CLIProxyManager` 앱은 실행, 종료, 활성화, 재실행하거나 process를 조작하지 않는다.
- 자동 검증은 테스트, development bundle 생성, codesign까지 수행한다.
- development 앱 실행은 사용자가 명시적으로 요청한 경우에만 현재 worktree의 development bundle을 대상으로 한다.
- 기존 untracked `build-development/`는 commit하지 않는다.
