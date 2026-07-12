# Codex 역할별 Fast mode 설계

## 배경

CLIProxyManager는 Codex OAuth와 OpenAI API Key를 Claude Code의 Opus·Sonnet·Haiku 역할에 매핑한다. 각 역할은 현재 다음 값을 독립적으로 저장한다.

- GPT model
- reasoning effort
- context window

Codex의 Fast mode는 모델 자체가 아니라 요청의 service tier를 바꾸는 실행 옵션이다. CLIProxyAPI의 현재 설정 표면에서는 canonical 모델을 별도 alias로 노출하고 해당 alias 요청에 `service_tier: priority`를 주입하는 방식으로 표현할 수 있다.

모델명에 `-fast`만 붙여 보내는 방식은 alias mapping 없이 provider 조회가 실패할 수 있다. CLIProxyAPI upstream도 OAuth 경로에는 `oauth-model-alias + payload`, API Key 경로에는 credential의 `models[].alias + payload` 조합을 안내한다.

참고:

- [CLIProxyAPI #2235: explicit fast latency mode](https://github.com/router-for-me/CLIProxyAPI/issues/2235)
- [CLIProxyAPI #1911: Codex service tier preservation](https://github.com/router-for-me/CLIProxyAPI/issues/1911)
- 번들된 CLIProxyAPI `v7.2.66`의 `config.example.yaml`에는 `oauth-model-alias`, `codex-api-key.models[].alias`, Fast alias 대상 `payload.override`와 `service_tier: priority` 예시가 포함돼 있다.

## 목표

- Codex의 Opus·Sonnet·Haiku 역할마다 Fast mode를 독립적으로 켜거나 끈다.
- Fast를 지원하는 모델에서만 토글을 활성화한다.
- 사용자는 CLIProxyAPI alias와 payload 문법을 직접 관리하지 않는다.
- Codex OAuth, OpenAI API Key, Codex round-robin, 기존 legacy Codex 설정에 동일한 동작을 제공한다.
- Fast와 일반 모드가 같은 canonical 모델을 동시에 사용할 수 있다.
- Fast 설정 변경을 실행 중인 CLIProxyAPI에 자동 반영한다.
- 기존 설정 파일과 Fast를 사용하지 않는 동작을 완전히 호환한다.

## 비목표

- Claude provider에 Fast mode 추가
- 사용자가 임의의 service tier 문자열을 입력하는 기능
- custom OpenAI-compatible provider 지원
- CLIProxyAPI 자체 source 수정
- 모델별 속도나 크레딧 배율의 실시간 측정
- Fast mode가 실제 upstream 계정에서 허용되는지 과금 요청으로 사전 검사
- Fast와 reasoning을 결합한 별도 모델 목록을 사용자에게 노출

## 사용자 선택

설계 논의에서 다음 정책을 확정했다.

- 설정 단위: Opus·Sonnet·Haiku 역할별 토글
- 지원 정책: Fast 지원이 확인된 모델만 활성화
- 전송 방식: 앱이 CLIProxyAPI alias와 payload override를 자동 생성
- 안내 방식: 역할 행의 토글과 표 아래 사용량 안내
- 적용 범위: 모든 Codex 경로
- 반영 방식: 실행 중인 CLIProxyAPI 자동 restart

## 데이터 모델

### `AppConfig.CodexRole`

역할별 Fast 상태를 추가한다.

```swift
public struct CodexRole: Codable, Equatable, Sendable {
    public var model: String
    public var reasoning: CodexReasoning
    public var contextWindow: CodexContextWindow
    public var fastModeEnabled: Bool
}
```

초기값과 decode 기본값은 `false`다.

기존 JSON에는 `fastModeEnabled`가 없으므로 `CodexRole`에 custom `Codable` 구현을 추가하고 누락 시 `false`로 읽는다. 기존 initializer call site가 대량으로 깨지지 않도록 initializer parameter에도 기본값 `false`를 둔다.

### Fast 요청 모델 식별자

Fast 여부와 내부 alias 규칙은 Core의 단일 helper에서 관리한다.

```text
canonical model:     gpt-5.6-sol
managed Fast alias:  gpt-5.6-sol-cpm-fast
reasoning 포함:      gpt-5.6-sol-cpm-fast(xhigh)
```

일반 모드는 기존처럼 다음 식별자를 사용한다.

```text
gpt-5.6-sol(xhigh)
```

내부 suffix는 `-cpm-fast`로 고정한다. 일반적인 upstream `-fast` 이름과 구분하고 앱이 소유하는 alias임을 명확히 하기 위해서다.

helper는 다음 책임만 가진다.

- canonical 모델에서 관리 alias 생성
- 식별자가 관리 alias인지 판별
- 관리 alias에서 canonical 모델 복원
- 역할의 `fastModeEnabled`와 reasoning을 반영한 요청 모델 식별자 생성

`ShellFunctionRenderer`, `RoundRobinSelectionService` 등 기존 `CodexRole.modelIdentifier` 소비자는 동일한 최종 식별자를 받는다. 구현은 `CodexRole.modelIdentifier`가 helper를 사용하도록 하여 경로별 중복 조합을 피한다.

## 모델 capability

### `CodexModelOption`

Fast 지원 여부를 추가한다.

```swift
public struct CodexModelOption: Equatable, Sendable {
    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?
    public var supportsFastMode: Bool
}
```

### metadata decoding

`GET /v1/models?client_version=0.144.0`의 Codex model metadata에서 다음 값을 추가로 읽는다.

- `service_tiers[].id`
- `service_tiers[].name`
- `additional_speed_tiers[]`

다음 중 하나를 만족하면 metadata가 Fast 지원을 명시한 것으로 본다.

- `service_tiers[].id == "priority"`
- `service_tiers[].name`이 대소문자 구분 없이 `Fast`
- `additional_speed_tiers[]`에 `fast` 존재

### scoped model fallback

CLIProxyAPI `v7.2.66`은 template에 존재하지 않는 prefixed 모델을 Codex client metadata로 변환할 때 `service_tiers`를 빈 배열로 만든다. 따라서 OAuth account prefix나 `cpm-codex-api` prefix를 통해 조회한 모델은 실제 Fast 지원 모델이어도 capability가 누락될 수 있다.

이를 보완하기 위해 앱은 번들된 registry에서 확인된 다음 canonical 모델을 보수적인 fallback allowlist로 관리한다.

- `gpt-5.4`
- `gpt-5.5`
- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`

`gpt-5.4-mini`와 그 외 custom·legacy 모델은 metadata가 Fast를 명시하지 않으면 미지원으로 취급한다.

판정 순서는 다음과 같다.

1. metadata가 Fast를 명시하면 지원
2. canonical 모델이 fallback allowlist에 있으면 지원
3. 그 외는 미지원

미확인 모델을 허용하지 않는 이유는 사용자가 Fast가 적용됐다고 오인하는 것을 방지하기 위해서다.

### 내부 alias 필터링

앱이 만든 `*-cpm-fast` alias는 CLIProxyAPI의 `/v1/models` 목록에 다시 나타날 수 있다. 모델 picker에는 canonical 모델만 보여야 하므로 `ProxyModelClient`가 모델 목록과 metadata를 결합하기 전에 관리 alias를 제외한다.

현재 저장 모델이 내부 alias인 비정상·중간 상태에서도 picker에 별도 모델로 추가하지 않고 canonical 모델로 정규화한다.

## 역할 값 정규화

`CodexRoleRoutingOptions`에 Fast 관련 정규화를 추가한다.

- 현재 모델이 Fast를 지원하면 저장된 `fastModeEnabled`를 유지한다.
- Fast 미지원 모델로 변경하면 `fastModeEnabled = false`로 바꾼다.
- capability 조회가 실패해 option 자체가 없으면 Fast를 새로 활성화할 수 없다.
- 모델 변경 시 기존 reasoning 정규화와 Fast 정규화를 한 번의 role update로 적용한다.

기존 설정을 읽는 것만으로 저장 파일을 즉시 다시 쓰지는 않는다. 설정 화면의 in-memory role은 안전한 값으로 표시하고, 사용자가 저장할 때 정규화된 값이 기록된다.

## 설정 UI

`CodexRoleRoutingFields`에 `Fast` 열을 추가한다.

```text
Claude | GPT model | Reasoning | Context | Fast
Opus   | ...       | ...       | ...     | toggle
Sonnet | ...       | ...       | ...     | toggle
Haiku  | ...       | ...       | ...     | toggle
```

동작:

- 선택 모델의 `supportsFastMode == true`: 토글 활성화
- 미지원 또는 capability 미확인: 토글 비활성화
- 미지원 모델로 변경: 토글 즉시 off
- 활성 토글은 기존 accent tint와 small control size 사용

표 아래에는 다음 의미의 안내를 표시한다.

```text
Fast mode can be about 1.5× faster and may consume more usage or credits.
```

정확한 과금 배율을 앱이 보장하지 않으므로 고정된 2× 표현은 사용하지 않는다.

공통 component를 사용하는 다음 화면에 자동 적용한다.

- Codex OAuth account 설정
- OpenAI API Key 설정
- Codex round-robin 설정
- legacy Codex model 설정 sheet

추가 열로 인해 picker가 지나치게 줄지 않도록 provider sheet와 관련 metrics를 조정한다. Fast 열은 고정된 좁은 폭을 사용한다.

## CLIProxyAPI YAML 생성

### 구성 입력

`ProxyServiceManager`는 현재 port와 secret provider만 사용해 관리 YAML을 만든다. Fast 설정은 `AppConfig`에 있으므로 manager에 현재 앱 설정을 읽는 injectable provider를 추가한다.

```swift
appConfigProvider: @Sendable () throws -> AppConfig
```

기본 구현은 `AppConfigStore(paths: paths).load()`를 사용하고, 실패하면 `.default`로 조용히 대체하지 않는다. 저장된 Fast 설정이 있는데 잘못된 YAML을 생성할 수 있으므로 config load 실패는 `prepare/start/restart` 오류로 전달한다.

테스트에서는 고정 `AppConfig` provider를 주입한다.

### OAuth alias

OAuth, legacy, round-robin에서 Fast로 사용하는 canonical 모델을 중복 제거해 생성한다.

```yaml
oauth-model-alias:
  codex:
    - name: "gpt-5.6-sol"
      alias: "gpt-5.6-sol-cpm-fast"
      fork: true
```

`fork: true`를 사용해 canonical 모델과 Fast alias를 함께 유지한다.

수집 대상:

- `oauthCommandProfiles`의 enabled Codex profile
- enabled Codex `roundRobinProfiles`
- legacy `ccodex`

legacy `ccodex`는 OAuth command profile이 없는 기존 fallback 경로에서 사용한다. YAML 생성 자체는 안전하게 중복 제거되므로 동일 canonical 모델이 여러 역할과 프로필에 있어도 alias는 한 번만 기록한다.

### OpenAI API Key alias

`codexAPI.codex`에서 Fast로 사용하는 canonical 모델을 `codex-api-key[].models`에 추가한다.

```yaml
codex-api-key:
  - api-key: "..."
    base-url: "https://api.openai.com/v1"
    prefix: "cpm-codex-api"
    models:
      - name: "gpt-5.6-sol"
        alias: "gpt-5.6-sol-cpm-fast"
```

API Key가 없으면 기존처럼 `codex-api-key` block 자체를 만들지 않는다.

### payload override

OAuth와 API Key에서 사용되는 모든 Fast alias를 중복 제거해 한 rule로 생성한다.

```yaml
payload:
  override:
    - models:
        - name: "gpt-5.6-sol-cpm-fast"
          protocol: "codex"
      params:
        service_tier: priority
```

Fast 역할이 하나도 없으면 다음 section을 생성하지 않는다.

- 관리용 `oauth-model-alias.codex`
- API Key의 `models`
- 관리용 `payload.override`

따라서 Fast를 끄면 다음 `prepare/start/restart`에서 stale alias와 payload rule이 제거된다.

### YAML 소유권

현재 `config.yaml`은 `ProxyServiceManager`가 전체 파일을 원자적으로 재생성한다. Fast section도 같은 renderer가 소유하며 기존 사용자 YAML과 merge하지 않는다.

alias와 payload 생성 순서는 canonical 모델명으로 정렬해 동일 입력에서 항상 동일한 YAML을 만든다. snapshot 성격의 테스트와 diff 확인을 안정화하기 위해서다.

## 저장과 런타임 반영

Fast 설정은 앱 JSON과 shell function뿐 아니라 CLIProxyAPI YAML에도 영향을 준다.

### 변경 감지

Codex 설정 저장 전후에 Fast YAML 입력을 비교한다. 비교 대상은 다음의 정규화된 집합이다.

- OAuth용 Fast canonical 모델 집합
- API Key용 Fast canonical 모델 집합
- 공통 Fast alias 집합

집합이 바뀐 경우에만 proxy configuration restart가 필요하다. reasoning, context window, Fast가 꺼진 역할의 model 변경만으로는 YAML이 바뀌지 않으므로 불필요한 restart를 하지 않는다.

### 실행 중

서버가 실행 중이면 설정 저장 성공 후 restart를 요청한다.

순서:

1. 새 `AppConfig` validation
2. shell function 반영
3. 앱 설정 JSON 저장
4. 새 설정을 이용한 CLIProxyAPI restart
5. health가 ready가 될 때까지 기존 흐름으로 확인

API Key 교체 등 기존 restart 요청과 겹치면 pending flag를 통합해 restart는 한 번만 수행한다.

### 중지 상태

서버가 중지 상태면 restart하지 않는다. 다음 `start`가 저장된 최신 `AppConfig`로 YAML을 생성한다.

### restart 실패

설정 JSON 저장 이후 restart가 실패하면 설정을 rollback하지 않는다. shell function과 JSON은 이미 일관된 새 상태이며, 파일 저장까지 되돌리면 더 큰 불일치가 생길 수 있다.

UI에는 다음 의미를 분명히 표시한다.

```text
Fast mode settings were saved, but CLIProxyAPI could not restart: <reason>
```

사용자는 기존 server control로 다시 시작할 수 있다. Fast alias 설정을 적용하지 못한 상태에서 일반 모델로 조용히 fallback하지 않는다.

## 경로별 데이터 흐름

### Codex OAuth

1. 역할의 `modelIdentifier`가 Fast alias와 reasoning suffix를 생성한다.
2. shell function이 account prefix를 붙인다.
3. CLIProxyAPI의 `oauth-model-alias.codex`가 alias를 canonical 모델로 mapping한다.
4. payload override가 alias 요청에 `service_tier: priority`를 주입한다.

### Codex round-robin

1. round-robin이 선택한 account prefix를 결정한다.
2. profile의 역할별 `modelIdentifier`가 Fast alias를 생성한다.
3. OAuth와 동일한 global alias와 payload rule을 사용한다.

### OpenAI API Key

1. 역할의 `modelIdentifier`가 Fast alias를 생성한다.
2. shell function이 `cpm-codex-api` prefix를 붙인다.
3. credential의 `models[].alias`가 canonical 모델로 mapping한다.
4. 공통 payload override가 `service_tier: priority`를 주입한다.

### legacy Codex

OAuth command profile이 없는 기존 설정은 `ccodex` 역할 값을 사용한다. Fast alias가 있으면 global Codex OAuth alias와 공통 payload rule을 사용한다.

## 오류 처리

- 기존 JSON의 누락 필드: `fastModeEnabled = false`
- Fast 미지원 모델 선택: 저장 전 자동 off
- capability 조회 실패: 새 Fast 활성화 금지
- AppConfig load 실패 during proxy config generation: start/restart 실패로 노출
- CLIProxyAPI가 alias/payload 문법을 거부: start/restart 실패로 노출
- alias collision: 앱의 관리 suffix와 canonical 모델이 충돌하면 Fast를 지원하지 않는 것으로 처리하고 오류를 테스트 가능하게 반환
- YAML escaping: 기존 `yamlDoubleQuoted`를 alias와 model 값에도 사용

## 테스트

### `AppConfigTests`

- Fast 필드가 없는 기존 JSON decode 결과는 `false`
- Fast role encode/decode round-trip
- 일반 모델 식별자 유지
- Fast alias + reasoning suffix 조합
- `auto` reasoning은 Fast alias에 suffix를 추가하지 않음

### `ProxyModelClientTests`

- `service_tiers`와 `additional_speed_tiers` decode
- metadata 기반 Fast 지원
- fallback allowlist 기반 Fast 지원
- `gpt-5.4-mini`와 custom 모델 미지원
- `*-cpm-fast` 관리 alias 필터링
- prefixed 모델의 capability fallback

### `CodexRoleRoutingOptionsTests`

- 지원 모델에서 Fast 유지
- 미지원 모델 변경 시 Fast off
- capability 미확인 모델에서 토글 비활성
- reasoning과 Fast 정규화가 함께 적용됨

### `ProxyServiceManagerTests`

- Fast가 없으면 기존 YAML section과 동일
- OAuth alias와 `fork: true` 생성
- API Key `models[].alias` 생성
- payload override와 `service_tier: priority` 생성
- 중복 canonical 모델 제거와 안정적 정렬
- Fast를 모두 끄면 관련 section 제거
- OAuth만, API Key만, 둘 다 있는 조합
- management key, Claude API Key와 함께 생성
- invalid/missing AppConfig provider 오류 전달

### `ShellFunctionRendererTests`

- legacy Codex Fast role 식별자
- 개별 OAuth profile의 Fast role 식별자와 prefix
- API Key Fast role 식별자와 prefix
- 일반 역할은 canonical 모델 유지
- reasoning suffix가 Fast alias 뒤에 위치

### `RoundRobinSelectionServiceTests`

- Fast role의 account-prefixed alias assignment
- 같은 profile에서 Fast와 일반 역할 혼용

### ViewModel 및 UI tests

- Fast YAML 입력 변경 시 실행 중 server restart 요청
- Fast 집합이 동일하면 restart하지 않음
- API Key restart와 겹치면 한 번만 restart
- restart 실패 메시지
- 지원 모델에서 toggle enabled
- 미지원 모델에서 toggle disabled/off
- 안내 문구와 provider sheet width/metrics

## 실제 검증

앱 검증은 프로젝트 기준에 따라 개발 빌드로 수행한다.

1. 기존 설정 파일로 앱을 열고 모든 Fast 토글이 off인지 확인
2. Codex OAuth에서 Opus만 Fast를 켜고 저장
3. 생성된 `config.yaml`에 OAuth alias와 payload override가 있는지 확인
4. Opus는 Fast alias, Sonnet·Haiku는 canonical 모델로 shell function이 생성되는지 확인
5. OpenAI API Key에서 역할별 Fast를 켜고 credential model alias를 확인
6. Codex round-robin에서 Fast/일반 역할 혼용을 확인
7. 실행 중 저장 시 CLIProxyAPI가 한 번 restart되고 ready로 복귀하는지 확인
8. Fast를 모두 끈 뒤 관련 YAML section이 제거되는지 확인
9. 미지원 모델에서 토글이 비활성화되고 저장값이 false인지 확인

실제 upstream 과금 요청은 자동 검증에 포함하지 않는다. 생성 모델 식별자, YAML alias, payload override, local proxy readiness까지를 end-to-end 검증 범위로 삼는다.

## 성공 기준

- 각 Codex 역할에서 Fast mode를 독립적으로 설정할 수 있다.
- Fast 지원 모델에서만 토글이 활성화된다.
- 동일 canonical 모델의 Fast와 일반 요청이 동시에 올바르게 라우팅된다.
- 사용자가 CLIProxyAPI YAML을 직접 편집하지 않아도 된다.
- 모든 Codex 경로가 동일한 Fast 의미론을 사용한다.
- Fast가 없을 때 기존 생성 YAML과 실행 모델 ID가 변하지 않는다.
- 기존 설정 decode와 개발 빌드 검증이 통과한다.
