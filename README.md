# CLIProxyManager

[English](README.en.md)

<table>
  <tr>
    <td><img src="docs/assets/readme-main-window.png" alt="CLIProxyManager 다중 계정 대시보드" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud.png" alt="OAuth 구독 사용률과 API Key 예상 비용을 함께 보여 주는 expanded Usage HUD" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud-compact.png" alt="계정별 사용률과 API 예상 비용을 세로로 보여 주는 compact Usage HUD" width="100"></td>
  </tr>
</table>

CLIProxyManager는 여러 Claude·Codex OAuth 구독, Claude·OpenAI API Key, 로컬 CLIProxyAPI 서버를 macOS 메뉴바에서 관리하는 앱입니다. 계정마다 전용 명령어를 만들고 모델 라우팅과 round-robin을 설정하며, 구독 사용률과 API 예상 비용을 하나의 Usage HUD에서 확인할 수 있습니다.

## 주요 기능

- Claude·Codex OAuth 계정과 provider별 복수 Claude·OpenAI API Key profile을 한곳에서 추가하고 관리
- OAuth 계정과 API Key profile별 명령어·별칭·순서·Usage HUD 표시 여부와 인증 방식별 설정 관리
- Claude OAuth의 Direct/CLIProxyAPI 연결 선택과 계정별 Claude model mapping
- Codex OAuth와 OpenAI API Key의 Opus·Sonnet·Haiku 역할별 GPT model, reasoning, 감지된 context window, Fast mode 설정
- 선택한 OAuth 계정을 새 CLI session마다 순환하고 session 안에서는 계정을 고정하는 round-robin 명령어
- 로컬 CLIProxyAPI 서버 시작·중지·상태·로그 확인
- 메뉴바, expanded HUD, compact HUD에서 OAuth 구독 사용률과 API Key token·request·예상 비용 확인
- **cpm Command Line Tool**로 터미널이나 SSH에서 proxy·앱·quota·업데이트 관리

## 요구 사항

- macOS 15 이상
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치
- Claude/Codex OAuth 계정 또는 Claude/OpenAI API Key
- 생성된 터미널 명령어를 사용할 경우 zsh

## 설치 및 macOS 보안 경고

배포본은 자체 서명되어 있지만 Apple 공증을 받지 않았습니다. 따라서 처음 실행할 때 macOS 보안 경고가 나타날 수 있습니다.

