# Claude OAuth 동적 모델 선택 및 마지막 성공 사용량 유지 설계

## 배경

현재 Claude OAuth 계정을 CLIProxyAPI 경로로 실행하면 앱이 세 Claude 역할의 모델을 고정값으로 주입한다.

- Opus: `claude-opus-4-7`
- Sonnet: `claude-sonnet-4-6`
- Haiku: `claude-haiku-4-5-20251001`

이 값은 `OAuthModelDefaults`에서 정의되고, 개별 OAuth 명령과 Claude round robin 명령이 `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`로 전달한다. 따라서 OAuth credential이나 CLIProxyAPI가 더 최신 모델을 노출하더라도 프록시 명령은 새 모델을 자동으로 사용하지 않는다. 반면 Direct 모드는 proxy 및 model 환경 변수를 제거하므로 Claude Code 공식 로그인의 현재 모델 정책을 따른다.

Codex subscription usage에도 별도의 상태 문제가 있다. 사용량 조회가 한 번 성공한 뒤 credential 오류가 발생하면 현재 구현은 기존 `.available(snapshot)`을 `.unavailable(.credentialExpired)`로 교체한다. 성공 상태만 저장하는 cache가 이후 빈 값으로 덮이면서 마지막 성공 snapshot도 삭제된다. 그 결과 일시적이거나 복구 가능한 credential 문제에서도 기존 사용량 그래프가 사라지고 `Usage unavailable — Credential needs attention.`만 표시된다.

두 문제는 공통적으로 현재 성공 데이터와 현재 제어 상태를 분리하지 않은 데서 발생한다.

- Claude 모델: 사용자가 선택한 정책과 현재 계정에서 resolve된 모델이 분리되어 있지 않다.
- Subscription usage: 마지막 성공 snapshot과 마지막 refresh 오류가 동시에 표현되지 않는다.

## 목표

- Claude OAuth의 CLIProxyAPI 경로에서 계정별 실제 모델 registry를 기준으로 모델을 선택한다.
- 역할별 기본값은 `Automatic`으로 제공하며, 필요하면 Opus·Sonnet·Haiku를 각각 수동 지정할 수 있게 한다.
- `Automatic`은 저장 시점의 최신 모델이 아니라 명령 실행 시점에 해당 계정에 노출된 최신 family 모델로 resolve한다.
- Direct 모드는 모델 선택을 적용하지 않고 Claude Code 공식 로그인 정책을 그대로 사용한다.
- Claude round robin도 실제 선택된 계정의 동일한 모델 정책을 사용한다.
- 사용량 조회에 오류가 발생해도 마지막 성공 snapshot과 디스크 cache를 유지한다.
- 마지막 성공 사용량을 표시하는 동안 오류는 작은 경고 아이콘과 tooltip으로만 알린다.
- 오류 유형에 따른 자동 polling 중단 정책과 수동 refresh 기능을 유지한다.
- 기존 설정과 기존 snapshot cache를 손실 없이 읽는다.

## 비목표

- Direct 모드의 Claude Code 모델 선택을 앱에서 제어하는 기능
- CLIProxyAPI 자체의 모델 registry 또는 OAuth refresh 동작 변경
- Claude API Key provider의 모델 선택 UI
- Codex 모델 및 reasoning 정책 변경
- 사용자가 임의의 Claude-compatible model family 규칙을 정의하는 기능
- 다른 계정이나 API Key의 모델을 Claude OAuth 계정의 fallback으로 사용하는 기능
- Usage 오류 이력의 영구 저장 또는 별도 로그 화면 추가

## 1. Claude OAuth 모델 선택 데이터 모델

### 역할별 선택값

Claude OAuth 계정 설정은 역할별로 자동 또는 명시적 모델을 저장한다.

```swift
public enum ClaudeModelSelection: Codable, Equatable, Sendable {
    case automatic
    case model(String)
}

public struct ClaudeRouting: Codable, Equatable, Sendable {
    public var opus: ClaudeModelSelection
    public var sonnet: ClaudeModelSelection
    public var haiku: ClaudeModelSelection
}
```

`AppConfig.OAuthCommandProfile`에 Claude provider 전용 optional 설정을 추가한다.

```swift
public var claude: ClaudeRouting?
public var codex: Codex?
```

