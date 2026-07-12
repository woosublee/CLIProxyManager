# Provider 라우팅 및 Codex 모델 capability 설계

## 배경

API Key와 OAuth 계정별 명령을 분리하는 작업 중 다음 문제가 확인됐다.

1. Claude의 Direct/CLIProxyAPI 선택이 API Key까지 적용되는 것처럼 안내되고 있었다. 실제로 사용자 선택이 필요한 대상은 Claude OAuth뿐이다.
2. OpenAI API Key 설정으로 생성한 CLIProxyAPI YAML에는 `base-url`이 없었다. 번들된 CLIProxyAPI 7.2.66은 `base-url`이 비어 있는 `codex-api-key` 항목을 제거하므로 OpenAI API Key가 런타임 인증으로 등록되지 않았다.
3. OpenAI API Key 설정 화면에 보인 `gpt-5.6-terra`는 API Key 전용 모델 응답이 아니라 저장된 이전 선택값이었다.
4. Codex 모델 설정은 모든 모델에 동일한 reasoning 값을 노출했지만, 실제 지원 범위는 모델마다 다르다.
5. OpenAI API Key 명령의 실행 전 검사는 전체 `/v1/models` 요청의 성공 여부만 확인해 API Key가 등록되지 않은 상태도 정상으로 오인했다.

이 문서는 `2026-07-12-api-key-file-store-design.md`의 API Key connection mode 관련 내용을 수정·구체화한다. 비밀 파일 저장 방식은 기존 설계를 그대로 유지한다.

## 확인된 런타임 동작

개발 경로의 실제 CLIProxyAPI 7.2.66을 사용해 다음을 확인했다.

### 기존 설정

```yaml
codex-api-key:
  - api-key: "..."
    prefix: "cpm-codex-api"
```

결과:

- CLIProxyAPI 시작 로그: `0 Codex keys`
- `/v1/models`의 `cpm-codex-api/*`: 0개
- 앱의 API Key scoped model 결과: 0개
- UI에는 설정 파일에 저장된 `gpt-5.6-terra`만 보존됨

### `base-url`을 추가한 설정

```yaml
codex-api-key:
  - api-key: "..."
    base-url: "https://api.openai.com/v1"
    prefix: "cpm-codex-api"
```

결과:

- CLIProxyAPI 시작 로그: `1 Codex key`
- `/v1/models`의 `cpm-codex-api/*`: 10개
- `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` 등이 API Key 전용 prefix로 등록됨

Claude API Key는 `base-url`이 없어도 CLIProxyAPI가 항목을 유지하고 `https://api.anthropic.com`을 기본값으로 사용한다. 실제 응답에서 `cpm-claude-api/*` 모델 14개와 `1 Claude API key` 등록을 확인했다. 이번 변경에서는 두 공식 provider 설정을 명시적으로 동일한 형태로 관리한다.

## 목표

- 연결 방식 선택은 Claude OAuth 설정에서만 제공한다.
- Claude OAuth의 선택지 이름은 `CLIProxyAPI`와 `Direct`로 통일한다.
- Claude API Key와 OpenAI API Key는 항상 CLIProxyAPI를 경유한다.
- 두 API Key provider에 공식 upstream base URL과 고정 prefix를 명시한다.
- OpenAI API Key 모델 목록을 실제 `cpm-codex-api/*` 모델 응답으로 구성한다.
- Codex OAuth와 OpenAI API Key 모두 account/provider prefix의 실제 모델 및 reasoning metadata를 사용한다.
- 신규 Codex OAuth와 OpenAI API Key 설정의 기본 모델은 `gpt-5.6-terra`로 한다.
- API Key 명령은 전용 prefix 모델이 실제로 등록된 경우에만 실행한다.
- 기존 저장 모델은 자동 변경하지 않고, capability가 확인된 시점에만 지원하지 않는 reasoning을 안전하게 정규화한다.

## 비목표

- 사용자가 custom base URL을 입력하는 기능
- OpenAI-compatible third-party provider 지원
- Claude API Key의 모델 매핑 UI 추가
- context window 지원 범위의 동적 제한
- 실제 과금 요청을 이용한 API Key 유효성 검사
- CLIProxyAPI 자체의 모델 registry 또는 upstream 동작 변경

## 연결 방식 UI

### Claude OAuth

Claude OAuth 계정 설정에만 segmented connection picker를 표시한다.

