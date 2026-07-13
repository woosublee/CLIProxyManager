# Compact 사용량 HUD 설계

## 배경

현재 사용량 HUD는 300pt 폭의 별도 `NSPanel`에서 계정명, 명령어, 기간별 progress bar, 사용률, reset 시각, 갱신 상태와 수동 갱신 버튼을 모두 보여 준다. 사용량을 계속 화면에 띄워 두기에는 유용하지만, 다른 작업을 방해하지 않는 최소 크기의 상시 표시 형태가 없다.

사용자는 기존 HUD 우측 상단 X 버튼 왼쪽에 축소 전환 버튼을 추가하고, 누르면 동일한 창이 매우 좁고 세로로 긴 compact HUD로 바뀌기를 원한다. compact 상태는 Apple의 utility UI처럼 조용하고 즉각 이해할 수 있어야 하며, 같은 provider의 여러 계정도 구분할 수 있어야 한다.

## 목표

- 확장 HUD와 compact HUD를 하나의 `NSPanel`에서 전환한다.
- 확장 HUD 우측 상단에 compact 전환 버튼을 추가하고, compact HUD에는 확장 버튼을 제공한다.
- 창의 오른쪽 위 위치를 유지한 채 왼쪽과 아래쪽이 접히거나 펼쳐지는 전환을 제공한다.
- compact HUD를 약 108pt 폭으로 구성하고 계정 avatar, 짧은 계정명, 기간, 사용률만 표시한다.
- 사용자가 선택한 표시 모드를 설정에 저장하고 앱 재실행 후에도 복원한다.
- 계정 수가 많을 때 화면 높이까지 자연스럽게 늘어나고, 초과분만 내부 스크롤한다.
- 오류나 unavailable 상태에서도 계정과 행 구조를 유지하고 원인을 접근 가능하게 전달한다.
- 기존 사용량 cache, background refresh, opacity, always-on-top, 창 드래그, 세션 숨김 동작을 유지한다.

## 비목표

- compact HUD에서 수동 새로고침 제공
- compact HUD에서 reset 시각, 명령어 또는 전체 갱신 시각 표시
- compact HUD의 계정별 표시 항목 사용자화
- compact HUD만을 위한 별도 창 또는 별도 위치 저장
- 계정 순서 재배치
- 사용량 조회·cache·refresh 정책 변경
- compact HUD를 메뉴바 popover나 Widget으로 전환

## 설계 원칙

### 목적과 단순성

compact HUD의 목적은 각 계정의 현재 사용률을 최소 면적으로 빠르게 확인하는 것이다. 제목, progress bar, 명령어, reset 시각, 갱신 상태처럼 이 목적에 필수적이지 않은 정보는 숨긴다. 단순히 가장 작게 만드는 대신 같은 provider의 여러 계정을 구분할 수 있도록 짧은 계정명은 유지한다.

### 친숙성과 예측 가능성

확장과 compact는 별도 창이 아니라 같은 물체의 두 상태로 동작한다. 전환 버튼은 X 버튼 바로 왼쪽에 고정하고, compact와 expanded에서 같은 위치와 반대 의미의 symbol을 사용한다. X 버튼은 현재와 동일하게 현재 세션에서만 창을 숨긴다.

### 공간적 일관성

전환 전후의 창 `maxX`와 `maxY`를 유지한다. 축소 시 왼쪽 가장자리와 아래쪽이 오른쪽 위 방향으로 접히고, 확장 시 동일한 경로로 복원된다. 화면 경계 보정이 필요한 경우에만 anchor 위치를 안전한 범위 안으로 이동한다.

### 절제된 motion

기본 전환은 약 0.25초이며 overshoot 없이 critically damped하게 느껴져야 한다. 창 frame과 콘텐츠 전환은 같은 동작으로 인지되도록 조율하되, 사용자의 다음 입력을 막지 않는다. macOS의 Reduce Motion 설정이 켜져 있으면 frame은 즉시 바꾸고 콘텐츠는 짧은 cross-fade 또는 정적 교체로 대체한다.

### 가독성과 접근성

작은 글자는 system font와 monospaced/tabular 숫자를 사용한다. translucent material 위 secondary text의 대비를 충분히 유지한다. icon-only control과 상태 indicator에는 명확한 accessibility label과 tooltip을 제공하며, 색상만으로 상태를 전달하지 않는다.

## 저장 모델

`AppConfig.UsageOverlay`에 표시 모드를 추가한다.