- Claude OAuth profile은 `claude`를 사용한다.
- Codex OAuth profile은 기존 `codex`를 사용한다.
- provider와 맞지 않는 routing 필드는 실행에 사용하지 않는다.
- `claude` 필드가 없는 기존 Claude OAuth profile은 세 역할 모두 `.automatic`으로 해석한다.
- Direct 모드로 변경해도 `claude` 설정은 삭제하지 않는다. 다시 CLIProxyAPI로 전환하면 이전 선택을 복원한다.

### JSON 표현

설정 파일은 역할별 문자열을 사용한다.

```json
{
  "claude": {
    "opus": "automatic",
    "sonnet": "automatic",
    "haiku": "claude-haiku-4-5"
  }
}
```

- `"automatic"`은 `.automatic`을 의미한다.
- 다른 문자열은 `.model(<base-model-id>)`를 의미한다.
- 저장값은 routing prefix가 없는 base model ID다.
- 빈 문자열이나 whitespace-only 값은 decode 시 `.automatic`으로 정규화한다.

## 2. 계정별 Claude 모델 조회

### `ClaudeModelOption`

CLIProxyAPI 응답에서 UI와 resolver가 사용할 typed value를 생성한다.

```swift
public enum ClaudeModelFamily: String, Codable, Equatable, Sendable {
    case opus
    case sonnet
    case haiku
    case other
}

public struct ClaudeModelOption: Equatable, Sendable {
    public let id: String
    public let family: ClaudeModelFamily
    public let created: Int?
}
```

Family 분류 규칙은 base model ID에 적용한다.

- `claude-opus-`로 시작하면 `.opus`
- `claude-sonnet-`으로 시작하면 `.sonnet`
- `claude-haiku-`로 시작하면 `.haiku`
- 그 외 Claude 모델은 `.other`

`.other` 모델은 조회 결과에서 보존하지만 Automatic 후보에는 포함하지 않는다. 기존 수동 저장값이 `.other`로 분류되더라도 임의로 삭제하지 않는다.

### `ProxyModelClient`

계정 prefix로 제한한 Claude 모델 API를 추가한다.

```swift
public func claudeModelOptions(
    port: Int,
    modelPrefix: String
) async throws -> [ClaudeModelOption]
```

동작 규칙:

1. `GET http://127.0.0.1:<port>/v1/models`를 호출한다.
2. ID가 정확히 `"<trimmed-prefix>/"`로 시작하는 항목만 허용한다.
3. 정확한 prefix만 제거하여 base ID를 만든다.
4. Claude family 규칙에 맞는 모델과 `.other` 모델을 typed option으로 변환한다.
5. 같은 base ID가 중복되면 첫 항목을 유지한다.
6. 다른 OAuth 계정, `cpm-claude-api`, Codex, global 모델은 섞지 않는다.
7. 빈 prefix와 유효하지 않은 port는 기존 proxy error 체계로 거부한다.

`/v1/models.created`는 최신 모델 우선순위의 첫 번째 신호로 사용하되, 값이 없거나 동일한 상황을 resolver가 처리한다.

## 3. Claude 모델 resolver

### 책임과 인터페이스

UI와 CLI는 같은 순수 resolver를 사용한다.

```swift
public struct ResolvedClaudeModels: Equatable, Sendable {
    public let opus: String
    public let sonnet: String
    public let haiku: String
}

public enum ClaudeModelResolver {
    public static func resolve(
        routing: ClaudeRouting,
        options: [ClaudeModelOption],
        prefix: String
    ) throws -> ResolvedClaudeModels
}
```

Resolver의 책임은 다음과 같다.

- Automatic 최신 family 모델 선택
- 수동 모델의 현재 availability 검증
- 역할과 다른 family의 수동 선택 거부
- routing prefix가 붙은 최종 model ID 생성
- 결정적이고 테스트 가능한 최신 모델 정렬
- 사용자에게 표시할 typed error 생성

### Automatic 최신 모델 정렬

각 family에서 다음 순서로 최신 모델을 결정한다.

1. `created`가 있는 모델을 우선하고 값이 큰 모델을 선택한다.
2. `created`가 같거나 모두 없으면 Claude model ID의 숫자 version component를 비교한다.
3. version 비교가 동률이면 base model ID 문자열 내림차순으로 결정한다.

숫자 version 비교는 ID에서 연속된 숫자 component를 추출해 정수 배열로 비교한다. 예를 들어 `claude-opus-4-8`은 `[4, 8]`, `claude-opus-4-7`은 `[4, 7]`로 비교한다. 날짜 suffix가 있는 모델도 같은 규칙으로 안정적으로 정렬한다. 마케팅 이름이나 별도 하드코딩 순위를 사용하지 않는다.