- `CLIProxyAPI`: 등록된 OAuth 계정을 로컬 CLIProxyAPI의 account prefix로 고정해 실행한다.
- `Direct`: proxy 관련 환경 변수를 제거하고 현재 Claude Code 공식 로그인으로 직접 실행한다.

기존 `Claude Code current login` 라벨은 `Direct`로 변경한다. 저장 모델은 기존 `AppConfig.OAuthCommandProfile.connectionMode`를 계속 사용한다.

### Claude API Key

사용자 선택 없이 항상 `CLIProxyAPI`로 실행한다. API Key 화면은 고정 라우팅임을 안내하되 Direct 선택지를 제공하지 않는다. 과거 설정의 `connectionMode` 필드는 호환 decode만 하고 새 저장에는 사용하지 않는다.

### Codex OAuth 및 OpenAI API Key

Codex OAuth는 기존처럼 CLIProxyAPI를 통해 Claude Code 모델 tier를 GPT 모델에 매핑한다. OpenAI API Key도 항상 CLIProxyAPI를 경유하며 connection picker를 제공하지 않는다.

Add Provider 및 설정 화면의 설명에서 API Key에 Direct 선택이 가능한 것처럼 보이는 문구를 제거한다.

## CLIProxyAPI provider 설정

`ProxyServiceManager`가 API Key가 있을 때 다음 YAML을 생성한다.

```yaml
claude-api-key:
  - api-key: "<stored-key>"
    base-url: "https://api.anthropic.com"
    prefix: "cpm-claude-api"

codex-api-key:
  - api-key: "<stored-key>"
    base-url: "https://api.openai.com/v1"
    prefix: "cpm-codex-api"
```

base URL은 앱 설정 JSON에 저장하지 않는다. 현재 provider 유형은 각각 공식 Anthropic API Key와 공식 OpenAI API Key만 의미하므로 YAML 생성 상수로 관리한다.

API Key가 없으면 해당 provider 블록을 생성하지 않는 기존 동작을 유지한다. YAML escaping과 파일 권한 정책도 기존 구현을 유지한다.

## 모델 capability 데이터 모델

문자열 배열만 전달하던 Codex 모델 조회 결과를 typed metadata로 확장한다.

```swift
struct CodexModelOption: Equatable, Sendable {
    var id: String
    var supportedReasoning: [AppConfig.CodexReasoning]
    var defaultReasoning: AppConfig.CodexReasoning?
}
```

`id`는 UI와 설정에 저장할 base model ID다. account/API Key prefix와 모델명 끝의 thinking suffix는 제거된 값이어야 한다.

`AppConfig.CodexReasoning`에는 `max`를 추가한다.

```text
auto, low, medium, high, xhigh, max
```

`auto`는 CLIProxyAPI metadata의 reasoning level이 아니라 앱의 의미론이다. `auto`를 선택하면 모델 ID에 reasoning suffix를 붙이지 않는다. `max`는 `(max)` suffix로 렌더링한다. API Key 전용 prefix 모델 metadata에서 제공되지 않는 `ultra`는 앱 선택지에 추가하지 않는다.

## 모델 및 capability 조회

### 일반 모델 목록

기존 `/v1/models` 응답은 모델 ID, owner, created만 제공한다. OAuth account와 API Key scope를 구분하는 기본 모델 목록 및 기존 fallback에 계속 사용한다.

### Codex metadata 목록

같은 로컬 CLIProxyAPI에 다음 요청을 추가한다.

```text
GET /v1/models?client_version=0.144.0
Authorization: Bearer sk-dummy
```

이 응답의 `models[]`에서 다음 필드를 읽는다.

- `slug`
- `supported_reasoning_levels[].effort`
- `default_reasoning_level`
- `visibility`

모델 scope는 기존과 동일하게 prefix로 제한한다.

- Codex OAuth 계정: 해당 `OAuthCommandProfile.modelPrefix`
- OpenAI API Key: `cpm-codex-api`
- Codex round robin: 포함 계정들의 공통 base model 집합

prefix를 제거한 base model ID를 key로 하여 일반 모델 목록과 metadata를 결합한다. 이 결합은 OpenAI API Key뿐 아니라 각 Codex OAuth account prefix와 Codex round robin에도 동일하게 적용한다. 모델 표시는 일반 `/v1/models`의 created 내림차순을 유지하되, 기본 모델 선택에는 동률 순서를 사용하지 않는다.

