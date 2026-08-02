# 메뉴바 상태 및 Development 빌드 아이콘 설계

## 목표

메뉴바 아이콘만 보고 CLIProxyAPI 서버가 연결됨, 연결 중, 중지됨 중 어느 상태인지 파악할 수 있게 한다. 동시에 development bundle을 official build와 메뉴바 및 Dock에서 즉시 구분할 수 있게 한다.

## 범위

이번 변경은 실행 중인 앱의 아이콘 표현에만 적용한다.

- 메뉴바에서 서버 상태 3단계 표시
- 연결 중 line-draw motion
- development 메뉴바 아이콘 변형
- development Dock 및 App Switcher 아이콘 변형
- Light/Dark mode와 Reduce Motion 대응
- 상태 매핑, build channel 판별, 렌더링 테스트

다음 항목은 변경하지 않는다.

- `AppConfig`와 사용자 설정
- proxy runtime 및 상태 polling
- 앱 이름과 bundle identifier
- Finder에서 보이는 정적 development `.icns`
- development channel을 생성하는 기존 Makefile 흐름

## 승인된 시각 방향

기존 파형 마크를 모든 variant의 기준으로 유지한다.

### 서버 상태

| 상태 | 메뉴바 표현 |
| --- | --- |
| Connected | 현재 파형 아이콘을 그대로 완전히 표시 |
| Connecting | 파형이 왼쪽에서 오른쪽으로 순차적으로 그려지는 line-draw motion |
| Stopped | 현재 파형 위에 `/` 방향 사선 표시 |

오류는 별도 네 번째 아이콘을 추가하지 않고 Stopped variant로 표시한다. 상세 메뉴의 기존 `Error` 텍스트와 진단 내용은 그대로 유지한다.

### Build variant

| Build | 메뉴바 | Dock / App Switcher |
| --- | --- | --- |
| Official | 상태별 파형만 표시 | 기존 blue–purple gradient icon 유지 |
| Development | 채운 4pt continuous rounded-square 배경에서 상태별 파형을 negative space(투명 cutout)로 표시 | 기존 blue–purple gradient를 유지하되 파형을 반투명 검정으로, 얇은 주황색 rounded-square 테두리를 추가 |

Development variant도 Connected, Connecting, Stopped의 상태 의미를 동일하게 유지한다. Build 표식이 상태 표식을 대체하지 않는다.

## 상태 모델

아이콘 전용 상태를 app UI 계층에 둔다.

```swift
enum MenuBarIconState: Equatable {
    case connected
    case connecting
    case stopped
}
```

기존 runtime 상태를 다음 규칙으로 변환한다.

| `ServerControlState` | `DiagnosticStatus.severity` | 아이콘 상태 |
| --- | --- | --- |
| `.running` | `.ready` | `.connected` |
| `.starting` | 모든 값 | `.connecting` |
| `.running` | `.warning` 또는 `.error` | `.stopped` |
| `.stopping` | 모든 값 | `.stopped` |
| `.stopped` | 모든 값 | `.stopped` |
| `.error` | 모든 값 | `.stopped` |

`.stopping`은 연결을 시도하는 상태가 아니므로 Connecting motion을 사용하지 않는다. 서버가 내려가는 즉시 Stopped variant로 전환한다.

새로운 상태 저장, timer 기반 상태 polling, 사용자 preference는 추가하지 않는다. `DashboardViewModel.serverControlState`와 `DashboardViewModel.serverStatus`의 기존 `@Published` 갱신을 그대로 소비한다.

## Build channel 판별

작은 독립 타입이 app bundle의 기존 release-channel marker를 읽는다.

```swift
enum AppBuildFlavor: Equatable {
    case official
    case development
}
```

판별 규칙은 다음과 같다.

- `Bundle.main`의 `CLIProxyManagerReleaseChannel` 값이 정확히 `development`이면 `.development`
- key가 없거나 다른 값이면 `.official`

기존 `make development-bundle`은 이미 development bundle의 `Info.plist`에 이 marker를 삽입한다. 별도 환경 변수나 compile flag를 단일 기준으로 추가하지 않는다.

판별 로직은 dictionary 또는 bundle metadata 입력을 주입할 수 있게 작성하여 실제 bundle 없이 단위 테스트할 수 있게 한다.

## 구성요소

### `MenuBarIconState`

