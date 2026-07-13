# 계정 순서 변경 기능 설계

## 배경

현재 등록 계정은 OAuth 인증 파일과 설정 배열에서 만들어진 순서대로 앱 메인 화면에 표시된다. 메뉴바와 Usage HUD도 `DashboardViewModel.providerRows`를 사용하므로 같은 기본 순서를 따르지만, 사용자가 자주 확인하는 계정을 앞으로 옮길 방법이 없다.

계정이 추가·삭제·재연결되거나 프로필 정보가 갱신될 때에도 사용자가 지정한 상대 순서를 유지하면서 OAuth 계정과 API key 계정을 하나의 목록으로 관리해야 한다.

## 목표

- 앱 메인 화면에서 모든 등록 계정의 순서를 변경할 수 있다.
- OAuth 계정과 Claude/OpenAI API key 계정을 하나의 통합 순서로 관리한다.
- 변경한 순서를 앱 재실행 후에도 복원한다.
- 메인 화면, 메뉴바, Usage HUD가 동일한 계정 순서를 사용한다.
- 계정 추가·삭제·재연결·프로필 정보 갱신 후에도 기존 계정의 상대 순서를 가능한 한 보존한다.
- drag-and-drop 외에도 접근 가능한 이동 명령을 제공한다.

## 비목표

- CLIProxyAPI 인증 파일 자체에 표시 순서를 기록하는 기능
- Provider 유형별 자동 그룹화 또는 정렬 규칙
- 메뉴바나 Usage HUD에서 직접 순서를 변경하는 기능
- 서로 다른 기기 간 계정 순서 동기화
- 계정별 설정과 인증 파일의 전체 수명주기 구조를 재설계하는 작업

## 검토한 접근법

### 별도 통합 순서 배열

`AppConfig`에 계정 표시 ID 배열을 저장한다. 계정 설정과 표시 순서를 분리할 수 있고 OAuth와 API key를 같은 방식으로 다룰 수 있다. 이 설계의 채택안이다.

### `oauthCommandProfiles` 배열 재정렬

OAuth 계정 순서는 표현할 수 있지만 API key 계정의 위치를 함께 나타낼 수 없다. API key 위치를 위한 두 번째 체계가 필요해 단일 순서 소스라는 목표에 맞지 않는다.

### 계정별 `displayOrder` 저장

명시적인 정렬 값이지만 OAuth와 API key에 서로 다른 저장 위치가 필요하다. 삽입·삭제 때 순번 재계산과 충돌 처리가 추가되며 현재 범위에서는 복잡성이 크다.

## 저장 모델

`AppConfig`에 다음 필드를 추가한다.

```swift
public var accountOrder: [String]
```

각 값은 `ProviderRowState.ID.rawValue`다.

- OAuth 계정: 대응하는 `OAuthCommandProfile.id`
- Claude API key: `ProviderRowState.ID.claudeAPI.rawValue`
- OpenAI API key: `ProviderRowState.ID.codexAPI.rawValue`

`AppConfig` decoder는 이전 설정 파일에 필드가 없으면 빈 배열을 사용한다. 빈 배열은 아직 사용자 지정 순서가 없는 상태를 의미하며 현재 생성된 계정 순서를 최초 기본값으로 사용한다.

표시 순서는 계정 자체의 속성이 아니다. 따라서 OAuth 인증 JSON에 필드를 추가하지 않고 앱 설정 파일에만 저장한다. 이 구조는 향후 계정 프로필 저장 방식이 변경되더라도 표시 순서 저장소를 독립적으로 유지한다.

## 순서 정규화

`DashboardViewModel`은 기존 방식으로 원본 `ProviderRowState` 목록을 만든 후 저장된 `accountOrder`를 적용한다. 정규화 규칙은 다음과 같다.

1. `accountOrder`에 있는 ID 중 현재 존재하는 계정을 저장 순서대로 배치한다.
2. 중복 ID는 첫 번째 항목만 사용한다.
3. 존재하지 않는 계정 ID는 제거한다.
4. 순서에 없는 현재 계정은 원본 생성 순서대로 목록 마지막에 추가한다.
5. 최종 `providerRows`의 ID 배열을 정규화된 `accountOrder`로 사용한다.

