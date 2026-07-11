# cpm 설치와 사용량 출력 정리

**작성일:** 2026-07-11  
**상태:** 사용자 검토 대기

## 목표

- 앱 Settings에서 사용자가 원할 때만 `cpm`을 설치·갱신·삭제한다.
- 공식 전역 CLI는 `/usr/local/bin/cpm` 하나로 한다.
- `cpm quota` 기본 출력을 내부 profile 파일명 대신 앱에서 사용하는 닉네임과 command name으로 읽기 쉽게 표시한다.

## 범위 밖

- `cliproxy-manager` 설치·갱신·삭제·UI 노출
- 앱 시작·Sparkle 업데이트 후 자동 CLI 설치 또는 권한 요청
- shell function 동작 변경
- 메뉴바 구독 사용량 UI 변경
- `cpm quota --json` 형식 변경
- 별도 daemon, 장기 실행 helper, 광범위한 privileged service 추가

## Settings: cpm 설치

`GeneralSettingsView`에 **Command Line** 행을 하나 추가한다.

| 상태 | 버튼 |
| --- | --- |
| `/usr/local/bin/cpm` 없음 | `Install cpm` |
| 앱이 설치한 `cpm`이 현재 번들과 일치 | `Update cpm`, `Remove cpm…` |
| 앱이 설치한 이전 `cpm` | `Update cpm`, `Remove cpm…` |
| 앱이 설치하지 않은 파일 | 버튼 없음, 수동 해결 안내 |

- `Install cpm`, `Update cpm`, `Remove cpm…`을 누를 때만 macOS 관리자 인증을 요청한다.
- 설치/갱신은 현재 앱 번들의 `Contents/Helpers/cpm`만 `/usr/local/bin/cpm`으로 복사한다.
- 삭제는 `/usr/local/bin/cpm`만 제거한다.
- `Remove cpm…`은 확인 dialog를 먼저 표시한다.
- 작업 중에는 세 버튼을 비활성화한다.
- 설치·갱신·삭제 성공 후 상태를 다시 읽어 화면을 갱신한다.

### 최소 안전장치

설치 성공 시 앱 설정에 설치한 `cpm`의 SHA-256 digest를 기록한다.

- 업데이트/삭제 전 실제 `/usr/local/bin/cpm`의 digest가 기록값과 일치하는지 확인한다.
- 일치할 때만 앱이 설치한 파일로 간주한다.
- 기록이 없거나 digest가 다르면 다른 도구가 관리하는 파일로 보고 덮어쓰거나 삭제하지 않는다.
- 설치 과정은 임시 파일에 복사한 뒤 대상 이름으로 교체한다. 실패하면 기존 파일은 유지한다.

이 기능은 명시적으로 클릭한 경우에만 시스템 인증을 요청하는 고정된 설치·삭제 작업만 수행한다. 임의 경로, 임의 명령, 사용자 입력 shell command는 허용하지 않는다.

## `cpm quota` 기본 출력

`cpm quota`의 JSON 출력은 바꾸지 않는다. 기본 텍스트 출력만 다음 규칙으로 변경한다.

- 제목은 nickname이 있으면 nickname, 없으면 `Claude OAuth` 또는 `Codex OAuth`다.
- 제목 오른쪽에 앱 메뉴바와 같은 `$ <command name>`을 표시한다.
- 내부 `profileID` 파일명과 이메일은 출력하지 않는다.
- Claude의 `5h`·`7d`는 그대로 표시한다.
- Codex의 API label `Primary`는 `5h`, `Secondary`는 `7d`로 표시한다.
- 각 기간은 10칸 텍스트 진행률 bar, 사용률, reset 시각을 별도 줄에 표시한다.
- 사용량 상태가 unavailable/loading/disabled인 경우 현재 앱의 안전한 상태 문구를 그대로 사용한다.

예시:

```text
Claude OAuth  $ cc
  5h   ░░░░░░░░░░   0%
  7d   ░░░░░░░░░░   1%
       Next reset: 7월 18일 오전 3:00

Codex OAuth  $ cdx
  5h   ██░░░░░░░░  15%
       Next reset: 7월 12일 오전 1:09
  7d   █░░░░░░░░░   9%
       Next reset: 7월 18일 오후 3:02
```

메뉴바는 현재처럼 기간 label을 별도로 표시하지 않는다. 변경 대상은 `cpm quota`의 텍스트 출력뿐이다.

## 변경 위치

- `GeneralSettingsView`: Command Line 설치 행
- `DashboardViewModel`: 설치 상태, Install/Update/Remove action, 오류 메시지
- 작은 `CPMInstaller` service: digest 기록, 고정된 설치·삭제 작업
- `CLIProxyManagerCommand`: `quota` 텍스트 formatter
- 관련 unit test와 개발 빌드 runtime 검증

## 테스트와 수용 기준

- `cpm` 미설치 상태에서 Install 버튼으로 `/usr/local/bin/cpm`을 설치할 수 있다.
- 설치 후 `cpm --help`, `cpm status`, `cpm quota`가 새 터미널/SSH에서 실행된다.
- 앱 번들이 바뀐 뒤 Update 버튼으로만 전역 `cpm`을 갱신할 수 있다.
- Remove 버튼은 앱이 설치하고 digest가 일치하는 `cpm`만 삭제한다.
- 다른 파일이 `/usr/local/bin/cpm`에 있으면 덮어쓰거나 삭제하지 않는다.
- `cliproxy-manager`, menu bar, shell functions, `cpm quota --json`은 변경하지 않는다.
- `cpm quota` 기본 출력은 nickname fallback, `$ command`, 5h/7d, 사용률, reset 시각을 표시하고 profile 파일명을 출력하지 않는다.
