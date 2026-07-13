# 전용 Usage 설정 탭 및 독립 표시 설정 설계

**작성일:** 2026-07-13  
**상태:** 승인됨 — 구현 계획 작성 전 사용자 검토 대기  
**관련 이슈:** [#63 Consolidate menu bar and HUD usage settings into a dedicated Usage tab](https://github.com/woosublee/CLIProxyManager/issues/63)

## 배경

구독 사용량 표시 설정은 현재 서로 다른 탭에 분산되어 있다.

- `General`의 `Usage Overlay`: HUD 표시, 항상 위, 배경 투명도
- `Server`의 `Subscription Usage (Experimental)`: 구독 사용량 조회와 메뉴바 표시를 함께 제어하는 단일 toggle

두 기능은 같은 구독 사용량 데이터를 사용하지만 설정 위치와 표현 방식이 달라 관계를 이해하기 어렵다. 또한 기존 `Show subscription usage`는 이름상 메뉴바 표시 설정처럼 보이지만 실제로는 management key 생성·삭제와 전체 조회 기능의 수명주기를 제어한다. HUD와 메뉴바 표시를 각각 선택하려는 사용자 의도도 표현할 수 없다.

## 목표

1. 설정 창에 `Usage` 전용 탭을 추가한다.
2. 메뉴바와 Usage HUD 표시를 각각 독립적으로 켜고 끌 수 있게 한다.
3. 두 표시 위치 중 하나라도 사용 중이면 공통 사용량 조회 기능과 management key를 자동 유지한다.
4. 두 표시 위치가 모두 꺼졌을 때만 조회 기능을 중단하고 management key를 삭제한다.
5. 기존 저장값, HUD 실시간 투명도 미리보기, HUD의 세션 한정 숨김 동작을 보존한다.
6. 설정 창의 기존 720×500 크기에서 다섯 개 탭과 모든 control이 잘리지 않게 한다.

## 범위 밖

- Usage HUD 콘텐츠와 시각 디자인 개편
- 계정별 표시 위치 선택
- 사용량 refresh 주기 변경
- 메뉴바와 HUD의 계정 순서 변경
- 새로운 usage provider 지원
- HUD `×` 버튼을 영구 설정 변경 동작으로 전환

## 결정 사항

### 표시 설정은 독립적이다

사용자는 다음 두 값을 각각 설정한다.

- 메뉴바에서 구독 사용량 표시
- Usage HUD 표시

메뉴바 표시를 꺼도 HUD가 켜져 있으면 조회 기능은 유지된다. HUD를 꺼도 메뉴바 표시가 켜져 있으면 조회 기능은 유지된다.

### 조회 기능은 표시 설정에서 계산한다

사용자가 직접 조작할 수 없는 별도 master switch는 저장하지 않는다. 내부 조회 활성 여부는 다음 규칙으로 계산한다.

```swift
isSubscriptionUsageEnabled =
    subscriptionUsage.showInMenuBar || usageOverlay.isVisible
```

따라서 UI 설정과 내부 조회 상태가 서로 어긋나는 저장 상태를 만들 수 없다.

### HUD 닫기는 현재 실행에만 적용한다

HUD의 `×` 버튼과 메뉴바의 `Hide usage HUD`는 현재처럼 창만 `orderOut`하고 저장된 `usageOverlay.isVisible` 값은 변경하지 않는다. 설정 탭에서 HUD toggle을 껐다 켜거나 앱을 재실행하면 저장 설정에 따라 창이 다시 표시된다.

## 설정 모델

### `AppConfig.SubscriptionUsage`

기존 저장 모델:

```swift
SubscriptionUsage(isEnabled: Bool)
```

새 저장 모델:

```swift
SubscriptionUsage(showInMenuBar: Bool)
```

`isEnabled`는 `SubscriptionUsage`의 저장 필드로 유지하지 않는다. 대신 `AppConfig`에 다음 계산 속성을 제공하고, 앱·core·CLI의 모든 조회 활성 판단은 이 속성을 사용한다.

```swift
var isSubscriptionUsageEnabled: Bool {
    subscriptionUsage.showInMenuBar || usageOverlay.isVisible
}
```

### `AppConfig.UsageOverlay`

기존 구조와 의미를 유지한다.

```swift
UsageOverlay(
    isVisible: Bool,
    alwaysOnTop: Bool,
    backgroundOpacity: Double
)
```

`alwaysOnTop`과 `backgroundOpacity`는 조회 활성 여부에 영향을 주지 않는다.

## 기존 설정 migration

`SubscriptionUsage` decoder는 새 필드와 기존 필드를 모두 이해한다.

1. `showInMenuBar`가 있으면 해당 값을 사용한다.
2. `showInMenuBar`가 없고 기존 `isEnabled`가 있으면 그 값을 `showInMenuBar`로 이전한다.
3. 두 필드가 모두 없으면 `false`를 사용한다.
4. encode할 때는 새 `showInMenuBar`만 기록한다.
5. 기존 `usageOverlay.isVisible` 값은 변경하지 않는다.

이 규칙에 따라 기존 `isEnabled == false`, `usageOverlay.isVisible == true` 조합은 새 버전에서 다음 상태가 된다.

- 메뉴바 표시: 꺼짐
- HUD 표시: 켜짐
- 계산된 조회 기능: 켜짐

즉 기존 HUD 표시 의도를 보존하고 필요한 조회 기능과 management key를 자동 복구한다.

## 설정 변경과 management key 수명주기

표시 toggle을 변경할 때 변경 전후의 계산된 조회 활성 상태를 비교한다.

### `false → true`

메뉴바 또는 HUD 중 첫 표시 위치가 켜진 경우다.

1. management key가 없으면 생성한다.
2. 변경된 표시 설정을 config에 저장한다.
3. config 저장이 실패하고 이번 동작에서 key를 새로 만들었다면 key를 제거한다.
4. 서버가 실행 중이면 새 관리 설정 적용을 위해 재시작한다.
5. 서버가 정지 상태면 사용량 조회 상태를 갱신한다.

### `true → true`

한 표시 위치가 이미 켜진 상태에서 다른 표시 위치를 켜거나, 두 위치 중 하나만 끄는 경우다.

1. 변경된 표시 설정만 저장한다.
2. management key, 조회 task, cache, snapshot을 유지한다.
3. 사용량 관리 설정 자체가 바뀌지 않으므로 서버를 불필요하게 재시작하지 않는다.

### `true → false`

마지막 표시 위치가 꺼진 경우다.

1. 비활성 표시 설정을 config에 저장한다.
2. 진행 중인 사용량 조회와 예약 polling을 취소한다.
3. management key를 삭제한다.
4. usage state와 snapshot cache를 정리한다.
5. 서버가 실행 중이면 management 설정 제거를 적용하기 위해 재시작한다.

기존 비활성화 원자성 정책을 유지한다. config 저장이 실패하면 활성 config와 key를 보존한다. config 저장 후 key 삭제만 실패하면 표시 설정은 꺼진 상태를 유지하고 오류를 사용자에게 알린다.

## ViewModel API

표시 위치별 의도가 드러나는 API를 제공한다.

```swift
func saveSubscriptionUsageMenuBarVisible(_ isVisible: Bool) throws
func saveUsageOverlay(_ preferences: AppConfig.UsageOverlay) throws
```

두 API는 공통 helper를 통해 변경 전후의 계산된 활성 상태를 비교하고 management key 및 조회 수명주기를 조정한다. 기존 `saveSubscriptionUsageEnabled(_:)`에 결합된 활성화·비활성화 로직은 이 공통 경계로 이동한다.

`saveUsageOverlay(_:)`는 다음을 구분한다.

- `isVisible` 변경: 조회 활성 상태가 바뀔 수 있으므로 공통 수명주기 적용
- `alwaysOnTop` 또는 `backgroundOpacity`만 변경: config 저장과 window update만 수행

opacity slider는 현재처럼 drag 중 `previewUsageOverlayBackgroundOpacity(_:)`로 config의 in-memory 값을 갱신하고, drag가 끝날 때 `saveUsageOverlay(_:)`로 저장한다.

## Usage 탭 UI

### 탭 순서

1. `General`
2. `Usage`
3. `Server`
4. `Advanced`
5. `About`

`Usage` 탭의 SF Symbol은 `chart.bar.xaxis`를 사용한다. 상단 탭은 현재의 12pt horizontal padding을 유지한다. 구현 전에 `apple-design` 스킬의 macOS 설정 UI 원칙을 검토하되, 검토 결과는 이 정보 구조를 바꾸지 않고 label 위계와 간격의 세부 polish에만 적용한다. 다섯 탭이 기존 720pt 폭에서 안정적으로 맞아야 하며 창 크기는 변경하지 않는다.

### Menu Bar 그룹

- **Show subscription usage** toggle
- 설명: 연결된 Claude 및 Codex 계정 아래에 구독 사용량을 표시한다.
- HUD가 켜져 있다면 이 toggle을 꺼도 조회 기능은 계속 유지된다는 내부 동작을 UI에 과도하게 노출하지 않는다.

### Usage HUD 그룹

- **Show usage HUD** toggle
- **Always on top** toggle
- **Background opacity** slider

`Always on top`과 `Background opacity`는 `Show usage HUD`가 켜진 경우에만 활성화한다. 비활성 상태에서도 저장값은 유지한다.

### 안내 문구

탭 하단에 다음 의미의 짧은 보조 문구를 제공한다.

> Usage data is fetched whenever the menu bar display or Usage HUD is enabled. CLIProxyManager manages the local management key automatically.

실제 copy는 기존 앱의 간결한 영어 문체와 `apple-design` 검토 결과에 맞춰 다듬을 수 있으나, 의미를 추가하거나 삭제하지 않는다.

### 기존 화면 정리

- `GeneralSettingsView`에서 `Usage Overlay` 그룹과 관련 binding을 제거한다.
- `ServerSettingsView`에서 `Subscription Usage (Experimental)` 그룹을 제거한다.
- 새 `UsageSettingsView`가 메뉴바와 HUD 설정 binding을 소유한다.
- `Experimental` 표현은 제거한다.

## 표시 동작

### 메뉴바

메뉴바 사용량 presentation은 `subscriptionUsage.showInMenuBar`가 켜진 경우에만 렌더링한다. 이 설정이 꺼져도 다음 정보는 유지한다.

- 계정명과 nickname
- command name
- 연결 상세 정보
- provider status

HUD가 켜져 있으면 usage state와 cache는 계속 갱신하되 `MenuBarAccountRow`의 usage 영역만 숨긴다.

### Usage HUD

HUD는 `usageOverlay.isVisible`을 영구 표시 preference로 사용한다. 메뉴바 표시 설정과 무관하게 사용량을 렌더링한다.

`UsageOverlayWindowController`의 기존 세션 동작을 유지한다.

- 설정에 의한 off: 창을 숨기고 저장값도 off
- 설정에 의한 on: 창을 표시하고 저장값도 on
- `×` 또는 메뉴바 hide action: 이번 실행에서만 숨기고 저장값 유지
- 앱 재실행: 저장값이 on이면 다시 표시

## 오류 처리

- 최초 표시 위치 활성화 중 key 생성 실패: config를 변경하지 않고 오류 toast 표시
- key 생성 후 config 저장 실패: 새로 만든 key를 rollback하고 기존 표시 상태 유지
- 마지막 표시 위치 비활성화 중 config 저장 실패: 기존 활성 설정과 key 유지
- config 저장 후 key 삭제 실패: 새 비활성 설정은 유지하고 오류 표시
- 메뉴바와 HUD 중 하나만 끌 때: key 삭제, cache 정리, polling 취소, 서버 재시작을 하지 않음
- window preference 저장 실패: 기존 `saveSetting` 오류 전달 경로를 사용
- 서버 재시작 실패: 기존 서버 action 오류 표시 경로를 사용하며 저장된 표시 preference를 임의로 되돌리지 않음

## Apple 디자인 검토 조건

설정 UI 구현을 시작하기 전에 `apple-design` 스킬을 읽고 다음 항목을 현재 앱 스타일에 맞춰 적용한다.

- 탭 수가 늘어날 때 label과 icon의 정보 위계
- macOS 설정 화면에 적절한 group 간격과 row density
- toggle 및 slider의 alignment와 충분한 click target
- disabled control이 저장값을 유지한다는 점이 시각적으로 자연스럽게 드러나는 방식
- 설명 문구를 짧고 직접적으로 유지하는 방식
- 기존 material, corner radius, typography와 충돌하지 않는 절제된 적용

이 작업은 설정 창의 전체 재디자인이 아니다. 기존 `SettingsGroup`, `SettingsRow`, `SettingsToggleStyle`을 우선 재사용하고, Usage 탭을 명확하게 만드는 데 필요한 최소 변경만 수행한다.

## 테스트 전략

### Config 및 migration

- 기존 `subscriptionUsage.isEnabled == true`를 `showInMenuBar == true`로 decode
- 기존 `isEnabled == false`를 `showInMenuBar == false`로 decode
- 새 `showInMenuBar` encode/decode round-trip
- 새 필드와 legacy 필드가 함께 있으면 새 필드 우선
- 메뉴바/HUD의 네 가지 조합에서 계산된 `isSubscriptionUsageEnabled` 확인
- `cpm quota`와 proxy config 생성도 같은 계산 속성을 사용함을 검증

### ViewModel 및 수명주기

- 메뉴바만 켜면 key 생성 및 조회 활성화
- HUD만 켜면 key 생성 및 조회 활성화
- 메뉴바가 켜진 상태에서 HUD를 끄면 key와 state 유지
- HUD가 켜진 상태에서 메뉴바를 끄면 key와 state 유지
- 마지막 표시 위치를 끌 때만 key 삭제, polling 취소, state/cache 정리
- 최초 활성화 config 저장 실패 시 새 key rollback
- 마지막 비활성화 config 저장 실패 시 기존 key와 활성 config 유지
- key 삭제 실패 시 비활성 config 유지
- reset 시 두 표시 설정과 management key 정리

### Settings 및 presentation

- `SettingsTab` 순서와 title/icon 검증
- 새 Usage 탭에서 각 control이 대응하는 config 값을 변경
- 메뉴바 표시 off일 때 account usage presentation 숨김
- 메뉴바 표시 off 및 HUD on 상태에서 HUD usage presentation 유지
- HUD opacity preview가 저장 전 실시간 반영되고 commit 시 저장
- HUD 세션 숨김이 config를 변경하지 않음

### 최종 검증

1. 관련 focused tests
2. 전체 `swift test`
3. development app build
4. 앱 실행과 수동 UI 확인은 사용자가 담당

## 완료 조건

- 설정 창에 독립된 `Usage` 탭이 존재한다.
- General과 Server에서 기존 usage 그룹이 제거된다.
- 메뉴바와 HUD 표시를 각각 설정할 수 있다.
- 둘 중 하나라도 켜져 있으면 조회 기능과 management key가 유지된다.
- 둘 다 꺼졌을 때만 조회 기능이 비활성화된다.
- 기존 설정이 명시된 migration 규칙에 따라 유지된다.
- HUD의 세션 한정 숨김과 opacity 실시간 미리보기가 유지된다.
- 기존 720×500 설정 창에서 탭과 콘텐츠가 잘리지 않는다.
- 자동 테스트와 development build가 통과한다.