### Compatibility fallback

`Automatic`에서 해당 family 모델이 하나도 없으면 기존 `OAuthModelDefaults` 값을 compatibility 후보로 확인한다.

- compatibility ID가 같은 계정의 scoped option에 실제로 존재하면 사용한다.
- scoped option에도 없으면 실행을 중단한다.
- 다른 계정이나 global model로 fallback하지 않는다.

`OAuthModelDefaults`는 더 이상 정상 경로의 기본값이 아니라 이 제한된 compatibility 검사에만 사용한다.

### 수동 선택 검증

수동 선택은 다음을 모두 만족해야 한다.

- 선택 ID가 현재 계정의 scoped option에 존재한다.
- 선택 ID의 family가 역할과 일치한다.
- 선택값에는 routing prefix가 포함되지 않는다.

저장된 수동 모델이 현재 사라졌다면 설정값은 유지하지만 실행 시 조용히 Automatic으로 바꾸지 않는다. 사용자가 다른 모델을 선택하거나 Automatic으로 바꿀 수 있도록 명령을 중단하고 오류를 보여준다.

### 오류 타입

```swift
public enum ClaudeModelResolutionError: LocalizedError, Equatable {
    case noModelsAvailable(prefix: String)
    case noModelForFamily(ClaudeModelFamily)
    case selectedModelUnavailable(role: ClaudeModelFamily, model: String)
    case selectedModelHasWrongFamily(
        role: ClaudeModelFamily,
        model: String,
        actualFamily: ClaudeModelFamily
    )
}
```

오류 문구는 사용자가 취할 행동을 포함한다.

```text
Selected Opus model claude-opus-4-7 is unavailable for this account.
Choose another model or switch Opus to Automatic.
```

## 4. 명령 실행 시점의 동적 해석

### 새로운 helper 명령

개별 Claude OAuth 명령은 shell 생성 시 모델 ID를 고정하지 않는다. 실행할 때 helper가 모델을 resolve한다.

```text
cpm routing claude-models <command-profile-id>
```

Helper 동작:

1. config에서 command profile을 찾는다.
2. profile이 활성 Claude OAuth이고 connection mode가 proxy인지 확인한다.
3. model prefix를 검증한다.
4. 현재 로컬 CLIProxyAPI의 scoped 모델 목록을 조회한다.
5. profile의 `ClaudeRouting`을 resolve한다.
6. shell-safe assignment만 stdout으로 출력한다.

```text
ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-8'
ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-5'
ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5'
```

오류 설명은 stderr에 출력하고 non-zero status를 반환한다. stdout에는 `eval` 가능한 assignment 외의 텍스트를 섞지 않는다.

### 생성되는 shell function

```zsh
claude_work() {
  local routing_env
  if ! routing_env="$(cpm routing claude-models 'claude-work')"; then
    return 1
  fi
  eval "$routing_env"

  ANTHROPIC_BASE_URL="http://127.0.0.1:18317" \
  ANTHROPIC_AUTH_TOKEN='sk-dummy' \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_DEFAULT_SONNET_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_DEFAULT_HAIKU_MODEL" \
  claude "$@"
}
```

기존 helper command path와 shell quoting 정책을 그대로 재사용한다.

### Direct 모드

Direct 모드는 현재처럼 다음 환경 변수를 제거하고 Claude Code를 실행한다.

```zsh
env -u ANTHROPIC_BASE_URL \
    -u ANTHROPIC_AUTH_TOKEN \
    -u ANTHROPIC_API_KEY \
    -u ANTHROPIC_DEFAULT_OPUS_MODEL \
    -u ANTHROPIC_DEFAULT_SONNET_MODEL \
    -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
    claude "$@"
```

기존 구현은 base URL과 credential 변수만 제거하므로, 부모 shell에 model override가 설정된 경우까지 Direct 정책이 오염되지 않도록 세 model 환경 변수도 명시적으로 제거한다.

### Legacy OAuth 명령

`oauthCommandProfiles`가 비어 있을 때 생성되는 legacy Claude OAuth 명령도 고정 모델을 사용하지 않는다. 이를 위해 helper에 명시적인 compatibility 형식을 제공한다.

```text
cpm routing claude-models --legacy
```