새 계정은 기존 계정의 상대 순서를 변경하지 않고 마지막에 추가된다. 계정 삭제 시 나머지 계정의 상대 순서는 유지된다.

기존 버전에서 마이그레이션된 설정처럼 순서 정보가 없으면 현재 원본 순서가 그대로 사용된다. 이 원본 순서는 기존 동작과 동일하게 OAuth command profile 순서 뒤에 구성된 API key 계정이 이어지는 순서다.

## 공통 표시 흐름

`DashboardViewModel.providerRows`를 유일한 정렬 결과로 사용한다.

- `DashboardView`는 `providerRows` 순서대로 계정 카드를 표시한다.
- `MenuBarStatusSnapshot`은 입력 순서를 변경하지 않고 연결된 계정만 필터링한다.
- `UsageOverlayView`는 `MenuBarStatusSnapshot.connectedProviders`를 사용한다.

따라서 view별 정렬 로직을 추가하지 않는다. 순서 변경 직후 `providerRows`가 갱신되면 메인 화면, 메뉴바, Usage HUD가 같은 순서를 관찰한다. 비활성화되거나 연결되지 않아 메뉴바와 HUD에서 제외되는 계정이 있더라도, 표시되는 나머지 계정의 상대 순서는 메인 목록과 일치한다.

## 순서 변경 API

`DashboardViewModel`은 계정 표시 ID를 입력으로 받는 이동 API를 제공한다.

- 특정 계정을 다른 계정 앞에 삽입하는 drop 동작
- 현재 위치에서 한 칸 위로 이동
- 현재 위치에서 한 칸 아래로 이동

이동 요청은 현재 `providerRows`에 존재하는 ID만 처리한다. 자기 자신 앞에 놓기, 첫 계정을 위로 이동하기, 마지막 계정을 아래로 이동하기 같은 no-op 요청은 저장하지 않는다.

이동 절차는 다음과 같다.

1. 현재 `providerRows`와 `config`를 rollback 값으로 보관한다.
2. 메모리의 목록을 새 순서로 변경해 UI에 즉시 반영한다.
3. 새 ID 배열을 `config.accountOrder`에 기록한다.
4. 기존 `AppConfigStore.save()` 경로로 설정을 원자 저장한다.
5. 저장 실패 시 `providerRows`와 `config`를 이전 값으로 복구하고 오류 toast를 표시한다.

순서 변경은 인증 정보, shell function, 라우팅 설정 또는 서버 설정을 바꾸지 않으므로 서버 재시작이나 shell profile 재설치를 유발하지 않는다.

## 추가·삭제·재연결 동작

### 계정 추가

OAuth 로그인이나 API key 설정 후 계정 목록을 다시 만들 때 저장된 순서에 없는 새 ID를 마지막에 추가한다. 기존 계정의 상대 순서는 유지한다.

### 계정 삭제

계정 삭제 후 목록을 다시 만들면 존재하지 않는 ID가 정규화 과정에서 제거된다. 나머지 계정은 기존 상대 순서를 유지한다. API key를 삭제한 후 다시 등록하면 신규 계정으로 취급해 마지막에 추가한다.

### OAuth 재연결과 설정 변경

재연결, 활성화·비활성화, 닉네임 변경, privacy 설정, 모델 라우팅 변경은 기존 command profile ID를 유지하므로 표시 순서가 바뀌지 않는다. 인증 결과가 완전히 새로운 command profile ID로 생성되는 경우에만 새 계정으로 판단해 마지막에 추가한다.

### 저장 정리 시점

계정 목록 갱신 중 정규화 결과가 기존 `accountOrder`와 다르면 정리된 값을 설정에 반영한다. 계정 데이터 변경과 함께 이미 설정을 저장하는 경로에서는 같은 저장에 포함한다. 단순 새로고침에서만 정리할 필요가 생긴 경우에는 표시를 우선 정상화하고 정리 저장 실패가 계정 조회를 막지 않도록 한다.

## 메인 화면 상호작용

각 계정 카드 왼쪽, Provider avatar 앞에 `line.3.horizontal` 형태의 drag handle을 항상 표시한다.

