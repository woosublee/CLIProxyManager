# Provider별 복수 API Key Profile 설계

**작성일:** 2026-07-27
**상태:** 구현 완료

## 배경

현재 Claude와 Codex/OpenAI API Key는 provider별 단일 설정, 단일 secret 파일, 단일 routing prefix, 단일 usage profile로 관리된다. CLIProxyAPI 설정은 이미 provider별 key 목록을 지원하므로, Manager의 singleton 경계를 stable ID 기반 profile collection으로 확장한다.

## 목표

- 같은 provider에 여러 API Key profile을 등록한다.
- 각 profile이 nickname, command, model routing, permission을 독립적으로 가진다.
- 기존 첫 API Key의 command, routing prefix, account order, HUD visibility와 usage history를 유지한다.
- 실제 API Key는 `config.json`과 generated shell script에 저장하지 않는다.
- profile별 고유 prefix로 요청과 예상 비용을 정확히 귀속한다.

## Schema v3

`AppConfig`의 `claudeAPI`와 `codexAPI`를 `apiKeyProfiles`로 교체한다.

```json
{
  "schemaVersion": 3,
  "apiKeyProfiles": [
    {
      "id": "claude-api",
      "provider": "claude",
      "secretReference": "claude-api-key",
      "commandName": "claude_work",
      "nickname": "Work",
      "claude": { "mode": "automatic" },
      "dangerousPermissionsEnabled": false
    }
  ]
}
```

- 기존 첫 Claude/OpenAI profile ID는 각각 `claude-api`, `codex-api`다.
- 신규 ID는 `<provider>-api-<lowercase UUID>`다.
- 신규 secret reference는 `<profile-id>-key`다.
- routing prefix는 저장하지 않고 `cpm-<profile-id>`로 계산한다.
- ID, secret reference와 prefix는 생성 후 변경하거나 재사용하지 않는다.

## Secret 저장

기존 파일을 이동하지 않는다.

- `claude-api` → `claude-api-key.json`
- `codex-api` → `codex-api-key.json`
- 신규 profile → `<profile-id>-key.json`

`SecretReference`는 영문 소문자, 숫자와 `-`만 허용하며 path separator, `..`, 제어문자를 거부한다. `FileSecretStore`의 `0700` directory, `0600` file/lock, owner/regular-file 검사, `O_NOFOLLOW`, `flock`, `fsync`, atomic rename 규칙은 유지한다.

## Migration

- schema missing/v1은 기존 legacy adapter로 읽는다.
- schema v2의 singleton 설정은 fixed ID와 legacy secret reference를 가진 profile 후보로 변환한다.
- schema v3은 canonical document로 읽는다.
- future schema는 조용히 downgrade하지 않고 거부한다.
- legacy profile 후보는 secret이 있거나 command/nickname/routing/permission이 기본값이 아닐 때 유지한다.
- config save 실패 시 기존 config와 secret 파일을 변경하지 않고 다음 실행에서 재시도한다.

## Runtime routing

각 configured profile은 CLIProxyAPI YAML에 별도 entry로 렌더링된다.

```yaml
claude-api-key:
  - api-key: "..."
    base-url: "https://api.anthropic.com"
    prefix: "cpm-claude-api"
  - api-key: "..."
    base-url: "https://api.anthropic.com"
    prefix: "cpm-claude-api-..."
```

각 shell command는 profile ID를 `cpm routing claude-models --api-profile <id>`에 전달하거나, Codex model에 해당 profile prefix를 직접 적용한다. API Key와 secret 파일 경로는 shell에 포함하지 않는다.

기존 `--api`, `claude-api-key`, `codex-api-key` CLI 입력은 reserved first profile을 위한 compatibility alias로 유지한다.

## Usage history

- queue record의 managed prefix, provider, executor와 auth index 존재 여부를 함께 검증한다.
- `claude-api`와 `codex-api`는 기존 ledger를 그대로 이어서 표시한다.
- 신규 profile은 생성 이후 자기 ID bucket에만 집계한다.
- profile 삭제 시 ledger는 삭제하지 않는다.
- 알 수 없는 prefix는 다른 profile로 추측 귀속하지 않는다.

## UI와 transaction

- Add Provider의 API Key 선택은 항상 신규 draft를 연다.
- 기존 row는 해당 profile만 편집·key 교체·삭제한다.
- create 실패 시 새 secret을 삭제한다.
- replace/save 실패 시 이전 secret을 복원한다.
- delete/save 실패 시 삭제한 secret을 복원한다.
- secret이 사라진 profile도 disconnected row로 남겨 key를 복구하거나 profile을 삭제할 수 있게 한다.
- command uniqueness는 OAuth, round-robin, 모든 API Key profile을 함께 검사한다.

## 검증

- v1/v2 → v3 migration과 future schema 거부
- 같은 provider에 2개 이상의 profile 생성·편집·삭제
- secret reference 경로 안전성과 파일 권한
- multi-entry proxy YAML과 profile별 shell routing
- profile별 usage 귀속과 legacy history 유지
- focused tests, 전체 `swift test`, debug bundle, ad-hoc codesign verification