Legacy helper는 `AuthProfileStore`의 활성 Claude profile을 조회한다.

- 활성 Claude profile이 정확히 하나이고 non-empty prefix가 있으면, 해당 prefix와 역할별 Automatic routing을 사용한다.
- 활성 Claude profile이 없으면 Claude OAuth 연결이 필요하다는 오류를 반환한다.
- 활성 Claude profile이 둘 이상이면 어떤 계정을 선택할지 추측하지 않고, 앱에서 계정별 command profile을 저장하라는 오류를 반환한다.
- prefix가 없으면 scoped model routing을 안전하게 보장할 수 없으므로 동일하게 계정별 command profile 생성을 요구한다.

이 compatibility 분기는 legacy config에서만 사용한다. 정상 계정별 명령은 항상 command-profile ID 형식을 사용한다.

### Claude round robin

기존 `cpm routing next <round-robin-profile-id>`는 선택된 account의 command profile을 찾은 뒤 해당 profile의 `ClaudeRouting`, model prefix, scoped model options를 같은 resolver에 전달한다.

- 계정마다 접근 가능한 최신 모델이 달라도 실제 선택된 계정 기준으로 resolve한다.
- round robin profile 자체에 별도 Claude model 설정을 추가하지 않는다.
- 계정별 수동 선택을 존중한다.
- 선택된 계정의 수동 모델이 unavailable이면 다른 계정으로 조용히 재선택하지 않고 해당 실행을 실패시킨다. Account selection과 model validation 사이의 오류를 숨기지 않기 위함이다.

## 5. Claude OAuth 설정 UI

### 표시 조건

Claude OAuth settings sheet에서 `Connection = CLIProxyAPI`일 때만 `Models` 섹션을 표시한다.

- CLIProxyAPI: 계정별 model picker 표시
- Direct: model picker 숨김
- Direct 설명: `Direct uses Claude Code's current model policy.`

Connection mode를 전환해도 routing 설정은 보존한다.

### 역할별 picker

각 역할은 하나의 picker를 제공한다.

```text
Opus    [ Automatic — claude-opus-4-8 ▼ ]
Sonnet  [ Automatic — claude-sonnet-5  ▼ ]
Haiku   [ claude-haiku-4-5              ▼ ]
```

Picker 순서:

1. `Automatic — <현재 resolve된 모델>`
2. 해당 family에 속한 실제 scoped 모델
3. 기존 수동 모델이 현재 목록에 없으면 `Unavailable — <model>`

동작 규칙:

- settings sheet가 나타나면 해당 account prefix의 모델을 비동기로 조회한다.
- 로딩 중에는 현재 설정값을 변경하지 않는다.
- 조회 실패 시 저장값을 삭제하거나 global model 목록으로 대체하지 않는다.
- refresh 버튼은 현재 account prefix만 다시 조회한다.
- 사용자가 `Automatic`을 선택하면 config에는 resolve된 ID가 아니라 Automatic 정책을 저장한다.
- 사용자는 역할과 다른 family 모델을 picker에서 선택할 수 없다.
- `.other` 모델은 기존 저장값 보존 외에는 일반 역할 picker에 광고하지 않는다.

Automatic label을 만들기 위한 UI preview와 실제 실행은 같은 `ClaudeModelResolver`를 사용한다. UI와 runtime의 최신 모델 판정이 달라져서는 안 된다.

## 6. Subscription usage 복합 상태

### 상태 모델

마지막 성공 snapshot과 현재 오류를 동시에 표현하기 위해 상태를 확장한다.

```swift
public enum AccountSubscriptionUsageState: Equatable, Sendable {
    case disabled
    case managementKeyNotConfigured
    case loading
    case available(SubscriptionUsageSnapshot)
    case stale(SubscriptionUsageSnapshot, SubscriptionUsageIssue)
    case unavailable(SubscriptionUsageIssue)
}
```

`stale`은 snapshot이 오래됐다는 사실보다, 새 refresh가 실패해 마지막 성공값을 표시 중이라는 의미다.

### 상태 전이

| 이전 상태 | 새 조회 결과 | 최종 상태 |
| --- | --- | --- |
| snapshot 없음 | 성공 | `available(newSnapshot)` |
| snapshot 없음 | 오류 | `unavailable(issue)` |
| `available(old)` | 성공 | `available(newSnapshot)` |
| `available(old)` | 오류 | `stale(old, issue)` |
| `stale(old, previousIssue)` | 성공 | `available(newSnapshot)` |
| `stale(old, previousIssue)` | 오류 | `stale(old, newIssue)` |