기존 server control 및 diagnostic 상태를 Connected, Connecting, Stopped로 축약한다. 상태 의미만 담당하며 SwiftUI 또는 AppKit 렌더링에 의존하지 않는다.

### `AppBuildFlavor`

Official과 Development를 판별한다. runtime metadata 해석만 담당하며 아이콘 색상이나 geometry를 알지 않는다.

### `MenuBarAppIcon`

다음 표현을 담당하는 SwiftUI view다.

- 기존 `AppMarkMenuBarPath`
- Connecting의 trim progress
- Stopped의 사선
- Development의 rounded-square 외곽선
- adaptive monochrome foreground
- accessibility label
- Reduce Motion fallback

`CLIProxyManagerApp`의 `MenuBarExtra` label은 기존 정적 `NSImage` 대신 이 view를 사용한다. View model의 published 상태가 바뀌면 label이 같은 data flow에서 다시 평가된다.

### `AppIconView` 및 `AppMarkRenderer`

Dock icon 렌더링 API가 `AppBuildFlavor`를 받는다.

- Official과 Development 모두 현재 blue–purple gradient, 기존 padding과 corner radius를 유지한다. 새로운 gradient나 badge는 추가하지 않는다.
- Official의 파형은 불투명 흰색을 유지한다.
- Development는 파형만 반투명 검정(`Color.black.opacity(0.34)`)으로 바꿔 official과 실루엣이 구분되게 한다.
- Development는 active artwork 전체에 얇은 주황색(`Color.orange.opacity(0.82)`) rounded-square 테두리를 추가로 그린다.
- 두 variant 모두 현재 1024×1024 canvas와 824×824 active artwork 규칙을 유지한다.

### `AppAppearanceService`

현재 `showDockIcon` 처리와 activation policy를 유지한다. Dock을 노출하기 전에 build flavor에 맞는 `applicationIconImage`를 적용하여 official icon이 잠깐 보이는 시간을 최소화한다.

Protocol 소비자는 build flavor를 알 필요가 없다. 실제 service가 생성 시 받은 build flavor를 내부에서 사용하며 기본값은 current bundle에서 판별한다.

## Data flow

1. Development bundle은 기존 Makefile 흐름에서 `CLIProxyManagerReleaseChannel=development`를 기록한다.
2. 앱 시작 시 `AppBuildFlavor`가 bundle metadata를 읽는다.
3. `LaunchAppearanceBootstrapper`가 저장된 Dock 표시 설정을 적용할 때 `AppAppearanceService`가 build flavor에 맞는 Dock icon을 먼저 설정한다.
4. `DashboardViewModel`이 기존 방식으로 server status를 갱신한다.
5. `MenuBarIconState`가 `serverControlState`와 `serverStatus.severity`를 3단계 상태로 변환한다.
6. `MenuBarAppIcon`이 상태와 build flavor를 조합해 메뉴바 label을 표시한다.
7. 서버 상태가 바뀌면 기존 published update에 따라 메뉴바 icon도 즉시 갱신된다.

## Connecting motion

Connecting은 `AppMarkMenuBarPath.trim(from: 0, to: progress)`를 사용한다.

한 주기는 약 1.4초다.

1. 0.9초 동안 progress를 0에서 1까지 선형 증가
2. 0.2초 동안 완성된 파형 유지
3. 0.15초 동안 opacity를 0으로 감소
4. 0.15초 후 다음 주기 시작

메뉴바의 작은 artwork에 과도한 갱신을 발생시키지 않도록 약 15fps 수준으로 제한한다. `.connecting`이 아닐 때는 animation clock을 실행하지 않는다.

상태 변경 시 동작은 다음과 같다.

- Connecting 진입: 새 주기를 progress 0에서 시작
- Connected 진입: 즉시 완성된 현재 파형 표시
- Stopped 진입: 즉시 완성된 파형과 사선 표시
- View 제거 또는 앱 종료: animation task 취소

## Geometry 및 가독성

- 기준 크기는 현재와 같은 18×18pt다.
- 기존 파형의 비율과 round line cap/join을 유지한다.
- Stopped 사선은 파형을 가로지르는 `/` 방향이며 파형과 동일 계열의 선 두께를 사용한다.
- Development의 채운 rounded-square 배경은 4pt continuous corner radius를 사용하고, 파형은 `destinationOut` blend로 배경에서 투명하게 cutout된다.
- Development variant의 파형은 외곽선과 충돌하지 않을 정도로만 소폭 축소한다.
- Official Connected는 현재 menu bar icon과 시각적으로 동일해야 한다.
- Light/Dark mode에서 색상에 의존하지 않고 shape 차이만으로 상태와 build를 구분한다.