```swift
public enum DisplayMode: String, Codable, Equatable, Sendable {
    case expanded
    case compact
}

public struct UsageOverlay: Codable, Equatable, Sendable {
    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var backgroundOpacity: Double
    public var displayMode: DisplayMode
}
```

정책은 다음과 같다.

- 기존 설정 파일처럼 `displayMode`가 없으면 `.expanded`로 decode한다.
- `UsageOverlayPresentationState`가 `@Published var displayMode`로 현재 세션의 mode를 소유하며, 초기값은 저장된 `config.usageOverlay.displayMode`에서 가져온다. mode 변화를 관찰해야 하는 코드는 presentation state의 publisher를 구독한다.
- `UsageOverlayWindowController`는 presentation state를 관리하고 현재 mode를 computed property로 노출한다. `UsageOverlayView`는 같은 presentation state를 관찰해 렌더링하며, 저장 중 `DashboardViewModel.config`가 rollback되더라도 표시 중인 창이 반대로 되돌아가지 않게 persisted config와 session UI state를 분리한다.
- 사용자가 전환 버튼을 누르면 controller의 session mode와 화면 상태를 먼저 바꾸고 새 모드를 설정에 저장한다.
- 저장에 실패하면 현재 세션의 화면 전환은 유지한다. 다음 실행에는 마지막으로 성공적으로 저장된 모드가 복원될 수 있으며, 오류는 기존 `saveSetting` 경로를 통해 `settingsMessage`에 전달한다.
- 외부 설정 변경으로 저장 config의 mode가 바뀌면 전환 animation이 진행 중이지 않을 때 controller의 session mode와 동기화한다.
- X 버튼이나 메뉴바의 HUD 표시·숨김은 `displayMode`를 변경하지 않는다.
- 메뉴바에서 다시 HUD를 표시하면 현재 세션의 mode로 열고, 새 앱 실행에서는 마지막으로 성공적으로 저장된 mode를 사용한다.

## View 구조

하나의 overlay shell이 공통 배경, clip shape, drag gesture, opacity와 콘텐츠 전환을 소유한다.

```text
UsageOverlayView
├── UsageOverlayChrome
│   ├── Display mode toggle
│   └── Close
└── mode content
    ├── ExpandedUsageOverlayContent
    └── CompactUsageOverlayContent
```

### `UsageOverlayView`

- `DashboardViewModel`에서 현재 provider snapshot을 만든다.
- 공통 material, corner radius, drag gesture, activation event와 refresh task를 유지한다.
- controller가 소유한 현재 session `displayMode`에 따라 expanded 또는 compact 콘텐츠를 표시한다.
- mode toggle action은 controller가 session mode, 창 frame과 persisted setting을 함께 조정할 수 있도록 callback으로 전달한다.
- expanded와 compact 콘텐츠가 동시에 layout width를 요구하지 않도록 전환 단계에서 활성 콘텐츠를 명확히 선택한다.

### `UsageOverlayChrome`

두 모드가 공유하는 우측 상단 control 영역이다.

- 확장 상태: `arrow.down.right.and.arrow.up.left` SF Symbol과 X
- compact 상태: `arrow.up.left.and.arrow.down.right` SF Symbol과 X
- 두 symbol은 프로젝트 최소 지원 버전인 macOS 15에서 제공되며, 대각선 화살표가 inward/outward 방향을 명확히 전달한다.
- 각 control은 최소 24×24pt hit target을 가진다.
- label:
  - `Show compact usage window`
  - `Show expanded usage window`
  - `Hide usage window`
- pointer press 시 즉각적인 highlight를 제공하고, 전환 animation 중에도 입력을 불필요하게 잠그지 않는다.

### `ExpandedUsageOverlayContent`

현재 HUD의 제목, 갱신 상태, refresh 버튼, 계정명, 명령어, progress bar, 사용률, reset 시각을 유지한다. 기존 expanded UI의 정보 구조와 300pt 폭은 이번 기능에서 변경하지 않는다.

### `CompactUsageOverlayContent`

폭은 108pt를 기본값으로 사용한다. 각 계정 블록은 다음 순서로 세로 배치한다.

1. 중앙 정렬 provider avatar
2. avatar 아래 짧은 계정명 한 줄
3. 기간별 사용량 행