모든 `SubscriptionUsageIssue`에 동일한 snapshot 보존 규칙을 적용한다. 오류가 terminal인지 retriable인지는 snapshot 보존이 아니라 polling 정책에만 영향을 준다.

### Polling 정책

기존 `SubscriptionUsageIssue.stopsPolling` 의미를 유지한다.

- `proxyUnavailable`, `authFileNotMatched`, `transientFailure`
  - 마지막 snapshot 유지
  - 자동 polling 계속
- `credentialExpired`, `credentialDisabled`, `managementAPINotSupported`, `schemaMismatch`, `managementKeyRejected`, `providerContractUnsupported`, `unknownProvider`
  - 마지막 snapshot 유지
  - 자동 polling 중단
- 수동 refresh는 terminal issue가 있는 `stale` 또는 `unavailable` profile에도 허용한다.
- 수동 refresh 성공 시 `available(newSnapshot)`으로 바꾸고 정상 polling schedule을 다시 시작한다.

`lastSuccessfulSubscriptionUsageRefreshAt`은 실제 성공 snapshot이 생겼을 때만 변경한다. 오류 report의 `fetchedAt`으로 덮지 않는다.

## 7. Usage cache 정책

Disk cache는 기존처럼 `[String: SubscriptionUsageSnapshot]` 형식을 유지한다. 오류는 영구 저장하지 않는다.

Cache 저장 시 다음 상태에서 snapshot을 추출한다.

- `.available(snapshot)`
- `.stale(snapshot, issue)`

다음 상황에서만 snapshot을 제거한다.

- 사용자가 subscription usage 기능을 끈 경우
- OAuth account가 제거된 경우
- account가 usage 대상에서 명시적으로 제외된 경우
- 사용자가 관련 앱 데이터를 초기화한 경우

Refresh 오류, credential 만료, provider schema 변경만으로 cache를 삭제하지 않는다.

앱 시작 시 cache snapshot은 `.available(snapshot)`으로 복원한다. 다음 refresh가 실패하면 `.stale(snapshot, issue)`로 전환한다. 오류 자체는 다음 실행에서 다시 판정한다.

## 8. Usage 표시

### 메뉴바와 Usage overlay

`.stale(snapshot, issue)`는 `.available(snapshot)`과 같은 그래프와 percentage를 렌더링한다. 큰 오류 문구로 그래프를 대체하지 않는다.

사용자가 선택한 표현 방식에 따라 작은 경고 아이콘만 추가한다.

- SF Symbol: `exclamationmark.triangle.fill`
- 색상: 기존 warning tone
- 배치: 각 account의 usage content를 감싸는 `HStack`의 trailing edge에 한 번만 표시하고, 첫 번째 progress row의 top과 정렬한다.
- tooltip: issue message와 마지막 성공 갱신 시각
- accessibility label: tooltip과 동일한 의미를 완전한 문장으로 제공

Tooltip 예시:

```text
Credential needs attention.
Showing usage last updated 12 minutes ago.
```

Snapshot이 한 번도 없는 `.unavailable(issue)`에서만 현재처럼 `Usage unavailable — <message>` 문구를 표시한다. `.unavailable(.proxyUnavailable)`의 기존 숨김 또는 server 시작 안내 정책도 snapshot이 없을 때만 적용한다.

공통 presentation component를 사용한다.

```swift
SubscriptionUsageWarningIcon(
    issue: issue,
    lastUpdatedAt: snapshot.fetchedAt
)
```

메뉴바와 overlay가 서로 다른 warning 문구나 accessibility label을 만들지 않게 한다.

### CLI usage 출력

CLI에는 icon이나 tooltip이 없으므로 stale snapshot의 수치를 먼저 정상 출력하고 마지막에 경고 한 줄을 추가한다.

```text
Warning: Credential needs attention. Showing last successful usage.
```

Snapshot이 없는 경우에는 기존 `Usage unavailable — ...` 출력을 유지한다.

## 9. 오류 처리

### 모델 조회 및 해석

