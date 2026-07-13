# Codex 역할별 Fast mode 개발 현황

## 현재 상태

Codex의 Opus·Sonnet·Haiku 역할별 Fast mode 구현과 자동 검증을 완료했다.

## 완료된 작업

- `CodexRole.fastModeEnabled` 저장 및 기존 JSON 하위 호환 decode
- 앱 관리 Fast alias `-cpm-fast`와 reasoning suffix 조합
- Codex model metadata의 Fast capability 조회
- fallback allowlist 및 관리 alias 필터링
- OAuth, OpenAI API Key, round-robin, legacy 설정 화면의 역할별 Fast toggle
- 미지원 모델의 Fast 값 저장 전 정규화
- OAuth/API Key alias와 `service_tier: priority` payload YAML 생성
- Fast 미사용 시 기존 YAML의 바이트 단위 호환성 유지
- legacy, OAuth, API Key, round-robin shell routing 테스트
- Fast 설정 변경 시 proxy restart 및 API Key 변경과의 coalescing
- restart 중 추가 변경의 generation별 drain
- model-server 준비 및 모델 조회와 configuration restart 직렬화
- 필수 내부 restart와 수동 lifecycle action의 충돌 방지
- restart/readiness 실패의 diagnostic 및 Fast 전용 메시지 처리
- invalid legacy Fast alias 복구와 reasoning/context-only 저장 호환성
- 한국어·영어 README 문서화

## 자동 검증

최종 구현 기준:

- `DashboardViewModelRefreshTests`: 140 tests, 0 failures
- 전체 `swift test`: 762 tests, 0 failures
- development build: `swift build -c debug` 성공
- `git diff --check`: 통과

## 수동 검증

앱 실행, 스크린샷, 실제 UI 조작과 runtime 설정 확인은 사용자가 직접 수행한다.

확인 권장 항목:

1. 지원되는 Codex 모델에서 역할별 Fast toggle이 활성화된다.
2. 미지원·custom 모델에서는 Fast toggle이 비활성화된다.
3. 저장 후 실행 중 proxy가 한 번 restart되고 ready로 복귀한다.
4. 생성 YAML에 OAuth/API Key alias와 `service_tier: priority`가 추가된다.
5. Fast를 모두 끄면 관리 alias와 payload section이 제거된다.
6. shell function의 Fast 역할은 `-cpm-fast(reasoning)` 순서를 사용한다.

## 관련 문서

- 설계: `docs/superpowers/specs/2026-07-12-codex-fast-mode-design.md`
- 구현 계획: `docs/superpowers/plans/2026-07-12-codex-fast-mode.md`
- 브랜치: `feature/codex-fast-mode`
- Draft PR: `#61`