metadata 응답에 특정 모델이 없으면 해당 모델은 목록에서 제거하지 않는다. 모델은 일반 응답을 기준으로 유지하고 capability만 unknown으로 취급한다.

## 기본 모델 정책

신규 Codex OAuth 계정과 신규 OpenAI API Key 설정은 `gpt-5.6-terra`가 해당 scoped 모델 목록에 있으면 Opus·Sonnet·Haiku의 초기 모델로 사용한다. `terra`가 없으면 현재 scoped 모델 목록의 첫 사용 가능 모델로 fallback한다.

`AppConfig.default.ccodex`도 신규 설정 fallback과 일치하도록 모델을 `gpt-5.6-terra`로 변경하되 역할별 reasoning 기본값은 유지한다.

- Opus: `xhigh`
- Sonnet: `medium`
- Haiku: `low`

기존 OAuth command profile, 기존 `ccodex`, 기존 OpenAI API Key에 저장된 모델은 자동 migration하지 않는다. 사용자가 설정 화면에서 모델을 변경하거나 신규 provider를 생성할 때만 새 기본 정책을 적용한다.

## reasoning 선택지와 정규화

`CodexRoleRoutingFields`를 사용하는 모든 Codex 설정에 동일한 규칙을 적용한다.

- Codex OAuth 계정
- OpenAI API Key
- Codex round robin

### capability가 알려진 모델

Reasoning picker는 다음 순서로 구성한다.

1. `auto`
2. metadata가 제공한 supported reasoning levels

예시:

| 모델 | 선택지 |
| --- | --- |
| `gpt-5.4`, `gpt-5.5` | `auto`, `low`, `medium`, `high`, `xhigh` |
| `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` | `auto`, `low`, `medium`, `high`, `xhigh`, `max` |

모델 변경 후 현재 reasoning이 새 모델에서 지원되지 않으면 다음 순서로 정규화한다.

1. metadata의 `default_reasoning_level`이 지원 목록에 있으면 사용
2. 그렇지 않으면 `auto` 사용

### capability가 알려지지 않은 모델

지원하지 않는 값을 추측해 새 선택지로 광고하지 않는다.

- `auto`는 항상 제공한다.
- 기존 저장 reasoning이 `auto`가 아니면 데이터 손실 방지를 위해 현재 값만 추가로 표시한다.
- 사용자가 `auto`를 선택하거나 capability가 로드되기 전까지 기존 값을 임의 변경하지 않는다.

이 규칙은 metadata 요청 실패나 custom/legacy model ID에도 적용한다.

## API Key 명령 실행 전 검사

두 API Key shell function은 전체 모델 endpoint의 성공 여부가 아니라 전용 prefix 모델의 존재를 확인한다.

```bash
# Claude API Key
grep -q 'cpm-claude-api/'

# OpenAI API Key
grep -q 'cpm-codex-api/'
```

OpenAI API Key가 등록되지 않은 상태에서 OAuth 모델만 존재해도 검사를 통과하지 않아야 한다. 검사 실패 시 Claude Code를 실행하지 않고 기존 provider별 오류 메시지와 non-zero status를 반환한다.

OAuth 명령과 round-robin 명령의 preflight는 이번 범위에서 변경하지 않는다.

## 오류 처리

- 일반 모델 목록 요청 실패: 기존 `CodexModelLoadingState.failed` 흐름을 사용한다.
- metadata 요청 실패: 일반 모델 목록을 유지하고 capability를 unknown으로 처리한다.
- API Key scoped 모델이 0개: unrelated OAuth/global 모델로 대체하지 않고 현재 저장 선택값을 보존하며 로딩 오류 안내를 유지한다.
- 잘못된 metadata reasoning 값: 알려진 enum 값만 수용하고 나머지는 무시한다.
- 기존 설정에 `max`가 없던 것은 decode 호환성에 영향이 없다. 새 `max` 값은 추가 enum case로 encode/decode한다.
- API Key 추가·교체 후에는 기존 동작대로 실행 중인 CLIProxyAPI를 재시작해 provider registry를 갱신한다.

## 테스트 전략

### Core 단위 테스트

1. `ProxyServiceManagerTests`
   - Claude API Key YAML에 `https://api.anthropic.com`과 `cpm-claude-api`가 생성된다.
   - OpenAI API Key YAML에 `https://api.openai.com/v1`과 `cpm-codex-api`가 생성된다.
   - Key가 없으면 해당 블록과 base URL이 생성되지 않는다.

