# Codex 역할별 Fast mode 개발 현황

## 현재 상태

Codex의 Opus·Sonnet·Haiku 역할별 Fast mode 구현과 development build를 완료했다.

## 완료된 작업

- `CodexRole.fastModeEnabled` 저장 및 기존 JSON 하위 호환 decode
- 앱 관리 Fast alias `-fast`와 reasoning suffix 조합
- Codex model metadata의 Fast capability 조회와 fallback allowlist
- managed alias metadata 제외 및 case-insensitive metadata 결합
- OAuth, OpenAI API Key, round-robin, legacy 설정 화면의 역할별 Fast toggle
- capability unknown/unsupported 구분과 저장값 보존
- round-robin auth-profile prefix fallback 및 known-empty reasoning 정규화
- OAuth/API Key alias와 `service_tier: priority` payload YAML 생성
- Fast 미사용 시 기존 YAML의 바이트 단위 호환성 유지
- legacy, OAuth, API Key, round-robin shell routing 테스트
- Fast 설정 변경 시 proxy restart와 API Key 변경 coalescing
- restart generation drain, lifecycle 직렬화, readiness/error/recovery 처리
- reserved `-fast` suffix collision 검증
- 한국어·영어 README 문서화

## 자동 검증

- 전체 suite: 877 tests, 0 failures
- development app bundle: `make verify CONFIGURATION=debug BUILD_DIR=build/development` 성공
- 생성 shell function: Fast 역할이 `-fast(reasoning)` 형식을 사용하고 `ANTHROPIC_DEFAULT_*_MODEL_NAME`을 포함하지 않음
- Claude Code status-line stdin: `codex-personal/gpt-5.6-terra-fast(xhigh)[1m]`, context window 1,000,000 확인
- `git diff --check`: 통과

## 수동 검증

앱 실행, 스크린샷, 실제 UI 조작과 runtime 설정 확인은 사용자가 직접 수행한다.

확인 권장 항목:

1. 지원되는 Codex 모델에서 역할별 Fast toggle이 활성화된다.
2. 미지원·custom 모델에서는 Fast toggle이 비활성화된다.
3. 저장 후 실행 중 proxy가 restart되고 ready로 복귀한다.
4. 생성 YAML에 OAuth/API Key alias와 `service_tier: priority`가 추가된다.
5. Fast를 모두 끄면 관리 alias와 payload section이 제거된다.
6. shell function의 Fast 역할은 `-fast(reasoning)` 순서를 사용한다.

## 관련 문서

- 설계: `docs/superpowers/specs/2026-07-12-codex-fast-mode-design.md`
- 구현 계획: `docs/superpowers/plans/2026-07-12-codex-fast-mode.md`
- 브랜치: `feature/codex-fast-mode`
- PR: `#61`
