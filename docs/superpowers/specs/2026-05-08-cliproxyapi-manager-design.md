# CLIProxyAPI Manager 설계

## 요약

macOS 전용 SwiftUI 앱을 만들어 CLIProxyAPI를 비개발자도 쉽게 사용할 수 있게 한다. 앱은 CLIProxyAPI를 함께 제공하고, 서버를 백그라운드에서 유지하며, Claude/OpenAI 관련 연결 상태를 관리하고, 사용자가 터미널에서 바로 실행할 수 있는 shell function을 설치한다.

첫 버전은 세 가지 실행 명령을 관리한다.

- `cc`: 사용자의 기존 Claude Code 구독/공식 로그인 상태로 Claude Code 실행
- `ccapi`: macOS Keychain에 저장한 Claude API key로 Claude Code 실행
- `ccodex`: 로컬 CLIProxyAPI를 통해 OpenAI/Codex OAuth로 Claude Code 실행

이 앱은 Claude Code나 CLIProxyAPI를 대체하지 않는다. 설치, 실행, 연결, 진단, shell function 노출을 맡는 관리 앱이다.

## 목표

- 비개발자가 macOS 앱 하나만 설치해 CLIProxyAPI를 사용할 수 있게 한다.
- CLIProxyAPI 서버를 백그라운드에서 안정적으로 유지한다.
- 사용자가 실제로 입력하는 명령인 `cc`, `ccapi`, `ccodex` 중심의 대시보드를 제공한다.
- Claude Code 구독 로그인은 앱이 직접 OAuth를 구현하지 않고 공식 Claude Code CLI 명령으로 연결한다.
- Claude API key는 macOS Keychain에 저장한다.
- OpenAI/Codex OAuth는 CLIProxyAPI를 통해 관리한다.
- 단순 alias가 아니라 shell function을 생성한다.
- provider 환경변수를 전역으로 export하지 않는다.
- 서버, 인증, shell 연동, 모델 목록 실패를 비개발자도 이해할 수 있게 진단한다.

## MVP에서 제외할 것

- Gemini, Kimi, Qwen, Antigravity 등 추가 provider
- Windows/Linux 지원
- 고급 다중 계정 round-robin/failover 설정
- Codex OAuth 모델의 1M context 강제 우회 또는 패치
- Claude Code OAuth 토큰 파일 직접 조작
- Claude Code 공식 로그인 flow 대체

## 플랫폼과 기술

SwiftUI 기반 macOS 네이티브 앱으로 만든다.

이유:

- 첫 버전은 macOS만 지원한다.
- SwiftUI는 비개발자용 앱다운 UX를 만들기 좋다.
- Keychain, Launch at Login, 프로세스 관리, 파일 감시, 알림 같은 macOS 기능을 자연스럽게 사용할 수 있다.
- 웹 대시보드나 메뉴바 유틸보다 “설치해서 쓰는 앱” 경험을 만들기 쉽다.

## 핵심 결정

- CLIProxyAPI는 포크하지 않고 upstream pinned binary로 번들한다.
  - 첫 실행에서 별도 다운로드가 필요 없게 한다.
  - 추후 업데이트 기능으로 새 upstream binary를 내려받을 수 있게 한다.
  - 자체 포크는 upstream으로 해결할 수 없는 명확한 기능 요구가 생길 때만 검토한다.
- 기존 `~/.cli-proxy-api` 설정은 자동으로 가져오지 않는다.
  - 앱이 발견하면 “기존 설정 사용/복사/무시”를 사용자에게 묻는다.
- `cc`에는 `--dangerously-skip-permissions`를 기본으로 넣지 않는다.
  - 앱 설정에서 프로필별로 켤 수 있는 opt-in 옵션으로 제공한다.
- 기본 모델값은 앱 설정에서 수정 가능하게 하되, MVP 기본값은 다음으로 둔다.
  - `ccapi`: `claude-opus-4-7`
  - `ccodex` Opus/Sonnet: `gpt-5.5(xhigh)`
  - `ccodex` Haiku: `gpt-5.5(low)`
- shell 연동은 alias가 아니라 function으로 생성한다.
- `~/.zshrc`에는 source 한 줄만 추가하고, 실제 function은 앱이 관리하는 파일에 둔다.

## 아키텍처

### 1. SwiftUI App

역할:

- 첫 실행 온보딩 UI
- 프로필 중심 대시보드
- 계정/인증 상태 화면
- 서버 제어 화면
- 모델 목록 화면
- 로그/진단 화면
- 명령 이름, 모델, 포트, 권한 옵션 설정