계정명은 system font 약 10pt, semibold를 사용한다. 한 줄을 넘기지 않고 긴 이름은 말줄임 처리한다. account privacy 설정과 기존 `usageOverlayDisplayName` 정책은 변경하지 않는다.

각 사용량 행은 다음 두 열로 구성한다.

```text
5h       15%
7d        2%
1mo      43%
```

- 기간은 기존 `subscriptionUsageDisplayLabel(for:)`의 `5h`, `7d`, `1mo` 표기를 재사용한다.
- 사용률은 0~100 범위로 clamp하고 기존 HUD와 같이 반올림한 정수 퍼센트로 표시한다.
- 숫자는 monospaced 또는 tabular figures를 사용해 갱신 시 열이 흔들리지 않게 한다.
- progress bar와 reset 시각은 표시하지 않는다.
- 계정 블록 사이는 전체 폭의 강한 divider 대신 중앙부가 은은한 separator를 사용한다.
- warning은 숫자 전체의 색을 바꾸는 대신 작은 warning indicator로 표시한다.

계정이 없으면 좁은 폭에 맞는 account placeholder와 `No accounts`를 표시한다.

## Compact 상태 presentation

expanded와 compact가 원본 `AccountSubscriptionUsageState`를 각자 해석해 규칙이 어긋나지 않도록 공통 presentation helper를 둔다. helper는 다음 정보를 만든다.

- 표시할 기간 label
- 표시할 정수 퍼센트 또는 `—`
- 상태 indicator 종류
- tooltip 문구
- VoiceOver용 구체적인 상태 설명

상태별 compact 표현은 다음과 같다.

| 원본 상태 | Compact 표시 |
| --- | --- |
| 성공 snapshot | 기간 + 정수 퍼센트 |
| warning이 포함된 마지막 성공 snapshot | 기존 값 + 작은 warning indicator |
| loading이며 성공 snapshot 없음 | 퍼센트 자리에 `—` + loading indicator |
| proxy unavailable | `—` + unavailable indicator |
| subscription usage disabled | `—` + disabled indicator |
| provider/API 오류이며 성공 snapshot 없음 | `—` + warning indicator |
| snapshot에 window가 없음 | `—` + unavailable indicator |

마지막 성공 snapshot이 존재하는 동안 일시적인 refresh 실패가 발생하면 기존 cache 정책대로 마지막 성공 값을 계속 표시하고 warning indicator로 stale/error 상태만 전달한다. compact 기능은 cache 교체나 refresh 성공 판정 로직을 변경하지 않는다.

좁은 화면에 긴 오류 문구를 직접 표시하지 않는다. 구체적인 원인은 hover tooltip과 VoiceOver label에서 제공한다.

## 창 controller와 frame 전환

`UsageOverlayWindowController`는 계속 하나의 `NSPanel`만 소유한다. 별도 compact panel은 만들지 않는다.

### 크기 상수

`AppWindowMetrics`에 다음 역할의 값을 둔다.

- expanded width: 기존 300pt
- expanded minimum height: 기존 260pt
- compact width: 108pt
- expanded maximum height: 기존 720pt
- screen edge margin: 약 16pt

compact의 고정 높이는 두지 않는다. content fitting height를 사용하되 현재 screen의 visible height에서 edge margin을 뺀 값을 최대 높이로 삼는다.

### 목표 frame 계산

전환 시 controller는 현재 frame의 오른쪽 위 anchor를 저장한다.

```text
anchorX = currentFrame.maxX
anchorY = currentFrame.maxY
newOriginX = anchorX - targetWidth
newOriginY = anchorY - targetHeight
```

그 다음 target frame을 현재 panel이 위치한 screen의 `visibleFrame` 안으로 보정한다. 보정 후에도 창을 사용할 수 있도록 기존 `isFrameUsable` 정책을 유지하고, 최소 100pt 정도가 화면 안에 남아야 한다. display 구성이 바뀌어 저장 frame이 사용할 수 없으면 기존 동작처럼 화면 중앙으로 복구한다.

### 전환 순서

1. 현재 오른쪽 위 anchor와 목표 mode를 결정한다.
2. 목표 mode의 content fitting size와 최대 높이를 계산한다.
3. 목표 frame을 계산하고 screen visible frame 안으로 보정한다.
4. 설정의 `displayMode`를 갱신한다.
5. Reduce Motion이 꺼져 있으면 약 0.25초 동안 frame을 전환하고 콘텐츠를 짧게 cross-fade한다.
6. Reduce Motion이 켜져 있으면 frame을 즉시 적용하고 콘텐츠는 정적으로 교체하거나 짧은 opacity 전환만 사용한다.
7. 전환 완료 후 현재 콘텐츠의 최종 fitting size로 한 번 더 정렬한다.

