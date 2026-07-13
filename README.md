# CLIProxyManager

[English](README.en.md)

<table>
  <tr>
    <td><img src="docs/assets/readme-main-window.png" alt="CLIProxyManager 다중 계정 대시보드" width="300"></td>
    <td><img src="docs/assets/readme-usage-hud.png" alt="Claude와 Codex 계정 한도를 보여 주는 구독 사용량 HUD" width="300"></td>
  </tr>
</table>

CLIProxyManager는 여러 Claude·Codex OAuth 계정과 로컬 CLIProxyAPI 서버를 macOS 메뉴바에서 관리하는 앱입니다. 계정마다 별도 명령어를 만들고, 어떤 계정으로 Claude Code를 실행할지 쉽게 전환할 수 있습니다.

## 주요 기능

- Claude OAuth와 Codex OAuth 계정을 여러 개 연결하고 관리
- Claude와 OpenAI API Key를 추가하고 API Key별 명령어·별칭·모델 매핑·권한 설정 관리
- 모든 API Key 명령은 OAuth 구독 로그인과 분리된 로컬 CLIProxyAPI 경로로 실행
- 계정별 명령어·별칭·모델 설정
- 로컬 CLIProxyAPI 서버 시작·중지·상태·로그 확인
- 메뉴바와 별도 HUD에서 구독 사용량 확인
- **cpm Command Line Tool**로 터미널이나 SSH 환경에서도 프록시·앱·사용량 관리

## 요구 사항

- macOS 15 이상
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치
- Claude 또는 Codex/OpenAI OAuth 계정
- 터미널 명령어를 사용할 경우 zsh

## 설치 및 macOS 보안 경고

배포본은 자체 서명되어 있지만 Apple 공증을 받지 않았습니다. 따라서 처음 실행할 때 macOS 보안 경고가 나타날 수 있습니다.

1. [Releases](https://github.com/woosublee/CLIProxyManager/releases/latest)에서 최신 DMG를 내려받아 앱을 설치합니다.
2. 경고가 나타나면 Finder에서 앱을 Control-클릭한 뒤 **열기**를 선택하거나, **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다.

GitHub Releases에서 직접 내려받은 배포본만 사용하세요.

## 시작하기

1. 앱에서 **Add Provider**를 눌러 Claude/Codex의 OAuth subscription 또는 API Key를 추가합니다.
2. 계정별 Settings에서 원하는 명령어를 지정합니다. 예: `claude-work`, `codex-personal`
3. 새 터미널을 열거나 다음 명령을 실행합니다.

   ```zsh
   source ~/.zshrc
   ```

4. 지정한 명령어로 실행합니다.

   ```zsh
   claude-work
   codex-personal
   ```

## 사용량 HUD

**Server Settings → Subscription Usage**를 켠 뒤, **General → Usage Overlay**에서 별도 사용량 창을 표시할 수 있습니다.

- 창의 투명도와 항상 위 표시 여부를 설정할 수 있습니다.
- 메뉴바에서 HUD를 다시 표시하거나 숨길 수 있습니다.
- Claude와 Codex 계정별 사용량·초기화 시각을 보여 줍니다.
- Codex는 API가 보고한 실제 기간을 표시합니다. 일반 계정은 `5h`·`7d`, Team 플랜의 월간 윈도우는 `1mo`로 표시됩니다.
- HUD 우측 상단의 축소·확장 버튼으로 300pt 폭의 전체 보기와 108pt 폭의 compact 보기를 전환할 수 있습니다.
- compact 보기는 계정 avatar·이름과 기간별 사용률을 세로로 표시합니다. loading·unavailable·disabled·stale 상태에서는 `—`와 상태 indicator를 표시하며, 선택한 보기 상태는 앱 재실행 후에도 유지됩니다.

## 터미널과 SSH에서 사용하기

**cpm Command Line Tool**은 터미널과 SSH에서 CLIProxyManager를 제어하는 `cpm` 명령어입니다. 앱의 **Settings → General → Command Line**에서 **Install cpm Command Line Tool**을 선택해 설치할 수 있습니다. 설치된 버전이 최신이면 Update 버튼은 보이지 않고, 앱에 새 버전이 포함된 경우에만 Update 버튼이 나타납니다.

```zsh
# 상태와 프록시 제어
cpm status
cpm start
cpm stop
cpm restart
cpm logs -f

# 앱 제어
cpm app status
cpm app start
cpm app stop

# 계정별 구독 사용량
cpm quota
cpm quota --json
```

## 업데이트

CLIProxyManager는 앱을 실행 중일 때 새 버전을 확인합니다. 업데이트가 있으면 앱의 안내에 따라 설치하면 됩니다.

터미널에서는 다음 명령어도 사용할 수 있습니다.

```zsh
cpm update check
cpm update stage
cpm update apply
```

CLIProxyAPI 바이너리 업데이트는 앱 업데이트와 별개입니다. 앱의 안내 또는 `cpm update check proxy`로 확인할 수 있습니다.

## 문제 해결

### 터미널에서 명령어를 찾을 수 없음

새 터미널을 열거나 다음을 실행합니다.

```zsh
source ~/.zshrc
```

계정 Settings에서 지정한 명령어가 비어 있지 않은지도 확인하세요.

### 로컬 서버에 연결할 수 없음

앱에서 서버 상태를 확인하고, 필요하면 서버를 중지한 뒤 다시 시작하세요. 계속 문제가 있으면 **Advanced** 설정에서 로그를 확인합니다.

### 앱이 처음 실행되지 않음

설치 및 macOS 보안 경고 섹션의 안내에 따라 Finder에서 **열기**를 선택하거나 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택하세요.

## 보안

앱은 OAuth 프로필과 설정을 `~/.cliproxy-manager` 아래에서 관리합니다. API Key는 `~/.cliproxy-manager/api-keys/`의 평문 파일에 저장합니다. 앱은 디렉터리에 `0700`, 각 key 파일에 `0600` 권한을 적용하지만 macOS 계정에 접근할 수 있는 사용자는 값을 읽을 수 있습니다. 이 디렉터리를 복사·공유하거나 저장소에 커밋하지 마세요.

## 라이선스

CLIProxyManager는 [MIT License](LICENSE)를 따릅니다. 앱은 MIT License의 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)를 포함하거나 관리합니다.