2. `ProxyModelClientTests`
   - 일반 `/v1/models`의 prefix별 base model 추출을 검증한다.
   - Codex metadata 응답의 reasoning levels/default를 파싱한다.
   - unknown reasoning과 중복 모델을 안전하게 처리한다.
   - metadata와 일반 모델 순서를 결합한다.

3. `AppConfigTests`
   - `CodexReasoning.max` encode/decode와 `modelIdentifier`의 `(max)` suffix를 검증한다.
   - 기존 reasoning 저장값의 decode 호환성을 유지한다.

4. `ShellFunctionRendererTests`
   - Claude API Key preflight가 `cpm-claude-api/`를 검사한다.
   - OpenAI API Key preflight가 `cpm-codex-api/`를 검사한다.
   - 전체 모델 endpoint만 성공하는 검사는 생성되지 않는다.

### App 단위 테스트

1. 모델별 reasoning 옵션
   - GPT-5.5는 `max`를 표시하지 않는다.
   - GPT-5.6은 `max`를 표시한다.
   - 모델 변경 시 지원하지 않는 reasoning이 default 또는 `auto`로 정규화된다.
   - capability unknown 모델은 `auto`와 기존 저장값만 보존한다.

2. 모델 scope와 기본값
   - OpenAI API Key 화면은 `cpm-codex-api` 모델과 reasoning metadata만 사용한다.
   - Codex OAuth 계정은 해당 account prefix 모델과 reasoning metadata만 사용한다.
   - Codex round robin은 포함 account들의 공통 모델과 공통 reasoning만 사용한다.
   - 신규 Codex OAuth와 OpenAI API Key는 scoped 목록에 `gpt-5.6-terra`가 있으면 세 역할의 초기 모델로 사용한다.
   - 기존 저장 모델은 자동 변경하지 않는다.
   - API Key scoped refresh 실패 시 OAuth/global 모델을 섞지 않는다.

3. 연결 방식 UI와 저장
   - Claude OAuth만 `CLIProxyAPI`/`Direct` 값을 저장한다.
   - Claude API Key와 OpenAI API Key save callback에는 connection mode 선택이 없다.
   - Add Provider 설명은 API Key에 Direct 선택이 있다고 안내하지 않는다.

### 개발 빌드 런타임 검증

개발 빌드 기준으로 다음을 확인한다.

1. API Key를 저장하고 CLIProxyAPI를 재시작한다.
2. 로그에 `1 Claude API keys`와 `1 Codex keys`가 등록된다.
3. `/v1/models`에 `cpm-claude-api/*`, `cpm-codex-api/*`, 각 Codex OAuth account prefix 모델이 존재한다.
4. OpenAI API Key와 각 Codex OAuth 설정 화면에서 scoped GPT 모델이 표시된다.
5. API Key 및 OAuth 모두 GPT-5.5와 GPT-5.6 선택 시 reasoning 메뉴가 각각 다른 값을 표시한다.
6. 신규 Codex OAuth와 OpenAI API Key의 초기 모델이 `gpt-5.6-terra`인지 확인한다.
7. API Key provider 블록을 제거한 상태에서는 해당 shell command preflight가 실패한다.

검증 과정에서는 실제 generation 요청을 보내지 않아 API 사용량이나 과금을 발생시키지 않는다.

## 완료 기준

- Claude OAuth에서만 `CLIProxyAPI`와 `Direct`를 선택할 수 있다.
- 두 API Key provider가 공식 base URL과 고정 prefix로 CLIProxyAPI에 등록된다.
- OpenAI API Key가 런타임 로그에서 Codex key로 등록되고 전용 모델 목록을 반환한다.
- API Key shell 명령이 다른 provider의 모델 존재만으로 실행되지 않는다.
- Codex OAuth, OpenAI API Key, Codex round robin 설정 화면이 scoped 모델별 지원 reasoning을 정확히 제한한다.
- 신규 Codex OAuth와 OpenAI API Key의 기본 모델은 `gpt-5.6-terra`다.
- 기존 사용자 모델 설정과 현재 선택값을 자동 변경하거나 capability 확인 전에 손실하지 않는다.
- 관련 단위 테스트와 개발 빌드 런타임 검증이 모두 통과한다.