content가 전환 도중 갱신되어 fitting height가 바뀌어도 우측 상단 anchor를 기준으로 새 목표 frame을 다시 계산해야 한다. controller는 `NSAnimationContext`의 현재 panel frame에서 새 target frame으로 retarget하며 이전 target frame을 시작점으로 사용하지 않는다. 새 입력이 들어오면 진행 중인 resize를 기다리지 않고 현재 frame을 기준으로 반대 mode 목표를 계산한다.

## 높이와 스크롤

header chrome은 항상 상단에 고정한다. 계정 영역만 높이 제한을 받는다. `CompactUsageOverlayContent`는 계정 stack의 자연 높이를 size preference로 측정하고, controller가 계산한 최대 계정 영역 높이와 비교해 viewport 높이를 `min(naturalHeight, maximumAccountHeight)`로 지정한다. 계정 목록은 세로 `ScrollView` 안에 두되 자연 높이가 viewport 이하이면 scrolling과 indicator를 비활성화한다.

- content가 최대 높이보다 작으면 viewport가 자연 높이를 사용해 내부 스크롤 없이 fitting height로 창을 늘린다.
- content가 현재 screen의 허용 높이를 넘으면 viewport와 창 높이를 최대값으로 제한하고 계정 영역만 스크롤한다.
- 사용자가 다른 display로 창을 드래그하거나 display 구성이 바뀌면 해당 screen 기준으로 최대 높이를 다시 계산한다.
- expanded 모드는 기존 720pt 최대 높이를 유지한다.
- compact 모드는 `min(720pt, screenVisibleHeight - 2 × edgeMargin)`을 전체 창 최대 높이로 사용하고, account viewport 최대 높이는 여기서 chrome과 outer padding 높이를 뺀 값이다.

## 기존 동작과의 관계

- `backgroundOpacity`: 두 모드에서 같은 값을 사용한다.
- `alwaysOnTop`: 동일한 panel level 설정을 유지한다.
- 창 드래그: 두 모드 모두 기존 `WindowDragGesture`를 지원한다.
- X 버튼: panel을 현재 세션에서만 숨기며 `isVisible` 저장값을 변경하지 않는다.
- 메뉴바 toggle: 현재 panel visibility만 바꾸고 마지막 display mode를 유지한다.
- background refresh: compact에서도 계속 동작한다.
- compact 전환 자체는 강제 refresh를 실행하지 않는다.
- 사용량 cache: 마지막 성공 값을 지속화하고 성공한 background 결과로만 교체하는 기존 정책을 유지한다.

## 오류 처리

- mode 저장 실패: `DashboardViewModel.config`의 persisted 값은 rollback되지만 controller의 session mode와 현재 frame은 유지하고, 기존 `saveSetting` 오류 표시 경로를 사용한다.
- content fitting size 계산 실패 또는 0에 가까운 값: mode별 minimum size로 fallback한다.
- 현재 screen을 찾지 못함: `NSScreen.main`을 사용하고, 그것도 없으면 기존 frame anchor와 mode별 minimum size를 사용한다.
- 저장 frame이 모든 screen에서 사용할 수 없음: panel을 중앙에 배치한다.
- compact에 표시할 usage window가 없음: 계정은 유지하고 `—`와 unavailable 설명을 제공한다.
- 긴 계정명: 한 줄 말줄임으로 폭을 유지하고 tooltip·accessibility label에는 전체 이름을 제공한다.

## 테스트 전략

### Core 설정 테스트

`AppConfigTests`에서 다음을 검증한다.

1. `UsageOverlay.DisplayMode`의 expanded/compact encode·decode
2. 기존 JSON에 `displayMode`가 없을 때 `.expanded` fallback
3. compact mode 저장 후 재decode 시 유지
4. 기존 opacity clamp 및 다른 usage overlay 설정과의 호환성

### App presentation 테스트

compact presentation helper를 대상으로 다음을 검증한다.

1. `usedPercent`가 0~100으로 clamp되고 정수로 반올림된다.
2. `5h`, `7d`, `1mo` label을 기존 규칙과 동일하게 사용한다.
3. loading, disabled, proxy unavailable, API 오류와 window 없음이 `—`와 적절한 indicator로 변환된다.
4. warning이 포함된 마지막 성공 snapshot은 값과 warning을 함께 유지한다.
5. tooltip과 accessibility 설명이 상태의 구체적인 원인을 포함한다.