- handle만 drag 시작 영역으로 사용한다.
- 카드 내부의 설정, 메뉴, privacy, 활성화 버튼은 기존 클릭 동작을 유지한다.
- 계정이 하나뿐이면 handle을 흐리게 표시하고 drag를 비활성화한다.
- drag 중 대상 카드의 앞쪽 삽입 위치를 accent 색상의 가로선으로 표시한다.
- drop 대상 카드는 약한 accent 배경으로 강조한다.
- drop 완료 후 짧은 ease-in-out 위치 전환을 사용한다.
- Reduce Motion이 활성화된 경우 위치 전환 애니메이션을 생략한다.

카드 전체를 draggable로 만들지 않는다. 카드 내부 action과 drag gesture가 충돌하는 것을 방지하기 위해 전용 handle을 사용한다.

## 접근성

Drag handle에는 다음 정보를 제공한다.

- accessibility label: `Reorder account`
- accessibility hint: 현재 계정 이름을 포함해 계정 순서를 바꾸는 컨트롤임을 설명

Drag 조작이 어려운 사용자를 위해 계정 카드 메뉴에 `Move Up`과 `Move Down`을 제공한다. 첫 계정의 `Move Up`, 마지막 계정의 `Move Down`은 비활성화한다. 이 명령은 drag-and-drop과 동일한 view model 이동·저장 경로를 사용한다.

## 오류 처리

순서 저장 실패 시 UI를 저장 전 순서로 되돌린다. 기존 settings toast 영역에 다음 형식의 메시지를 표시한다.

```text
Account order could not be saved: <localized error>
```

순서 파일에 중복 ID, 삭제된 ID 또는 일부 계정만 포함되어 있어도 앱 시작을 실패시키지 않는다. 정규화 가능한 값은 사용하고 나머지는 제거하거나 마지막에 추가한다.

## 테스트

### `AppConfig`와 저장 호환성

- 기존 JSON에 `accountOrder`가 없어도 빈 배열로 decode한다.
- `accountOrder`를 encode하고 다시 decode하면 순서가 보존된다.
- 기본 설정의 `accountOrder`는 빈 배열이다.

### 정규화와 표시 순서

- 저장된 ID 순서대로 `providerRows`가 생성된다.
- OAuth와 API key 계정이 섞인 통합 순서를 적용한다.
- 순서에 없는 새 계정은 마지막에 추가한다.
- 중복 ID와 존재하지 않는 ID를 제거한다.
- 순서 정보가 없으면 기존 원본 순서를 사용한다.
- 메뉴바 snapshot이 연결된 계정의 입력 상대 순서를 보존한다.
- Usage HUD가 같은 snapshot 순서를 사용한다.

### 수명주기

- 새 계정 추가 후 기존 계정의 상대 순서가 유지된다.
- 계정 삭제 후 나머지 계정의 상대 순서가 유지된다.
- OAuth 재연결과 프로필 정보 변경 후 기존 순서가 유지된다.
- API key 삭제 후 재등록하면 마지막에 추가된다.

### 이동과 저장 실패

- 계정을 다른 계정 앞으로 이동하면 `providerRows`와 `accountOrder`가 함께 변경된다.
- move up/down이 한 칸씩 올바르게 이동한다.
- 경계와 자기 자신 대상 이동은 no-op이다.
- 이동 성공 시 설정 저장을 호출한다.
- 저장 실패 시 `providerRows`와 `config.accountOrder`가 rollback된다.
- 저장 실패 메시지가 toast에 표시된다.

### UI 구조

- 계정 카드가 항상 표시되는 drag handle을 제공한다.
- 단일 계정에서는 재정렬이 비활성화된다.
- Move Up/Move Down 명령의 경계 상태가 올바르다.
- drag 대상과 삽입 위치 표시가 계정 ID를 기준으로 동작한다.

## 검증

자동 검증은 다음 순서로 수행한다.

1. 관련 단위 테스트
2. 전체 `swift test`
3. development build

실제 앱에서 drag 시작 영역, 삽입선, 카드 이동 감각, 메뉴바와 Usage HUD의 즉시 반영은 사용자가 development build를 실행해 수동으로 확인한다.