### 2. CLIProxyAPI Service Manager

역할:

- 앱에 포함된 CLIProxyAPI binary 관리
- 앱 관리 디렉터리에 binary와 설정 저장
- CLIProxyAPI 시작/중지
- Launch at Login이 켜져 있으면 백그라운드에서 서버 유지
- `http://127.0.0.1:<port>/v1/models`로 health check
- 포트 충돌 감지
- 버전, PID, 포트, 최근 오류 표시
- 기존 `~/.cli-proxy-api` 발견 시 사용자 선택에 따라 사용 또는 복사

기본 포트는 `8317`이다.

### 3. Claude Code Connector

역할:

- `claude` 설치 여부 확인
- `claude --version`으로 버전 표시
- `claude auth status`로 공식 Claude Code 로그인 상태 확인
- 로그인이 필요하면 터미널을 열어 `claude auth login` 실행
- 사용자가 명시적으로 누른 경우에만 `claude auth logout` 실행

앱은 Claude Code OAuth 토큰을 직접 읽거나 쓰거나 변환하지 않는다.

### 4. Secret Store

역할:

- Claude API key를 macOS Keychain에 저장
- shell function에서 값을 가져올 수 있는 작은 helper 제공
- 원본 API key를 `~/.zshrc`나 `functions.zsh`에 쓰지 않음

### 5. Shell Function Installer

역할:

- `~/.cliproxy-manager/functions.zsh` 생성
- `~/.zshrc`에 아래 한 줄 추가

```sh
source ~/.cliproxy-manager/functions.zsh
```

- 생성 파일에 앱이 관리한다는 표시를 남김
- `~/.zshrc` 수정 전 백업 생성
- reinstall/uninstall 제공
- alias가 아니라 shell function 생성
- 환경변수는 해당 함수 실행에만 적용

예상 생성 형태:

```sh
cc() {
  claude "$@"
}

ccapi() {
  ANTHROPIC_AUTH_TOKEN="$(cliproxy-manager secret get claude-api-key)" \
  ANTHROPIC_MODEL="claude-opus-4-7" \
  claude "$@"
}

ccodex() {
  if ! curl -sf "http://127.0.0.1:8317/v1/models" >/dev/null; then
    echo "CLIProxyAPI Manager가 실행 중이 아닙니다. 앱을 열어 주세요."
    return 1
  fi

  ANTHROPIC_BASE_URL="http://127.0.0.1:8317" \
  ANTHROPIC_AUTH_TOKEN="sk-dummy" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="gpt-5.5(xhigh)" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="gpt-5.5(xhigh)" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="gpt-5.5(low)" \
  claude "$@"
}
```

## 사용자 경험

### 첫 실행 온보딩

1. Claude Code 설치 확인
2. Claude 구독 연결
   - `claude auth status`로 확인
   - 필요하면 `claude auth login` 실행
3. Claude API key 입력 여부 선택
   - 입력 시 Keychain 저장
4. OpenAI/Codex 연결
   - CLIProxyAPI OAuth flow 사용
5. shell functions 설치
6. `cc`, `ccapi`, `ccodex` 준비 상태 테스트

### 평소 대시보드

메인 화면은 프로필 중심이다.

카드:

- `cc`: Claude 구독 프로필
- `ccapi`: Claude API 프로필
- `ccodex`: CLIProxyAPI를 통한 OpenAI/Codex 프로필

각 카드가 보여줄 것:

- 준비됨/문제 있음 상태
- 어떤 backend를 쓰는지
- 테스트 버튼
- 문제 해결 버튼
- 터미널에서 입력할 정확한 명령

보조 패널:

- CLIProxyAPI 서버 상태: 실행/중지, 포트, PID, 버전, Launch at Login 상태
- Codex 계정 상태: 연결됨, 재연결, 모델 목록
- shell 연동 상태: 설치됨/누락, 재설치
- 최근 진단: 마지막 오류, 로그 바로가기, 해결 제안

## 데이터 흐름

### `cc`

```text
Terminal -> cc() -> claude "$@" -> Claude Code 공식 구독 로그인
```

### `ccapi`

```text
Terminal -> ccapi() -> Keychain helper -> scoped ANTHROPIC_AUTH_TOKEN -> claude "$@" -> Claude API
```

### `ccodex`