## 접근성

### Reduce Motion

`accessibilityReduceMotion`이 활성화되면 반복 motion을 실행하지 않는다. Connecting은 파형 경로의 약 65%만 그려진 정적 variant로 표시한다. 따라서 motion 없이도 Connected 및 Stopped와 구분된다.

### Accessibility label

Menu bar label에는 상태와 build를 함께 설명하는 label을 제공한다.

- `CLIProxyManager connected`
- `CLIProxyManager connecting`
- `CLIProxyManager stopped`
- Development일 때 `development build`를 덧붙임

아이콘의 shape 차이는 시각적 보조이며 상세 메뉴의 기존 상태 텍스트를 제거하지 않는다.

## 오류 및 fallback

- App build marker가 없거나 예상 값이 아니면 안전하게 Official로 처리한다.
- `MenuBarAppIcon`은 고정 geometry를 직접 그리는 non-optional SwiftUI view로 구성하여 runtime image 생성 실패 분기를 만들지 않는다.
- Dock renderer가 이미지를 만들지 못하면 기존 bundle icon을 그대로 사용한다.
- Dock icon 렌더링 실패가 activation policy, 앱 실행, proxy runtime 동작을 막지 않는다.
- Error 상태는 Stopped icon으로 표현하지만 메뉴의 `Error` label과 diagnostic message는 유지한다.

## 테스트

### 상태 매핑

- `.running + .ready`만 `.connected`가 됨
- `.starting`은 severity와 무관하게 `.connecting`이 됨
- `.running + non-ready`는 `.stopped`가 됨
- `.stopping`, `.stopped`, `.error`는 `.stopped`가 됨

### Build flavor

- marker가 없으면 `.official`
- marker가 `development`이면 `.development`
- 예상하지 않은 값이면 `.official`

### Menu bar 렌더링

- `ImageRenderer`로 렌더링한 Official Connected가 기존 18×18 geometry를 유지함
- Connecting의 서로 다른 progress 값이 서로 다른 render data를 생성함
- Stopped가 Connected와 다른 render data를 생성함
- Development가 각 Official 상태와 다른 render data를 생성함
- 모든 menu bar variant가 18×18 layout bounds를 유지함
- Reduce Motion Connecting presentation은 65% 정적 progress를 사용함

### Dock 렌더링

- Official과 Development가 모두 1024×1024 canvas image를 생성함
- Official과 Development render data가 서로 다름
- Official style이 기존 gradient와 active artwork geometry를 유지함
- 기본 `AppIconView()`는 Official style로 렌더링됨

### 회귀 검증

- 기존 `AppMarkRendererTests`
- 기존 `AppAppearanceServiceTests`
- 전체 `swift test`
- `make development-bundle BUILD_DIR=build-development`
- app bundle 구조 및 development release-channel marker 검증

## 수동 확인

자동 검증 후 사용자가 development app을 실행해 다음을 확인한다.

- Connected에서 기존 파형이 그대로 보임
- 서버 시작 중 파형이 순차적으로 그려짐
- Stopped 및 Error에서 사선이 보임
- Reduce Motion에서 Connecting이 정적 partial path로 보임
- Development 메뉴바 icon이 채운 rounded-square 배경과 투명 파형 cutout으로 보임
- Development Dock 및 App Switcher icon이 기존 gradient에 반투명 검정 파형과 얇은 주황색 테두리로 보임
- Light/Dark appearance 양쪽에서 icon이 선명함
- 상태 변경 후 menu bar icon이 지연 없이 갱신됨

## 성공 기준

- 메뉴바 icon만으로 Connected, Connecting, Stopped를 구분할 수 있다.
- Official Connected icon은 현재 icon과 동일한 인상을 유지한다.
- Development 앱은 menu bar와 Dock/App Switcher 모두에서 Official과 즉시 구분된다.
- motion은 서버 시작 중에만 실행되고 Reduce Motion을 존중한다.
- 기존 앱 설정, proxy lifecycle, packaging channel 동작에 회귀가 없다.
