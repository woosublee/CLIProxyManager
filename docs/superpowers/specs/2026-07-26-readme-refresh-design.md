# README v0.1.27 최신화 설계

**작성일:** 2026-07-26
**상태:** 설계 승인

## 문제

국문 `README.md`와 영문 `README.en.md`는 현재 앱의 기본 설치·사용 흐름을 설명하지만 v0.1.27의 주요 사용자 기능을 충분히 보여 주지 않는다. 상단 이미지의 Usage HUD는 OAuth 구독 사용량만 표시하는 이전 화면이며 compact HUD 이미지가 없다.

문서에는 API Key 예상 비용, 혼합 Usage HUD, 계정 순서 변경과 HUD 표시 선택, round-robin command, 확장된 `cpm` 업데이트·quota 기능, 앱과 CLIProxyAPI의 독립적인 업데이트 흐름이 부분적으로 누락돼 있다.

## 목표

- 기존 README의 간결한 프로젝트 소개 구조를 유지하면서 v0.1.27 주요 사용자 기능을 국·영문에 동일하게 반영한다.
- 상단 이미지를 메인 대시보드, expanded Usage HUD, compact Usage HUD 순서로 구성한다.
- OAuth 구독 사용률과 API Key token·request·예상 비용이 함께 표시되는 현재 Usage HUD를 설명한다.
- 계정 관리, 모델 라우팅, round-robin, CLI, 업데이트 기능을 changelog가 아닌 사용자 관점에서 정리한다.
- 국문과 영문의 기능 범위, 명령 예시, 링크를 일치시킨다.

## 비목표

- 모든 설정 필드와 내부 구현을 나열하는 전체 사용 설명서를 만들지 않는다.
- release history나 commit별 변경 사항을 README에 추가하지 않는다.
- 기존 메인 대시보드 이미지를 교체하거나 편집하지 않는다.
- 사용자 제공 Usage HUD 이미지를 crop, rescale 또는 보정하지 않는다.
- 앱 코드, 설정 schema, release workflow를 변경하지 않는다.

## 이미지 구성

상단 `<table>`을 한 행의 세 이미지로 구성한다.

```text
[메인 대시보드] [Expanded Usage HUD] [Compact Usage HUD]
```

### 첫 번째 이미지

- 기존 `docs/assets/readme-main-window.png` 유지
- 다중 OAuth 계정과 command를 보여 주는 메인 대시보드

### 두 번째 이미지

- 사용자 제공 `스크린샷 2026-07-26 오후 8.55.22.png`
- `docs/assets/readme-usage-hud.png`를 해당 원본으로 교체
- expanded HUD에서 OAuth 구독 사용률과 Claude/OpenAI API Key의 Day/Mon token·request·예상 비용을 함께 보여 줌

### 세 번째 이미지

- 사용자 제공 `스크린샷 2026-07-26 오후 8.55.34.png`
- `docs/assets/readme-usage-hud-compact.png`로 추가
- compact HUD에서 같은 계정 집합의 사용률·예상 비용을 세로로 보여 줌

원본 PNG의 pixel dimensions를 유지한다. README에서는 첫 번째와 두 번째 이미지를 동일한 일반 폭으로, 세 번째 이미지를 실제 비율에 맞는 좁은 폭으로 표시한다. 국문과 영문은 같은 파일과 순서를 사용하고 alt text만 각 언어로 작성한다.

## 문서 구조

기존 섹션 순서를 최대한 보존한다.

1. 언어 전환 링크와 세 이미지
2. 소개
3. 주요 기능 / Highlights
4. 요구 사항 / Requirements
5. 설치 및 macOS 보안 경고
6. 시작하기 / Quick start
7. 새 계정과 라우팅 / Accounts and routing
8. Usage HUD
9. 터미널과 SSH / Terminal and SSH
10. 업데이트 / Updates
11. 문제 해결 / Troubleshooting
12. 보안 / Security
13. 라이선스 / License

## 기능 설명 범위

