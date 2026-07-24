# Usage HUD 계정 표시 관리 설계

**작성일:** 2026-07-25  
**상태:** 승인됨 — 구현 계획 작성 전 사용자 검토 대기

## 배경

Usage HUD는 현재 `DashboardViewModel.providerRows`에서 connected·enabled 계정을 가져와 Expanded와 Compact 모드에 모두 표시한다. 계정 순서는 메인 화면의 `accountOrder`를 따르지만, 특정 계정을 HUD에서 제외하는 설정은 없다.

계정이 많아지면 사용자가 자주 확인하는 계정만 HUD에 남기고 싶어도 API key 계정을 포함한 모든 connected 계정이 노출된다. 메인 계정 목록에서 간단히 HUD 표시 여부를 관리하고, 이 선택을 앱 재실행 후에도 복원할 수 있어야 한다.

## 목표

1. 메인 화면의 각 계정 카드에서 Usage HUD 표시 여부를 즉시 변경할 수 있다.
2. Claude/Codex OAuth와 Claude/OpenAI API key 계정을 동일한 방식으로 관리한다.
3. 기존 계정과 새 계정은 기본적으로 HUD에 표시한다.
4. Disabled 또는 disconnected 계정에서도 미리 표시 여부를 설정할 수 있다.
5. Expanded와 Compact HUD가 동일한 선택 목록과 기존 계정 순서를 사용한다.
6. 메뉴바 계정 목록과 구독 사용량 조회 수명주기는 변경하지 않는다.
7. 모든 계정을 숨겨도 HUD 창과 chrome은 유지하고 명확한 빈 상태를 표시한다.

## 범위 밖

- HUD 내부에서 계정 표시 여부 변경
- Usage 설정 탭에 별도 계정 관리 목록 추가
- HUD 전용 계정 순서
- Expanded와 Compact의 계정 선택 분리
- 메뉴바 계정 목록 필터링
- 숨긴 계정의 구독 사용량 조회 또는 cache 갱신 중단
- HUD 전체 표시 설정인 `usageOverlay.isVisible` 변경

## 검토한 저장 접근법

### 숨긴 계정 ID 목록

`AppConfig.UsageOverlay`에 HUD에서 숨긴 계정 ID만 저장한다. 빈 배열이 기존 동작인 “모두 표시”를 나타내므로 migration이 단순하고 새 계정도 자동으로 표시된다. OAuth와 API key를 `ProviderRowState.ID` 하나로 관리할 수 있다. 이 설계의 채택안이다.

### 표시할 계정 ID 목록

명시적인 allowlist라 이해하기 쉽지만, 기존 설정 파일과 새 계정을 기본 표시하기 위해 “아직 사용자 선택이 없음”과 “사용자가 모두 숨김”을 구분하는 추가 상태가 필요하다.

### 계정별 표시 속성

각 OAuth command profile이나 API key 설정에 표시 여부를 저장할 수 있지만 OAuth와 API key의 저장 위치가 분산된다. HUD라는 단일 presentation의 설정이 계정 인증·라우팅 설정에 섞이는 단점도 있다.

## 사용자 경험

### 계정 카드 버튼

메인 화면의 모든 계정 카드에 Usage HUD 표시 버튼을 항상 노출한다. 버튼은 기존 action 영역에서 Settings 버튼 앞에 배치하고 Usage 탭과 같은 `chart.bar.xaxis` SF Symbol을 사용한다.

계정 상태별 action 순서는 다음과 같다.

- Connected: `[HUD] [Settings] […]`
- Disabled: `[HUD] [Settings] […]`
- Disconnected: `[HUD] [Connect] […]`

버튼은 모든 상태에서 26×26 click target과 같은 위치를 유지한다.

- HUD 표시 상태: accent foreground와 약한 accent 배경
- HUD 숨김 상태: secondary 또는 tertiary foreground와 배경 없음
- 표시 중 tooltip/accessibility label: `Hide from Usage HUD`
- 숨김 중 tooltip/accessibility label: `Show in Usage HUD`

