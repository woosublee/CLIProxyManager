# API Key 파일 저장 및 설정 보완 설계

## 목표

API Key 기능을 기존 OAuth 설정 흐름과 일관되게 마무리한다.

- Claude API Key: CLIProxyAPI 경로에서 Automatic 또는 역할별 명시 모델을 선택하는 Claude 모델 라우팅과 명령별 권한 건너뛰기를 설정한다.
- OpenAI API Key: Codex OAuth의 모델 매핑과 명령별 권한 건너뛰기를 재사용한다.
- API Key는 macOS Keychain 대신 로컬 파일에 저장한다.

## 비밀 저장소

`FileSecretStore`를 기본 `SecretStore` 구현으로 둔다. 저장 위치는 `~/.cliproxy-manager/api-keys/`이며 개발 빌드는 기존 경로 규칙을 따라 `~/.cliproxy-manager/dev/api-keys/`를 사용한다.

| SecretKey | 파일 |
| --- | --- |
| `claude-api-key` | `claude-api-key.json` |
| `codex-api-key` | `codex-api-key.json` |

각 파일에는 versioned JSON envelope로 key를 저장한다. 값은 암호화되지 않은 평문이다. 대신 디렉터리는 `0700`, 파일과 lock file은 `0600`으로 강제한다. 읽기와 삭제에서는 `O_NOFOLLOW`로 심볼릭 링크를 거부하고, 현재 사용자 소유의 일반 파일 및 정확히 `0600` 권한인지 검증한다. 쓰기는 같은 디렉터리의 임시 `0600` 파일에 기록·`fsync` 후 atomic rename하며 `flock` lock file로 동시 접근을 직렬화한다.

기존 `SubscriptionUsageManagementKeyFileStore`의 파일 안전성 패턴을 재사용한다. 아직 배포되지 않은 API Key 기능이므로 Keychain의 테스트 값을 자동 마이그레이션하거나 fallback하지 않는다.

## 설정 모델 및 화면

`AppConfig`에 API Key 명령별 권한 설정을 추가한다.

- `ClaudeAPI`는 Opus/Sonnet/Haiku 역할별 `ClaudeRouting`과 `dangerousPermissionsEnabled`를 가진다. 기존 `model`과 `connectionMode` 저장값은 호환성 있게 decode만 하며, 새 화면과 shell rendering은 항상 CLIProxyAPI 경로를 사용한다.
- `codexAPI`는 Codex의 `opus`/`sonnet`/`haiku` 모델 역할 매핑과 별도의 `dangerousPermissionsEnabled`를 가진 API Key 설정 구조로 둔다. OAuth 프로필의 Codex 모델 설정과 전역 `ccodex` 설정은 변경하지 않는다.

Claude API Key 시트에서는 API Key, 명령 이름, `ClaudeRoleRoutingFields`, `Skip permission prompts`를 노출하고 CLIProxyAPI 고정 경로임을 안내한다. OpenAI API Key 시트에서는 API Key, 명령 이름, OAuth Codex 시트의 `CodexRoleRoutingFields`, `Skip permission prompts`를 노출하며 CLIProxyAPI 경유임을 계속 안내한다.

각 API Key의 skip 토글은 전역 `includeDangerouslySkipPermissions` 및 OAuth 계정별 값과 독립적이다.

## 실행 및 프록시 동작

- Claude API Key 명령은 항상 `cpm-claude-api/` prefix와 로컬 프록시를 사용한다. `renderClaudeAPIFunction()`은 실행 시 `cpm routing claude-models --api`를 호출해 저장된 역할별 정책과 현재 노출 모델을 해석하고 `ANTHROPIC_DEFAULT_*_MODEL`을 주입한다.
- Claude API Key 화면은 OAuth 프록시 화면과 동일한 `ClaudeRoleRoutingFields`를 사용해 Automatic 또는 역할별 명시 모델 선택을 제공한다.
- OpenAI API Key 명령은 `cpm-codex-api/` prefix와 API Key 전용 Codex 역할 매핑을 통해 로컬 프록시를 사용한다.
- API Key command의 `--dangerously-skip-permissions` 포함 여부는 해당 API Key 설정만 따른다.
- 프록시 YAML은 FileSecretStore가 읽은 API Key가 있을 때만 기존 `claude-api-key`·`codex-api-key` provider 블록을 생성한다.

## 오류 처리

잘못된 권한, 소유자, 파일 형식, 심볼릭 링크, 읽기·쓰기 실패는 기존 `SecretStoreError`로 노출한다. API Key 명령은 읽기 실패 시 기존 안내 메시지와 non-zero return으로 중단한다. API Key 변경·삭제 뒤 서버가 실행 중이면 프록시를 재시작한다.

## 테스트

- FileSecretStore의 생성, 읽기, 교체, 삭제, 파일 권한, 잘못된 파일 상태, 심볼릭 링크 거부, 동시 안전성 경로를 검증한다.
- AppConfig의 신규 API Key 권한/모델 설정 encode·decode 및 이전 설정 호환성을 검증한다.
- API Key 각 시트의 초기값과 save callback 전달 값을 검증한다.
- shell renderer가 Claude API Key에서 `routing claude-models --api` 결과를 사용하고 해당 skip 값을 적용하는지 검증한다.
- shell renderer가 OpenAI API Key 전용 Codex 모델 매핑과 해당 skip 값을 반영하는지 검증한다.
- DashboardViewModel, AutomaticShellInstallService, ProxyServiceManager, `cpm secret`이 기본 FileSecretStore를 일관되게 사용하는지 검증한다.