- `/v1/models` 조회 실패: 설정값 유지, UI에 refresh 실패 표시, 명령은 non-zero로 종료
- scoped 모델 0개: global 또는 다른 provider 모델로 대체하지 않음
- 빈 prefix: 명령 실행 전에 명시적 오류
- 잘못된 수동 model family: 저장값을 몰래 수정하지 않고 실행 오류
- 사라진 수동 모델: `Unavailable` 상태로 UI에 보존하고 실행 오류
- Automatic family 부재: scoped compatibility fallback 확인 후 없으면 실행 오류
- Direct: proxy health check와 model resolver를 호출하지 않음

### Usage 조회

- refresh 오류는 마지막 성공 snapshot을 절대 제거하지 않음
- 오류가 여러 번 바뀌면 최신 issue만 warning에 표시
- terminal issue는 polling만 멈추고 cache와 수동 refresh를 유지
- 성공 report가 일부 profile에만 있으면 profile별로 독립 적용
- settings에서 usage를 끈 경우에만 전체 상태와 cache를 명시적으로 비움

## 10. 호환성 및 마이그레이션

### AppConfig

- 기존 `OAuthCommandProfile`에 `claude`가 없으면 역할별 Automatic
- 기존 `connectionMode`와 Codex config decode는 유지
- 새 Claude routing encode/decode는 기존 파일을 읽을 수 있어야 함
- 앱 시작만으로 기존 config 파일을 강제 rewrite하지 않음

### Model defaults

- `OAuthModelDefaults`의 기존 상수는 compatibility fallback에만 남김
- 정상 proxy 실행과 round robin은 resolver 결과를 사용
- 새 Claude 모델 출시 시 앱 release 없이 Automatic이 선택 가능해야 함

### Usage cache

- cache schema는 변경하지 않으므로 기존 cache를 그대로 읽음
- terminal failure 시 cache가 비워지는 현재 테스트와 동작을 새 정책으로 교체
- cache decode 실패 시 기존처럼 빈 cache로 안전하게 시작

## 11. 구성 요소 경계

- `AppConfig`: 사용자가 선택한 Claude routing 정책 저장
- `ClaudeModelOption`: proxy가 현재 노출하는 model metadata 표현
- `ProxyModelClient`: account-scoped model discovery
- `ClaudeModelResolver`: Automatic 및 수동 선택 정책의 유일한 구현
- `CLIProxyManagerCommand`: runtime routing 명령과 오류 출력
- `ShellFunctionRenderer`: helper 실행 및 environment 연결만 담당
- `RoundRobinSelectionService`: account 선택 후 동일 resolver 호출
- `DashboardViewModel`: scoped model loading과 usage 상태 전이 orchestration
- `SubscriptionUsageSnapshotCacheFileStore`: 마지막 성공 snapshot의 영속화
- `SubscriptionUsageWarningIcon`: stale warning의 공통 presentation

정책을 SwiftUI view나 shell renderer에 중복 구현하지 않는다.

## 12. 테스트 전략

### Core 단위 테스트

1. `ProxyModelClientTests`
   - exact Claude account prefix만 추출한다.
   - prefix를 제거한 base ID와 `created`를 보존한다.
   - Opus/Sonnet/Haiku/Other family를 분류한다.
   - 다른 OAuth account, API Key, Codex 모델을 제외한다.
   - 중복 base ID를 결정적으로 처리한다.

2. `ClaudeModelResolverTests`
   - 각 family의 Automatic 최신 모델을 선택한다.
   - `created` 우선, version component 비교, 문자열 tie-break 순서를 검증한다.
   - 수동 모델을 prefixed ID로 resolve한다.
   - 사라진 수동 모델을 거부한다.
   - 잘못된 family의 수동 모델을 거부한다.
   - family 부재 시 scoped compatibility fallback만 허용한다.
   - fallback도 없으면 오류를 반환한다.

3. `AppConfigTests`
   - 기존 profile은 세 역할 Automatic으로 decode한다.
   - Automatic과 수동 model ID가 round trip한다.
   - Direct 전환에도 Claude routing이 보존된다.
   - 빈 수동 ID가 Automatic으로 정규화된다.

4. `CLIProxyManagerCommandTests`
   - `routing claude-models`가 shell-safe assignment만 stdout에 출력한다.
   - unknown, disabled, non-Claude, Direct profile을 거부한다.
   - unavailable 수동 모델의 actionable error를 stderr에 출력한다.

5. `ShellFunctionRendererTests`
   - Claude proxy function이 runtime helper를 호출한다.
   - shell function에 고정 Claude model ID가 남지 않는다.
   - Direct function이 credential, base URL, 세 model override를 모두 제거한다.
   - helper 실패 시 Claude Code를 실행하지 않는다.