계정 상세 개인정보를 표시·숨기는 기존 `eye` 버튼은 detail row에 그대로 둔다. HUD 버튼은 다른 symbol과 action 영역을 사용하여 두 기능의 역할을 구분한다.

### 적용 범위

- Connected, Disabled, Disconnected 계정에서 모두 버튼을 조작할 수 있다.
- Claude/Codex OAuth와 Claude/OpenAI API key 계정을 모두 관리한다.
- 계정 선택은 Expanded와 Compact HUD에 공통 적용한다.
- 메뉴바 계정 목록에는 적용하지 않는다.
- 표시되는 계정은 기존 `accountOrder`의 상대 순서를 유지한다.

## 저장 모델

`AppConfig.UsageOverlay`에 다음 필드를 추가한다.

```swift
public var hiddenAccountIDs: [String]
```

전체 구조의 의미는 다음과 같다.

```swift
UsageOverlay(
    isVisible: Bool,
    alwaysOnTop: Bool,
    backgroundOpacity: Double,
    displayMode: DisplayMode,
    hiddenAccountIDs: [String]
)
```

각 값은 `ProviderRowState.ID.rawValue`다.

- OAuth 계정: 대응하는 OAuth command profile ID
- Claude API key: `ProviderRowState.ID.claudeAPI.rawValue`
- OpenAI API key: `ProviderRowState.ID.codexAPI.rawValue`

### 기본값과 migration

- 기본값은 빈 배열이다.
- 기존 JSON에 `hiddenAccountIDs`가 없으면 빈 배열로 decode한다.
- 따라서 모든 기존 계정이 계속 표시된다.
- 새 계정 ID도 hidden 목록에 없으므로 자동으로 표시된다.
- encode할 때는 새 필드를 기록한다.

### 정규화

- decode할 때 중복 ID는 첫 번째 항목만 유지한다.
- 계정을 숨길 때 기존 배열 끝에 ID를 추가하고, 표시할 때 해당 ID를 제거한다.
- 계정 순서 변경은 hidden 목록을 다시 쓰지 않는다. 표시 순서는 계속 `accountOrder`에서만 결정한다.
- 현재 계정 목록에서 확인할 수 없는 stale ID가 있어도 decode나 HUD 표시를 실패시키지 않는다.
- 계정을 명시적으로 삭제할 때 해당 ID를 hidden 목록에서도 제거한다.

## 계정 presentation 상태

`ProviderRowState`에 다음 값을 추가한다.

```swift
let showsInUsageOverlay: Bool
```

기존 initializer와 테스트 호환을 위해 기본값은 `true`로 둔다. `DashboardViewModel`이 provider 행을 구성할 때는 config에서 명시적으로 계산한다.

```swift
showsInUsageOverlay =
    !config.usageOverlay.hiddenAccountIDs.contains(provider.id.rawValue)
```

`DashboardAccountSnapshot`도 이 값을 전달받아 계정 카드 버튼의 상태를 표현한다. 메뉴바 snapshot은 이 값을 사용하지 않는다.

## 표시 변경 API와 저장 흐름

`DashboardViewModel`은 다음 API를 제공한다.

```swift
func setAccountVisibleInUsageOverlay(
    _ id: ProviderRowState.ID,
    isVisible: Bool
) throws
```

처리 절차는 다음과 같다.

1. 현재 `providerRows`에 ID가 없으면 no-op한다.
2. 이미 원하는 상태면 no-op하고 저장하지 않는다.
3. 표시할 때 ID를 `hiddenAccountIDs`에서 제거한다.
4. 숨길 때 ID를 `hiddenAccountIDs`에 추가한다.
5. 메모리의 config와 provider 행을 갱신해 카드와 HUD에 즉시 반영한다.
6. 기존 원자적 config 저장 경로로 저장한다.
7. 저장 실패 시 config, provider 행, 카드 버튼, HUD 목록을 이전 상태로 rollback한다.