1. [Releases](https://github.com/woosublee/CLIProxyManager/releases/latest)에서 최신 DMG를 내려받아 앱을 설치합니다.
2. 경고가 나타나면 Finder에서 앱을 Control-클릭한 뒤 **열기**를 선택하거나, **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다.

GitHub Releases에서 직접 내려받은 배포본만 사용하세요.

## 시작하기

1. 앱에서 **Add Provider**를 눌러 Claude/Codex OAuth subscription 또는 Claude/OpenAI API Key profile을 추가합니다. 같은 provider의 API Key profile도 여러 개 등록할 수 있습니다.
2. 계정 또는 API Key profile별 Settings에서 nickname과 전용 명령어를 지정합니다. 예: `claude-work`, `codex-personal`
3. 새 터미널을 열거나 다음 명령을 실행합니다.

   ```zsh
   source ~/.zshrc
   ```

4. 지정한 명령어로 실행합니다.

   ```zsh
   claude-work
   codex-personal
   ```

## 계정과 라우팅

- 메인 화면에서 drag handle이나 더보기 메뉴를 사용해 계정 순서를 바꿀 수 있습니다. 같은 순서가 메뉴바와 Usage HUD에도 적용됩니다.
- OAuth 계정은 비활성화했다가 다시 활성화할 수 있고, 계정 상세정보를 흐리거나 Usage HUD 표시 대상에서 제외할 수 있습니다.
- Claude OAuth는 **Direct** 또는 **CLIProxyAPI** 연결을 선택할 수 있습니다. Direct는 Claude Code의 현재 model policy를 사용하고, CLIProxyAPI 연결은 계정별 model mapping을 사용합니다.
- 각 Claude·OpenAI API Key profile은 독립적인 명령어, nickname, model routing, permission 설정과 고유 proxy prefix를 사용합니다.
- Codex OAuth와 각 OpenAI API Key profile은 Opus·Sonnet·Haiku 역할마다 GPT model과 reasoning을 선택할 수 있습니다. 지원 모델에서는 Fast mode를 켤 수 있으며, 감지된 context window는 Claude Code auto-compaction에 반영됩니다.
- **Settings → General → Routing**에서 provider별 round-robin 명령어를 만들 수 있습니다. 최소 2개 계정을 선택하면 새 CLI session마다 다음 계정으로 순환하고, 선택된 계정은 해당 session 동안 고정됩니다.

## 사용량 HUD

**Settings → Usage**에서 메뉴바 사용량과 별도 Usage HUD 표시를 각각 설정할 수 있습니다.

- 창의 투명도와 항상 위 표시 여부를 설정하고, 메뉴바에서 HUD를 다시 표시하거나 숨길 수 있습니다.
- 메인 화면의 각 계정 카드에서 Usage HUD 버튼을 눌러 HUD에 표시할 계정을 선택할 수 있습니다. 선택은 expanded·compact 보기에 함께 적용되고 앱 재실행 후에도 유지됩니다.
- OAuth 계정은 API가 보고한 `5h`, `7d`, `1mo` 기간의 사용률과 reset 시각을 표시합니다.
- 각 Claude·OpenAI API Key profile은 고유 routing prefix로 로컬 CLIProxyAPI usage record를 분리 집계해 Day/Mon token, request, 예상 비용을 표시합니다. 비용은 수집된 usage와 앱의 price catalog를 바탕으로 한 추정치이며 provider 청구서가 아닙니다.
- HUD 우측 상단의 축소·확장 버튼으로 300pt 폭의 expanded 보기와 108pt 폭의 compact 보기를 전환할 수 있습니다.
- compact 보기는 account avatar·이름과 기간별 사용률 또는 Day/Mon 예상 비용을 세로로 표시합니다. loading·unavailable·disabled·stale 상태에서는 `—`와 상태 indicator를 표시합니다.
- 선택한 HUD mode와 account 목록은 앱 재실행 후에도 유지됩니다.

## 터미널과 SSH에서 사용하기

**cpm Command Line Tool**은 터미널과 SSH에서 CLIProxyManager를 제어하는 `cpm` 명령어입니다. 앱의 **Settings → General → Command Line**에서 **Install cpm Command Line Tool**을 선택해 설치할 수 있습니다. 앱에 더 최신 버전이 포함된 경우에만 Update 버튼이 나타납니다.

```zsh
# 상태와 proxy 제어
cpm status [--json]
cpm start
cpm stop
cpm restart
cpm logs --lines 100
cpm logs -f

# 앱 제어
cpm app status
cpm app start
cpm app stop
cpm app restart

# OAuth 구독 사용량과 quota access key
cpm quota
cpm quota --json
cpm quota key status --json
printf '%s\n' "$MANAGEMENT_KEY" | cpm quota key set --stdin
cpm quota key delete

# 앱·CLIProxyAPI 업데이트
cpm update check [app | proxy | all]
cpm update stage [app | proxy | all]
cpm update apply [app | proxy | all] [--yes]
```

## 업데이트

CLIProxyManager는 실행 중 새 앱 버전을 확인하고 Sparkle 안내를 통해 업데이트합니다.

앱 업데이트와 CLIProxyAPI 바이너리 업데이트는 서로 독립적입니다. 앱 시작 시 bundled CLIProxyAPI가 설치본보다 새 버전인지 확인하며, 실행 중인 server에 영향을 주는 적용은 사용자 동의를 받은 뒤 진행합니다.

터미널에서는 대상을 `app`, `proxy`, `all` 중에서 선택할 수 있습니다.

```zsh
cpm update check all
cpm update stage all
cpm update apply all --yes
```

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

앱은 OAuth 프로필과 설정을 `~/.cliproxy-manager` 아래에서 관리합니다. 현재 릴리스는 각 API Key profile의 실제 key를 `~/.cliproxy-manager/api-keys/`의 별도 평문 파일에 저장하며, macOS Keychain으로 전환하는 설정은 제공하지 않습니다. Key는 `config.json`과 generated shell function에 포함되지 않습니다. 앱은 디렉터리에 `0700`, 각 key와 lock 파일에 `0600` 권한을 적용하지만 macOS 계정에 접근할 수 있는 사용자는 값을 읽을 수 있습니다. 이 디렉터리를 복사·공유하거나 저장소에 커밋하지 마세요.

## 라이선스

CLIProxyManager는 [MIT License](LICENSE)를 따릅니다. 앱은 MIT License의 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)를 포함하거나 관리합니다.