```text
Terminal -> ccodex() -> local health check -> scoped CLIProxyAPI env -> claude "$@" -> CLIProxyAPI :8317 -> Codex OAuth backend
```

## 오류 처리와 진단

### 서버가 꺼져 있음

- shell function은 앱을 열라는 명확한 메시지를 출력한다.
- 앱은 Start Server와 Enable Launch at Login 액션을 보여준다.

### 포트 충돌

- 앱은 `8317` 포트를 점유한 프로세스를 표시한다.
- 사용자는 관리 포트를 바꾸거나 충돌 프로세스를 직접 종료할 수 있다.
- 앱은 사용자 확인 없이 무관한 프로세스를 종료하지 않는다.

### Claude Code 미설치

- 앱은 설치 안내를 보여준다.
- `claude`가 감지될 때까지 관련 프로필 카드를 비활성화한다.

### Claude 로그인 없음

- 앱은 `claude auth login` 실행을 안내하거나 터미널에서 실행한다.
- 완료 후 `claude auth status`로 확인한다.

### Claude API key 없음

- `ccapi` 카드는 Needs API key 상태를 표시한다.
- 사용자가 입력한 key는 Keychain에 저장한다.

### Codex OAuth 만료 또는 누락

- 앱은 CLIProxyAPI가 지원하는 OAuth flow로 Reconnect 액션을 제공한다.
- 최근 upstream 오류를 쉬운 문장으로 설명한다.

### Shell 연동 누락

- 앱은 `~/.zshrc`가 `~/.cliproxy-manager/functions.zsh`를 source하는지 확인한다.
- 앱은 reinstall과 backup/restore를 제공한다.

## 공개 배포와 라이선스 요구사항

- CLIProxyAPI는 MIT License이므로 번들 배포 시 CLIProxyAPI의 copyright notice와 MIT license 전문을 앱에 포함한다.
- 앱 번들에는 `Resources/Licenses/CLIProxyAPI-LICENSE.txt`를 포함한다.
- About/Licenses 화면에서 CLIProxyAPI 사용과 MIT License를 표시한다.
- README에는 CLIProxyAPI가 별도 오픈소스 프로젝트이며, Claude/OpenAI/Codex/Gemini 등 provider가 이 앱을 공식 보증한다는 식으로 표현하지 않는다.
- OAuth 구독/계정 사용은 각 provider 약관을 따라야 하며, 사용자가 자신의 계정과 책임으로 연결한다는 안내를 포함한다.
- 공개 배포 전에는 CLIProxyAPI binary의 정확한 버전과 license 파일을 함께 고정한다.

## 보안 원칙

- provider 환경변수를 전역 export하지 않는다.
- 원본 API key를 shell profile 파일에 쓰지 않는다.
- Claude Code OAuth 토큰 파일을 직접 조작하지 않는다.
- shell 시작 파일을 수정하기 전 명시적으로 확인을 받는다.
- 수정 전 backup을 만든다.
- 민감한 값은 항상 redacted 형태로 보여준다.

## 테스트 전략

수동 테스트:

- CLIProxyAPI가 설치되지 않은 새 macOS 사용자
- 기존 CLIProxyAPI가 `8317`에서 실행 중인 사용자
- 기존 `~/.cli-proxy-api` auth 파일이 있는 사용자
- Claude Code CLI가 없는 상태
- Claude Code가 로그아웃된 상태
- Claude API key가 없는 상태
- Codex OAuth가 만료된 상태
- `8317` 포트 충돌 상태
- shell function 설치, 재설치, 제거
- `cc`, `ccapi`, `ccodex`가 Claude Code에 인자를 정상 전달하는지

자동 테스트:

- shell function 생성 snapshot
- `.zshrc` source line 삽입/제거
- 포트 충돌 감지 parsing
- Keychain wrapper의 mocked secret store 동작
- mocked HTTP 응답 기반 CLIProxyAPI health state 전환

## MVP 범위

포함:

- SwiftUI 앱 shell
- macOS용 managed CLIProxyAPI service
- Launch at Login
- 프로필 중심 대시보드
- Claude Code 공식 login/status connector
- Claude API Keychain 저장
- CLIProxyAPI를 통한 OpenAI/Codex OAuth
- `cc`, `ccapi`, `ccodex` shell function 생성
- 서버 상태, 모델 목록, 로그, 진단

제외:

- Claude/OpenAI/Codex 외 provider
- 1M context 강제 활성화
- 고급 load balancing
- 크로스플랫폼 지원
- Claude OAuth 직접 구현