6. `RoundRobinSelectionServiceTests`
   - 실제 선택된 Claude account의 routing과 model scope를 사용한다.
   - account별 서로 다른 최신 모델을 정확히 resolve한다.
   - 수동 unavailable 오류를 다른 account 재선택으로 숨기지 않는다.

### App 단위 테스트

1. Claude OAuth settings
   - CLIProxyAPI에서만 Models 섹션을 표시한다.
   - Automatic label에 현재 resolve 결과를 표시한다.
   - family별 scoped model만 picker에 표시한다.
   - refresh 실패 시 저장 선택값을 보존한다.
   - unavailable legacy 선택을 별도 항목으로 보존한다.
   - Direct 전환 후 복귀해도 설정이 남는다.

2. Subscription usage state
   - 성공 후 retriable 오류는 `stale`이 된다.
   - 성공 후 terminal 오류도 `stale`이 된다.
   - stale 이후 성공은 새 `available`로 교체된다.
   - stale 이후 다른 오류는 snapshot을 유지하고 issue만 교체한다.
   - terminal stale profile은 자동 polling 대상에서 제외된다.
   - terminal stale profile도 force refresh 대상에는 포함된다.
   - 성공하면 polling이 다시 schedule된다.

3. Cache
   - `.available`과 `.stale` snapshot을 모두 저장한다.
   - credential 오류로 cache를 비우지 않는다.
   - 앱 초기화 시 cache를 먼저 복원한다.
   - account 제거와 usage 비활성화는 관련 cache를 제거한다.

4. Presentation
   - stale에서 graph와 percentage를 계속 표시한다.
   - 작은 warning icon을 표시한다.
   - tooltip과 accessibility label에 issue와 last-updated 의미가 포함된다.
   - snapshot이 없을 때만 전체 unavailable 문구를 표시한다.

### 전체 회귀

- `swift test`
- `git diff --check`
- 개발 configuration 앱 bundle build
- 생성된 shell function snapshot 검사

## 13. 개발 빌드 런타임 검증

개발 빌드를 기준으로 실제 generation 요청 없이 검증한다.

1. Claude OAuth account별 `/v1/models`에서 scoped model ID와 `created`를 기록한다.
2. settings UI의 Automatic preview가 resolver 결과와 일치하는지 확인한다.
3. 생성된 shell function이 `cpm routing claude-models`를 호출하는지 확인한다.
4. helper 출력이 실제 현재 최신 scoped model을 가리키는지 확인한다.
5. Direct 명령에서 proxy와 model override 환경 변수가 모두 제거되는지 확인한다.
6. Claude round robin을 여러 번 실행해 실제 선택 account의 prefix와 model policy가 일치하는지 확인한다.
7. Codex usage 성공 snapshot을 만든다.
8. test double 또는 안전한 credential 상태 재현으로 credential issue를 발생시킨다.
9. 그래프가 유지되고 warning icon tooltip이 표시되는지 확인한다.
10. 수동 refresh 성공 후 warning이 제거되고 새 snapshot으로 갱신되는지 확인한다.

검증은 사용량 조회 endpoint와 model listing만 사용하며 billable generation 요청을 보내지 않는다.

## 14. 완료 기준

- Claude OAuth proxy 명령에 출시 시점의 model ID가 고정되지 않는다.
- Automatic은 계정이 실제 노출하는 최신 Opus/Sonnet/Haiku를 다음 명령 실행부터 사용한다.
- 사용자는 계정별로 세 역할을 각각 수동 고정할 수 있다.
- 수동 모델이 사라지면 조용한 fallback 없이 명확한 오류를 받는다.
- Direct는 Claude Code 공식 모델 정책을 사용하고 외부 model override를 제거한다.
- Claude round robin은 실제 선택 account의 routing 정책과 model registry를 사용한다.
- Usage 오류가 마지막 성공 graph, percentage, fetched timestamp, disk cache를 삭제하지 않는다.
- stale usage 오류는 작은 warning icon과 tooltip으로만 표시된다.
- snapshot이 한 번도 없는 경우에만 전체 unavailable 문구를 표시한다.
- terminal issue의 자동 polling 중단과 수동 recovery가 모두 동작한다.
- 기존 AppConfig와 snapshot cache가 손실 없이 호환된다.
- 관련 단위 테스트, 전체 Swift test suite, 개발 빌드 런타임 검증이 통과한다.