### 소개와 주요 기능

다음 사용자 기능을 짧은 bullet로 설명한다.

- Claude/Codex OAuth와 Claude/OpenAI API Key 통합 관리
- 계정별 command·nickname·활성화 상태·순서·상세정보 privacy 관리
- Claude direct/CLIProxyAPI 연결 선택
- Codex와 OpenAI API Key의 역할별 GPT model·reasoning·감지된 context window·Fast mode 설정
- 선택 계정을 새 CLI session마다 순환하는 round-robin command
- 메뉴바, expanded HUD, compact HUD의 구독 사용률과 API 예상 비용
- `cpm`의 proxy/app 제어, logs, quota, update 관리

### 시작하기

기존 4단계 흐름을 유지한다.

1. OAuth subscription 또는 API Key 추가
2. nickname과 command 설정
3. shell reload
4. 생성된 command 실행

모델 설정 설명은 계정과 라우팅 섹션으로 이동해 Quick start를 짧게 유지한다.

### 계정과 라우팅

새 섹션에서 다음을 설명한다.

- 계정 drag reorder와 move fallback
- 계정 활성화/비활성화, account detail privacy, HUD 포함 여부
- Claude OAuth의 Direct 또는 CLIProxyAPI 연결
- Codex/OpenAI의 역할별 model, reasoning, detected context window, Fast mode
- 최소 2개 선택 계정을 새 session마다 순환하는 round-robin command와 session 내 계정 고정

### Usage HUD

기존 설정·표시 설명을 유지하면서 현재 데이터 유형을 구분한다.

- OAuth account: API가 보고한 `5h`, `7d`, `1mo` 사용률과 reset 시각
- API Key account: local CLIProxyAPI usage record를 집계한 Day/Mon token, request, 예상 비용
- expanded/compact 전환, 계정 선택 공유, 재실행 후 보기 상태 유지
- API 비용은 price catalog와 수집된 usage 기준의 estimate라는 점을 명시

### Terminal과 SSH

기존 명령에 누락된 사용자-facing command를 추가한다.

```zsh
cpm app restart
cpm update check [app | proxy | all]
cpm update stage [app | proxy | all]
cpm update apply [app | proxy | all] [--yes]
cpm quota key status --json
cpm quota key set --stdin
cpm quota key delete
```

`cpm routing next`는 round-robin generated command의 내부 선택 경로이므로 기본 command 목록에는 노출하지 않는다.

### 업데이트

- Sparkle 기반 앱 업데이트
- CLIProxyAPI 바이너리 업데이트의 독립성
- 앱 시작 시 bundled CLIProxyAPI와 설치본 비교 및 적용 전 동의
- `cpm update`에서 app/proxy/all 대상을 구분할 수 있음을 설명

## 언어 일관성

국문과 영문은 직역보다 자연스러운 표현을 사용하되 다음 계약을 유지한다.

- 동일한 섹션 순서
- 동일한 이미지 순서
- 동일한 기능 범위
- 동일한 shell command와 link
- `OAuth`, `API Key`, `Usage HUD`, `Fast mode`, `round-robin`, `CLIProxyAPI`, `cpm` 같은 제품 용어 유지

## 검증

1. 새 이미지가 PNG이며 dimensions가 expanded `692×1014`, compact `308×1274`인지 확인한다.
2. 기존 메인 이미지는 변경되지 않았는지 확인한다.
3. 국·영문 README의 `<img>` 순서와 파일 경로가 일치하는지 검사한다.
4. 국·영문에 계정·라우팅, 혼합 Usage HUD, CLI, 업데이트 기능이 모두 있는지 확인한다.
5. README에 등장하는 `cpm` 명령이 실제 CLI usage와 일치하는지 대조한다.
6. 내부 상대 링크와 fenced code block이 올바르게 닫혔는지 확인한다.
7. `git diff --check`를 실행한다.

문서와 PNG 자산만 변경하며 앱 테스트와 runtime build는 수행하지 않는다.