### Window controller 테스트

`UsageOverlayWindowControllerTests`에서 다음을 검증한다.

1. expanded와 compact 목표 폭을 적용한다.
2. 축소·확장 전후 `maxX`와 `maxY`가 유지된다.
3. target frame이 screen visible frame을 벗어나면 안전하게 보정된다.
4. content가 짧으면 fitting height를 사용하고 길면 mode별 최대 높이로 clamp한다.
5. 설정 저장 실패로 persisted config가 rollback되어도 controller의 session mode와 현재 frame은 유지된다.
6. 숨긴 뒤 다시 표시해도 현재 session display mode가 유지되고, 새 controller는 저장된 mode로 초기화된다.
7. X 버튼이 저장된 visibility와 display mode를 변경하지 않는다.
8. Reduce Motion 경로에서는 비애니메이션 frame 적용을 사용한다.
9. 표시 중 content height가 변해도 오른쪽 위 anchor를 유지한다.
10. 전환 도중 반대 mode 입력이 들어오면 현재 frame에서 새 목표로 retarget한다.

animation의 미세한 시각 품질은 단위 테스트에서 시간 기반으로 검증하지 않는다. controller가 animation 여부와 duration을 올바르게 선택하고 최종 frame이 정확한지만 검증한다.

### View 테스트와 접근성 검증

가능한 순수 helper와 view state 단위에서 다음을 검증한다.

- expanded/compact mode에 맞는 accessibility label
- 긴 계정명 말줄임과 전체 이름 접근성 제공
- unavailable 상태가 색상 외 icon·label로도 전달됨
- 빈 계정 상태 표시

### 개발 빌드 런타임 검증

프로젝트 지침에 따라 개발 빌드 앱을 기준으로 검증한다.

1. expanded HUD 우측 상단에 compact 버튼이 X 왼쪽에 표시된다.
2. expanded → compact → expanded 전환에서 오른쪽 위 위치가 유지된다.
3. compact 선택 후 앱을 재실행하면 compact로 복원된다.
4. X로 숨기고 메뉴바에서 다시 표시하면 compact mode가 유지된다.
5. Claude와 Codex의 여러 계정, 동일 provider의 `personal`/`work`, 긴 계정명이 식별 가능하다.
6. `5h`, `7d`, `1mo` 및 퍼센트가 좁은 폭에서도 흔들리지 않고 정렬된다.
7. loading, disabled, proxy unavailable, stale warning과 성공 snapshot 상태를 확인한다.
8. 계정 수가 화면 높이를 넘을 때 header는 고정되고 계정 영역만 스크롤된다.
9. opacity, always-on-top, 창 드래그와 background refresh가 두 mode에서 유지된다.
10. light/dark appearance와 Increase Contrast/Reduce Transparency에서 텍스트가 읽힌다.
11. Reduce Motion에서 overshoot나 큰 resize animation 없이 상태가 바뀐다.
12. 여러 display와 해상도 변경 후 panel이 화면 밖에 남지 않는다.

## 완료 기준

- 하나의 usage overlay panel에서 expanded와 compact mode가 전환된다.
- mode toggle은 X 왼쪽에 있고 양방향 의미와 접근성 label이 명확하다.
- compact HUD는 약 108pt 폭에서 avatar, 짧은 계정명, 기간, 사용률 숫자만 기본 표시한다.
- progress bar, reset 시각, 명령어, 제목, 갱신 상태와 refresh 버튼은 compact에서 숨겨진다.
- unavailable 상태는 계정을 숨기지 않고 `—`, indicator, tooltip과 접근성 설명으로 전달된다.
- 전환 시 오른쪽 위 anchor가 유지되고 기본 motion은 약 0.25초의 절제된 비탄성 전환이다.
- Reduce Motion 설정을 존중한다.
- compact mode가 설정에 저장되어 앱 재실행과 숨김·재표시 후에도 유지된다.
- content가 화면 높이를 초과할 때만 내부 스크롤이 활성화된다.
- 기존 사용량 cache, background refresh, opacity, always-on-top, drag와 세션 숨김 동작에 회귀가 없다.
- 관련 단위 테스트와 개발 빌드 런타임 검증이 통과한다.
