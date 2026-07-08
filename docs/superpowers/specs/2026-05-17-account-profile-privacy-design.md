# Account Profile Privacy Toggle Design

## Goal

계정 카드마다 계정 아이디 표시 뒤에 눈 아이콘 토글을 제공해, 사용자가 화면 공유나 외부 노출 상황에서 연결된 계정 이메일을 빠르게 가릴 수 있게 한다.

## Scope

- 연결된 Claude OAuth, Codex OAuth 계정 카드에만 privacy 토글을 표시한다.
- 각 계정 카드의 숨김/표시 상태는 provider별로 독립적으로 저장한다.
- 앱 재실행 후에도 각 provider의 숨김/표시 상태를 유지한다.
- 저장된 상태가 없는 새 계정은 기본적으로 숨김 상태로 시작한다.
- 숨김 상태에서는 이메일 전체를 blur 처리한다.
- 표시 상태에서는 이메일 원문을 그대로 보여준다.
- 눈 아이콘은 현재 상태를 나타낸다. 숨김 상태는 `eye.slash`, 표시 상태는 `eye`다.

## Non-goals

- auth profile 파일이나 Keychain에 저장된 계정 정보를 암호화하거나 수정하지 않는다.
- provider 연결/해제 동작은 변경하지 않는다.
- disconnected 계정에는 실제 이메일이 없으므로 privacy 토글을 표시하지 않는다.
- blur는 화면 노출을 줄이는 UI 기능이며, 보안 저장소나 권한 모델을 대체하지 않는다.

## Product Behavior

계정 카드의 연결 상태 줄은 다음 구조를 유지한다.

```text
[status LED] [email text] [eye icon]
```

숨김 상태:

```text
[green LED] claude.user@example.com(blurred) [eye.slash]
```

표시 상태:

```text
[green LED] claude.user@example.com [eye]
```

눈 아이콘 버튼은 이메일 바로 뒤에 배치해 “계정 아이디 표시 뒤에 눈 표시”라는 동작을 명확하게 만든다. 기존 `Settings` 버튼과 더보기 메뉴는 카드 오른쪽 액션 영역에 그대로 둔다.

토글 시 blur 변화에는 짧은 ease animation을 적용한다. 이메일 텍스트는 기존처럼 한 줄 표시와 truncation을 유지한다.

## Configuration Model

`AppConfig`에 provider별 privacy 상태를 저장하는 구조를 추가한다.

```swift
public struct AccountPrivacy: Codable, Equatable, Sendable {
    public var claudeHidden: Bool
    public var codexHidden: Bool
}
```

`AppConfig`는 다음 property를 가진다.

```swift
public var accountPrivacy: AccountPrivacy
```

기존 config 파일에는 `accountPrivacy`가 없으므로 decoding 시 기본값을 사용한다. 기본값은 모든 provider 숨김이다.

```swift
AccountPrivacy(claudeHidden: true, codexHidden: true)
```

`resetAllSettings()`는 사용자 계정과 command/nickname을 보존하는 기존 의도를 유지하되, privacy 설정은 일반 preference로 간주해 기본 숨김 상태로 reset한다.

## View Model Flow

`DashboardViewModel`은 provider row를 만들 때 config의 privacy 상태를 함께 반영한다.

- Claude row는 `config.accountPrivacy.claudeHidden`을 사용한다.
- Codex row는 `config.accountPrivacy.codexHidden`을 사용한다.
- `toggleAccountDetailVisibility(_ provider: ProviderRowState.ID)`를 추가해 provider별 hidden 값을 반전하고 config를 저장한다.
- 저장 성공 후 `providerRows`를 다시 빌드한다.
- 저장 실패 시 기존 settings toast 패턴으로 오류 메시지를 표시한다.

`DashboardAccountSnapshot`은 카드 렌더링에 필요한 privacy 값을 전달한다.

```swift
let isAccountDetailHidden: Bool
let showsAccountPrivacyToggle: Bool
```

`showsAccountPrivacyToggle`은 connected 계정에서만 true다.

## View Flow

`ProviderAccountCardView`는 privacy 상태와 토글 callback을 받는다.

```swift
let toggleAccountDetailVisibility: () -> Void
```

연결된 계정의 detail row에서 이메일 텍스트 뒤에 plain button을 둔다.

- `account.isAccountDetailHidden == true`: `Image(systemName: "eye.slash")`
- `account.isAccountDetailHidden == false`: `Image(systemName: "eye")`

숨김 상태에서는 이메일 `Text`에 blur를 적용한다.

```swift
.blur(radius: account.isAccountDetailHidden ? 4 : 0)
```

버튼에는 접근성 label을 둔다.

- 숨김 상태: `Account detail hidden`
- 표시 상태: `Account detail visible`

## Testing

Core config tests:

- 기존 config JSON에 `accountPrivacy`가 없어도 기본 숨김 값으로 decode되는지 확인한다.
- `AppConfig.default.accountPrivacy`가 Claude와 Codex 모두 숨김인지 확인한다.

ViewModel tests:

- 초기 provider rows가 config privacy 상태를 반영하는지 확인한다.
- Claude 토글이 Claude hidden 값만 바꾸고 Codex 값은 유지하는지 확인한다.
- Codex 토글이 Codex hidden 값만 바꾸고 Claude 값은 유지하는지 확인한다.
- 토글 저장 실패 시 settings message가 표시되는지 확인한다.

Snapshot/model tests:

- connected provider는 `showsAccountPrivacyToggle == true`이고 hidden 상태가 전달되는지 확인한다.
- disconnected provider는 `showsAccountPrivacyToggle == false`인지 확인한다.

## Acceptance Criteria

- 연결된 각 계정 카드에서 이메일 뒤에 눈 아이콘이 보인다.
- 새 계정은 기본적으로 이메일 전체가 blur 처리된다.
- 눈 아이콘을 누르면 해당 카드의 이메일만 표시/숨김 전환된다.
- 전환 상태는 앱 재실행 후에도 provider별로 유지된다.
- 숨김 상태의 아이콘은 `eye.slash`, 표시 상태의 아이콘은 `eye`다.
- disconnected 계정 UI는 기존처럼 보이고 privacy 토글이 없다.