UI에서는 기존 `saveSetting` 경로를 사용하여 오류를 settings toast에 표시한다. ViewModel은 config 저장 오류를 기능 전용 `LocalizedError`로 감싸 다음 문구를 제공한다.

```text
Usage HUD account visibility could not be saved: <localized error>
```

표시 선택은 구독 사용량 기능의 전역 활성 상태를 바꾸지 않는다. 따라서 다음 작업을 수행하지 않는다.

- 서버 재시작
- management key 생성 또는 삭제
- polling과 진행 중인 refresh 취소
- usage state 또는 snapshot cache 삭제
- 메뉴바 presentation 변경

숨긴 계정의 사용량은 기존 백그라운드 흐름에서 계속 갱신한다. 사용자가 다시 표시하면 마지막 성공 snapshot을 즉시 사용할 수 있다.

## 계정 수명주기

### Disabled와 disconnected

표시 의도를 그대로 저장한다. 계정이 다시 enabled 또는 connected 상태가 되면 저장된 선택에 따라 HUD에 나타난다.

### OAuth 계정 삭제

기존 `resetProviderSettings(_:)`가 OAuth command profile과 legacy 설정을 제거할 때 같은 `updatedConfig`에서 provider ID를 `hiddenAccountIDs`에서도 제거한다.

### API key 계정 삭제

`removeAPIProvider(_:)`의 기존 config transaction에서 command name을 정리할 때 고정 API provider ID도 `hiddenAccountIDs`에서 제거한다.

삭제 후 다시 등록한 OAuth 또는 API key 계정은 새 계정 기본값에 따라 HUD에 표시된다.

## HUD 데이터 흐름

`UsageOverlayView`에서만 HUD 표시 선택을 적용한다.

```swift
let selectedRows = viewModel.providerRows.filter(\.showsInUsageOverlay)
```

그 후 기존 `MenuBarStatusSnapshot`에 `selectedRows`를 전달한다. 이 snapshot의 기존 connected·enabled 필터와 입력 순서 보존 동작을 재사용한다.

`MenuBarStatusView`는 계속 전체 `providerRows`를 전달하므로 계정별 HUD 표시 설정의 영향을 받지 않는다.

## 빈 상태

HUD는 전체 `providerRows`, HUD 대상으로 선택된 행, 최종 connected provider를 함께 확인하여 다음 상태를 구분한다. 등록 계정 자체가 없는 경우에는 기존 `No connected accounts` 의미를 유지한다.

### 선택된 계정 없음

현재 등록 계정이 하나 이상 있지만 모두 `showsInUsageOverlay == false`인 상태다.

```text
No accounts selected
```

### 선택된 connected 계정 없음

HUD 표시 대상으로 선택된 계정은 있지만 모두 disabled 또는 disconnected인 상태다.

```text
No connected accounts
```

Expanded와 Compact HUD가 같은 의미를 사용한다. Compact에서는 108pt 폭에 맞게 문구의 여러 줄 표시를 허용한다.

모든 계정을 숨겨도 HUD window는 자동으로 닫지 않는다. 새로고침, 모드 전환, 닫기 버튼을 포함한 chrome은 계속 표시한다.

## 크기와 모드 전환

- Expanded와 Compact는 동일한 filtered provider 목록을 사용한다.
- 계정 숨김·표시로 provider ID 집합이 바뀌면 `CompactUsageMeasurementState`가 기존 측정값을 초기화한다.
- 새 콘텐츠 높이를 측정한 후 viewport와 window fitting size를 다시 계산한다.
- 숨긴 뒤 불필요한 세로 빈 공간을 남기지 않는다.
- 계정을 다시 표시하면 `accountOrder`에 해당하는 기존 위치로 돌아온다.
- `usageOverlay.isVisible`, `alwaysOnTop`, `backgroundOpacity`, `displayMode`는 계정 선택과 독립적으로 유지한다.

## 오류 처리

- 알 수 없는 provider ID 요청: no-op
- 동일 상태 재요청: no-op, config 저장 없음
- config 저장 실패: config와 provider presentation rollback 후 toast 표시
- 중복 hidden ID: 정규화하여 하나만 유지
- stale hidden ID: 다른 계정의 표시를 막지 않고 앱 시작을 실패시키지 않음
- 계정 삭제 중 설정 저장 실패: 기존 계정 삭제 오류 경로를 사용하며 성공하지 않은 config 정리를 완료한 것으로 표시하지 않음

## 테스트 전략

### `AppConfig`

- 기존 `UsageOverlay` JSON에 `hiddenAccountIDs`가 없어도 빈 배열로 decode한다.
- 새 필드를 encode하고 다시 decode하면 값이 보존된다.
- 빈 배열은 모든 계정 기본 표시를 의미한다.
- 중복 ID가 정규화된다.
- 기존 HUD 설정 필드와 함께 round-trip해도 값이 보존된다.

### Provider와 dashboard presentation

- `ProviderRowState`의 기본 HUD 표시값은 `true`다.
- hidden ID에 포함된 provider 행은 `showsInUsageOverlay == false`다.
- 새 계정은 `showsInUsageOverlay == true`다.
- `DashboardAccountSnapshot`이 HUD 표시 상태를 보존한다.
- 카드 버튼의 symbol, tone, tooltip, accessibility label이 상태에 맞게 결정된다.
- Connected, Disabled, Disconnected 카드에 버튼이 제공된다.

### ViewModel 저장과 rollback

- 계정을 숨기면 ID가 hidden 목록에 추가된다.
- 다시 표시하면 ID가 제거된다.
- 동일 상태와 존재하지 않는 ID 요청은 저장하지 않는다.
- config 저장 실패 시 config와 provider 행이 rollback된다.
- OAuth 계정 삭제 시 hidden ID가 제거된다.
- API key 계정 삭제 시 hidden ID가 제거된다.
- 표시 변경이 서버 재시작, polling 취소, management key 변경을 유발하지 않는다.
- 숨긴 계정의 usage state와 cache가 유지된다.

### HUD filtering과 empty state

- 숨겨진 계정만 HUD provider 목록에서 제외된다.
- 필터링 후에도 `accountOrder` 상대 순서가 유지된다.
- 메뉴바 snapshot에는 hidden 설정이 적용되지 않는다.
- 모두 숨긴 경우 `No accounts selected`를 사용한다.
- 선택된 계정은 있지만 connected 계정이 없으면 `No connected accounts`를 사용한다.
- Expanded와 Compact가 같은 필터 결과와 empty-state 의미를 사용한다.
- filtered provider ID 변경 시 compact 측정 상태가 새 높이를 요청한다.

### 최종 검증

1. 관련 focused test
2. 전체 `swift test`
3. development app build
4. 실제 앱 실행과 수동 UI 확인은 사용자가 수행

수동 확인 항목은 다음과 같다.

- 모든 카드 상태에서 HUD 버튼 위치와 click target
- 기존 privacy `eye` 버튼과 HUD 버튼의 역할 구분
- 계정 숨김·재표시 시 HUD의 즉시 목록·크기 변경
- Expanded와 Compact 전환
- 앱 재실행 후 선택 복원
- 모든 계정을 숨긴 빈 상태

## 완료 조건

- 메인 화면의 모든 계정 카드에서 HUD 표시 여부를 변경할 수 있다.
- 선택은 앱 재실행 후에도 유지된다.
- 기존 계정과 새 계정은 기본 표시된다.
- OAuth와 API key 계정을 동일하게 관리한다.
- Disabled와 disconnected 계정의 선택도 유지된다.
- Expanded와 Compact가 같은 선택 목록과 기존 순서를 사용한다.
- 메뉴바와 구독 사용량 조회 수명주기는 변경되지 않는다.
- 모든 계정을 숨기면 HUD가 `No accounts selected` 빈 상태를 표시한다.
- 저장 실패 시 UI와 config가 이전 상태로 복구된다.
- 자동 테스트와 development build가 통과한다.
