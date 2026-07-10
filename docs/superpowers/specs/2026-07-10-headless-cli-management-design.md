# SSH용 Headless CLI 관리 설계

## 요약

`CLIProxyManager`를 SSH로 접속한 동일한 macOS 사용자 계정에서 GUI를 열지 않고 운영할 수 있도록, 기존 보조 명령을 공식 `cpm` 관리 CLI로 확장한다. `cpm`은 로컬 CLIProxyAPI 프록시의 상태 확인·시작·중지·재시작·로그 조회, GUI 앱 프로세스 제어, CLIProxyAPI 바이너리 업데이트, CLIProxyManager 앱 및 외부 helper 업데이트를 제공한다.

핵심 원칙은 GUI와 CLI가 별도 daemon이나 IPC 없이 동일한 `CLIProxyManagerCore` 서비스·관리 경로·`launchctl` 사용자 영역을 사용하게 하는 것이다. GUI는 선택적인 설정 UI로 남고, 프록시 운영과 업데이트는 GUI 실행 여부에 의존하지 않는다.

## 목표

- SSH 세션에서 GUI 앱을 실행하지 않고 프록시를 시작, 중지, 재시작하고 상태를 확인할 수 있다.
- SSH 세션에서 실제 프록시 로그를 조회하고 follow할 수 있다.
- SSH 세션에서 CLIProxyAPI 바이너리의 업데이트를 확인, 다운로드·검증·적용할 수 있다.
- SSH 세션에서 CLIProxyManager 앱, 공식 `cpm` helper, 호환 helper를 함께 업데이트할 수 있다.
- 다운로드와 검증만 수행하는 안전한 staged 업데이트와, 명시적으로 요청하는 즉시 적용을 모두 지원한다.
- 앱과 프록시의 시작·중지 명령은 분리한다. GUI 앱이 없거나 GUI 세션이 없는 경우에도 프록시 제어와 업데이트는 계속 동작한다.
- 기존 생성 shell function과 기존 `cliproxy-manager secret`/`routing next` 사용자는 앱 업데이트 뒤에도 깨지지 않는다.

## 비목표

- 원격 네트워크에서 다른 컴퓨터의 CLIProxyManager를 관리하는 control plane, daemon, HTTP 관리 API 또는 IPC를 도입하지 않는다.
- SSH 계정과 앱을 설치·운영한 macOS 계정이 다른 경우 계정 간 관리 파일·Keychain·`launchctl` 영역을 넘나들어 제어하지 않는다.
- `sudo cpm`으로 root의 홈 디렉터리나 root `launchctl` 영역을 제어하게 하지 않는다.
- 앱 업데이트용으로 Sparkle의 GUI 흐름을 대체하거나 자동으로 모든 업데이트를 적용하지 않는다. GUI의 Sparkle 업데이트 UI는 유지한다.
- 사용자가 임의의 feed URL, 업데이트 채널 또는 설치 경로를 지정하게 하지 않는다.
- 업데이트를 성공적으로 완료한 뒤 사용자가 수동으로 이전 버전을 선택해 되돌리는 rollback 명령은 제공하지 않는다. 실패 중 자동 복구만 제공한다.
- 현재 앱 설정에 있는 bind address 동작을 변경하거나 원격에서 프록시 포트에 직접 연결하는 기능을 추가하지 않는다.

## 현재 제약과 근거

- 현재 `cliproxy-manager`는 `secret <get|set|delete> claude-api-key`와 `routing next <round-robin-profile-id>`만 제공한다.
- `ProxyServiceManager`는 이미 `launchctl` 기반 프록시 start/stop/restart, 설정 작성, 관리 대상 orphan process 정리를 제공한다. 명령 간 메모리 상태를 공유하지 않아도 포트와 생성된 config를 이용해 기존 관리 프로세스를 정리할 수 있다.
- CLIProxyAPI의 release 조회, checksum 검증, archive 검증, pending 저장, active 교체와 실패 시 복원은 Core에 존재한다. 현재 네트워크 orchestration만 App target의 `CLIProxyAPIUpdateService`에 있다.
- 앱 업데이트는 Sparkle GUI controller가 담당한다. Sparkle의 표준 `SPUStandardUpdaterController`는 GUI user driver를 전제로 하므로 headless CLI의 업데이트 경로로 사용하지 않는다.
- 현 release appcast는 GitHub Releases의 HTTPS feed와 enclosure의 Sparkle EdDSA signature를 사용한다. CLI는 public key를 고정하여 appcast enclosure와 다운로드 artifact를 독자적으로 검증해야 한다.
- 앱과 helper는 Makefile install 과정에서 `/Applications/CLIProxyManager.app` 및 `/usr/local/bin/cliproxy-manager`에 함께 설치된다. app update에 helper update가 자동 포함되지 않는 것이 현재 한계다.

## 사용자 경험과 명령 계약

공식 명령은 `cpm`이다. 도움말과 README는 `cpm`만 일반 사용자 명령으로 문서화한다.

```sh
# 통합 상태
cpm status [--json]

# 기본 대상: CLIProxyAPI 프록시
cpm start
cpm stop
cpm restart
cpm logs [-f] [--lines <count>]

# 선택 대상: GUI 앱
cpm app status
cpm app start
cpm app stop
cpm app restart

# 업데이트 대상: app, proxy, all (기본값 all)
cpm update check [app|proxy|all] [--json]
cpm update stage [app|proxy|all]
cpm update apply [app|proxy|all] [--yes]

# 기존 shell function 호환 명령
cpm secret <get|set|delete> claude-api-key
cpm routing next <round-robin-profile-id>
```

### 공통 규칙

- 인자가 없는 `cpm update check`, `stage`, `apply`의 대상은 `all`이다.
- `check`는 네트워크로 최신 release를 조회하지만 파일과 실행 중 프로세스를 변경하지 않는다.
- `stage`는 새 버전이 있는 대상을 다운로드·검증하고 staged 상태로 저장한다. 실행 중인 앱과 프록시는 변경하지 않는다.
- `apply`는 이미 검증된 staged 대상만 적용한다. staged 대상이 없으면 실패하며 먼저 `stage`를 실행하라고 안내한다.
- `apply`는 TTY에서 대상, 현재 버전, staged 버전을 보여 주고 확인을 요구한다. `--yes`는 이 확인만 생략하며 검증·권한 사전 점검·복구를 생략하지 않는다.
- 읽기 전용 명령은 성공 여부와 상관없이 비밀값, OAuth profile 내용, API key, auth file 경로 내용을 출력하지 않는다.
- 사람이 읽기 쉬운 기본 출력과 자동화용 `--json`을 지원한다. JSON은 stdout에만 출력하고 진단과 오류는 stderr에 출력한다.
- 성공·이미 최신·업데이트 없음은 exit code `0`, 실행 실패는 `1`, 잘못된 명령/인수는 `2`, 설치 경로나 권한 등 충족되지 않은 선행 조건은 `3`을 반환한다.

### 프록시 명령

- `cpm start`는 `config.json`의 포트를 읽고 `ProxyServiceManager.start(port:)`를 호출한다. GUI 앱은 시작하지 않는다.
- `cpm stop`은 앱이 이전에 시작한 프로세스를 포함해, 관리 바이너리와 관리 config를 사용하는 해당 포트의 프록시만 중지한다. 다른 프로그램이 같은 포트를 사용 중이면 중지하지 않는다.
- `cpm restart`는 관리 프록시를 중지한 뒤 같은 config로 다시 시작한다.
- `cpm status`는 앱 설치 상태, 현재 helper의 동기화 상태, 구성 포트, 프록시 readiness, active/pending CLIProxyAPI 버전, app/proxy staged 업데이트, GUI 앱 실행 상태를 하나의 요약으로 제공한다.
- `cpm logs`는 기본적으로 현재 proxy의 `main.log` 마지막 200줄을 출력한다. `--lines`는 양의 정수여야 하고, `-f`는 `tail -F`와 동등하게 같은 파일을 follow한다. `main.log`가 없으면 가장 최근 수정된 `.log` 하나를 선택하며, 로그 파일이 전혀 없으면 프록시가 아직 로그를 만들지 않았다는 오류를 출력한다.

### GUI 앱 명령

- `cpm app status`는 표준 설치 경로의 bundle 존재 여부와 `CLIProxyManager` process 실행 여부를 별도로 표시한다.
- `cpm app start`는 `/Applications/CLIProxyManager.app`을 LaunchServices로 연다. 현재 사용자에게 Aqua GUI 세션이 없거나 `open`이 실패하면 앱 시작만 실패한다. 이 실패가 프록시 상태를 바꾸지 않는다.
- `cpm app stop`은 GUI 앱에 정상 종료를 먼저 요청하고, 제한 시간 내 종료하지 않으면 사용자에게 상태를 보고한다. 프록시를 중지하기 위한 명령은 아니며, 프록시 lifecycle은 `cpm stop`으로 명시적으로 제어한다.
- `cpm app restart`는 stop 성공 뒤 start를 수행한다. GUI 세션 부재로 start할 수 없으면 stop이 성공했더라도 non-zero로 종료하고 두 결과를 모두 보고한다.

### 업데이트 대상

- `proxy`는 사용자 관리 경로 아래의 CLIProxyAPI 실행 파일만 의미한다.
- `app`은 `/Applications/CLIProxyManager.app`, `/usr/local/bin/cpm`, `/usr/local/bin/cliproxy-manager`를 하나의 원자적 업데이트 단위로 의미한다.
- `all`은 app과 proxy의 모든 staged 업데이트를 적용한다. 한 대상의 staged update가 없어도 다른 대상의 staged update는 적용한다. 어떤 staged update도 없으면 실패한다.
- `cpm update check`의 기본 출력은 app과 proxy 각각의 현재 버전·available 버전·pending/staged 상태를 구분해 보여 준다.

## 설치, 이름 변경 및 호환성

### 공식 helper 이름

새 release는 bundle의 `Contents/Helpers/cpm`과 외부 `/usr/local/bin/cpm`을 공식 helper로 설치한다. `AutomaticShellInstallService`와 새로 생성되는 `functions.zsh`는 `cpm`을 호출한다.

### 이전 이름 지원

기존 shell function 및 사용자의 직접 호출이 깨지지 않도록, 같은 release에는 `Contents/Helpers/cliproxy-manager`와 `/usr/local/bin/cliproxy-manager`를 호환 launcher로 함께 설치한다. 두 실행 파일은 같은 command dispatcher를 실행하며 기존 `secret`과 `routing` 문법을 보장한다. 새 기능 문서와 `cpm --help`의 기본 명령 목록에는 이전 이름을 노출하지 않는다.

기존 버전에서 새 버전으로 처음 전환하는 사용자는 새 release를 한 번 수동 설치해야 한다. 구버전 helper에는 `cpm`과 update 명령이 없으므로 이 bootstrap 단계 자체를 구버전 CLI로 자동화하지 않는다.

### bundle 및 proxy resource 탐색

CLI가 `/usr/local/bin/cpm`에서 실행돼도 app resource를 찾을 수 있어야 한다.

1. 실행 파일이 `CLIProxyManager.app/Contents/Helpers` 내부에 있으면 그 bundle을 사용한다.
2. 그렇지 않으면 표준 설치 경로 `/Applications/CLIProxyManager.app`을 사용한다.
3. bundle identifier와 필요한 `Contents/Resources/cliproxyapi` binary·manifest, `Contents/Helpers/cpm`의 존재를 검증한다.
4. active managed proxy binary가 이미 있으면 bundle resource 없이도 stop, status, logs는 동작한다. fresh start나 bundled baseline 복구에 resource가 필요할 때만 설치 오류를 반환한다.

## 컴포넌트 설계

### Command dispatcher와 출력

`CLIProxyManagerCommand`는 인수 파싱만 담당하고, 구체적 filesystem·network·process 동작은 아래 Core service protocol에 위임한다. 명령이 커져도 하나의 giant switch가 되지 않도록 각 command group을 독립 handler로 둔다.

- `StatusReporting`: app/proxy/helper/update 상태를 조합한다.
- `ProxyControlling`: proxy start/stop/restart/readiness를 제공한다.
- `ProxyLogStreaming`: 실제 proxy log를 찾고 조회·follow한다.
- `AppLifecycleControlling`: app bundle 상태 및 start/stop/restart를 제공한다.
- `ProxyUpdating`: proxy release check/stage/apply을 제공한다.
- `AppUpdating`: appcast check/stage/apply을 제공한다.
- `CommandOutput`: text/JSON serialization과 confirmation 입력을 담당한다.

각 service는 실제 구현과 test double을 교체할 수 있는 protocol 경계로 만든다. command handler는 명령어 검증과 결과의 exit code 결정만 하며 `Process`, network session, Finder, Sparkle 타입을 직접 다루지 않는다.

### Proxy runtime facade

새 `ProxyRuntimeService`는 `AppConfigStore`, `ProxyServiceManager`, `ProxyHealthClient`, `CLIProxyAPIBinaryStore`, `ManagedPaths`, bundle locator를 조합한다.

- proxy control은 기존 `ProxyServiceManager`를 그대로 재사용한다.
- CLI가 app target의 `BundledProxyBinary`에 의존하지 않도록 bundle resource locator를 Core로 옮긴다.
- status는 config 포트, managed config/binary의 존재, active/pending manifest와 health client 결과를 읽는다.
- start/restart 전에는 기존처럼 config 작성과 active binary 검증을 수행한다.

### 실제 로그 경로 정정

현재 `ManagedPaths.logsDirectory`는 `<root>/logs`를 가리키고 Advanced Settings의 Reveal은 그 디렉터리를 생성한다. 그러나 proxy config는 다음 설정만 제공한다.

```yaml
auth-dir: "<ManagedPaths.authDirectory>"
logging-to-file: true
debug: false
```

실제 CLIProxyAPI 런타임 로그는 `<ManagedPaths.authDirectory>/logs`에 생성된다.

- release: `~/.cliproxy-manager/auth/logs/`
- DEBUG: `~/.cliproxy-manager/dev/auth/logs/`

현재 관측되는 이름은 `main.log`, timestamp가 붙은 `main-*.log`, `error-*.log`이지만 이름 규칙은 upstream proxy가 정하며 이 프로젝트가 보장하지 않는다. Core에 `proxyLogsDirectory`를 추가하고, `cpm logs`와 Advanced Settings의 Reveal 모두 그 경로를 사용하게 수정한다. 앱이 별도 app log를 쓰지 않으므로 기존 `<root>/logs`를 새로 만들지 않는다.

### CLIProxyAPI update service

현재 App target에 있는 `CLIProxyAPIUpdateService`의 UI 상태와 24시간 자동 확인 정책을 CLI로 가져오지 않는다. 대신 Core의 재사용 가능한 `ProxyUpdateService`를 만든다.

1. `CLIProxyAPIReleaseClient`로 upstream latest stable release와 `checksums.txt` entry를 가져온다.
2. active manifest의 버전과 비교하여 update 여부를 계산한다.
3. stage에서 archive를 다운로드하고 `CLIProxyAPIArchiveVerifier`로 upstream checksum, archive 추출, binary `--version` metadata를 검증한다.
4. 검증된 binary와 manifest는 기존 `CLIProxyAPIBinaryStore.savePending`으로 저장한다.
5. apply에서 `CLIProxyAPIBinaryStore.applyPending`을 호출한다.
6. apply 전 프록시가 healthy/running이었다면 새 binary 적용 뒤 재시작하고 readiness를 다시 검사한다. 이전에 멈춰 있었다면 시작하지 않는다.
7. apply 또는 restart 실패 시 binary store의 기존 atomic backup/복구 경로를 사용하고, proxy restart 실패는 명확히 별도 오류로 보고한다.

GUI `CLIProxyAPIUpdateService`는 새 Core service를 호출하는 UI adapter로 축소해 다운로드·검증·pending policy가 두 군데로 갈라지지 않게 한다. GUI의 24시간 자동 check 및 사용자 prompt UX는 유지한다.

### Headless app update service

`AppUpdateService`는 Sparkle controller를 사용하지 않는 Core service다. Sparkle은 GUI 앱의 standard update UI를 계속 담당한다. Headless service는 Sparkle release feed와 동일한 artifact를 다음과 같이 검증한다.

1. 고정된 HTTPS appcast URL과 커밋된 Sparkle Ed25519 public key를 사용한다. 사용자 입력 URL이나 redirect 후의 비-HTTPS URL을 허용하지 않는다.
2. appcast에서 현재 설치 build보다 높은 stable enclosure 하나를 파싱한다. 필요한 값은 app build, display version, enclosure URL, byte length, `sparkle:edSignature`다.
3. enclosure URL을 다운로드한 뒤 appcast의 length와 일치하는지 확인한다.
4. Sparkle release pipeline의 `sign_update`와 호환되는 Ed25519 verification으로 raw DMG의 signature를 검증한다. 구현 시 release pipeline이 생성한 실제 fixture를 사용해 `CryptoKit.Curve25519.Signing` 검증 결과를 테스트한다. 호환성 검증이 실패하면 서명을 생략하지 않고 Sparkle의 검증 구현을 사용한다.
5. 검증한 DMG를 read-only, no-browse 방식으로 mount한다. root의 정확한 app 이름, `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString`, app code signature, bundle 내부 `cpm`과 compatibility helper를 검증한다.
6. 검증을 통과한 app bundle과 두 helper를 `<root>/updates/app/<build>/`에 stage한다. manifest에는 source URL, versions, archive digest, signature/length 검증 결과, staged timestamp만 기록한다. secret이나 OAuth data는 넣지 않는다.

이중 검증은 네트워크 release의 EdDSA 진위와 stage된 bundle의 코드 구조를 각각 보장한다.

### App update apply와 자동 복구

`cpm update apply app`은 다음 순서로 수행한다.

1. staged app manifest, staged app bundle, 두 staged helper의 무결성과 버전을 다시 확인한다.
2. `/Applications/CLIProxyManager.app`, `/usr/local/bin/cpm`, `/usr/local/bin/cliproxy-manager` 각각에 대한 write 권한을 적용 전 모두 확인한다. 부족하면 파일을 바꾸지 않고 stage를 유지하며, `sudo cpm`을 권하지 않는다. 사용자가 해당 사용자 권한으로 설치 경로 권한을 정정해야 한다.
3. app running 여부와 proxy running 여부를 기록한다. 실행 중인 GUI 앱에는 정상 종료를 요청하고 종료를 기다린다. 종료할 수 없으면 교체하지 않는다.
4. app bundle과 두 helper를 같은 filesystem 내 temporary path에 준비한다. 기존 대상을 `.previous`로 rename하고 새 대상을 rename하는 순서로 교체한다.
5. 어느 교체 단계라도 실패하면 이미 교체한 대상들을 `.previous`로 되돌린다. 이 복구가 성공/실패했는지도 stderr에 출력한다.
6. 모든 대상 교체가 완료되면 temporary/previous artifacts를 정리하고 staged app update를 완료 처리한다.
7. 업데이트 전 GUI 앱이 실행 중이었으면 재실행을 시도한다. Aqua session 부재로 재실행할 수 없어도 app/helper 교체 자체가 성공했다면 update는 성공으로 처리하고, GUI 재시작 결과를 경고로 별도 표시한다.
8. 업데이트 전 프록시가 실행 중이었고 GUI 종료로 인해 중단된 경우에만 `ProxyRuntimeService`로 프록시를 복구하고 health를 확인한다. app update는 proxy의 기존 active CLIProxyAPI 버전을 임의로 낮추지 않는다.

성공한 app update를 사용자가 뒤늦게 되돌리는 기능은 제공하지 않는다. `.previous`는 apply 중 실패한 경우의 자동 복구에만 사용하며 성공 후 삭제한다.

## 상태 모델과 저장 경로

기존 경로는 그대로 유지한다.

```text
~/.cliproxy-manager/
├── config.json
├── auth/
│   └── logs/                    # 실제 proxy log directory
├── cliproxyapi/
│   ├── cliproxyapi
│   ├── active-manifest.json
│   ├── pending/
│   └── update-state.json
└── updates/
    └── app/<build>/             # 새 headless app update stage
        ├── CLIProxyManager.app
        ├── cpm
        ├── cliproxy-manager
        └── manifest.json
```

DEBUG build는 기존 `ManagedPaths` 규칙에 따라 `~/.cliproxy-manager/dev/`를 사용한다. app staging과 proxy pending state는 서로 독립적이다. 한 대상의 staged update가 다른 대상 update를 덮어쓰지 않는다.

`cpm status --json`은 최소한 다음 안정 필드를 제공한다.

```json
{
  "app": {
    "installed": true,
    "path": "/Applications/CLIProxyManager.app",
    "version": "0.1.12",
    "build": "15",
    "running": false,
    "stagedVersion": null
  },
  "helper": {
    "path": "/usr/local/bin/cpm",
    "installed": true,
    "matchesBundled": true
  },
  "proxy": {
    "port": 8317,
    "running": true,
    "activeVersion": "7.2.41",
    "pendingVersion": null,
    "stagedVersion": null,
    "logsPath": "/Users/example/.cliproxy-manager/auth/logs"
  }
}
```

실제 user home 경로나 port는 로컬 상태에 따라 달라진다. JSON output에는 auth profile 목록, API key, log content를 포함하지 않는다.

## 오류 처리

- 모든 파일 변경은 같은 directory/filesystem 안에서 temporary file 또는 directory를 만든 뒤 rename하는 방식으로 수행한다.
- stage 중 download, checksum, archive, signature, mount, app bundle, code signature, version 검증에 실패하면 existing app, helper, active proxy binary를 건드리지 않는다.
- `cpm update apply`의 권한 사전 점검은 전체 대상에 대해 교체 전 끝낸다. 대상 일부만 바꾸고 권한 오류를 내지 않는다.
- app bundle을 찾지 못한 `cpm app` 또는 app update 명령은 canonical app path와 재설치 방법을 알려 준다. proxy의 status/stop/logs는 계속 수행할 수 있다.
- `cpm start`가 실행 가능한 active/bundled binary를 찾지 못하면 proxy binary가 누락됐다는 사실과 app install 필요 여부를 알려 준다.
- GUI app start 실패는 CLI proxy 상태를 변경하지 않는다. GUI restart의 stop/start 결과는 함께 출력한다.
- `cpm logs`는 file path가 auth directory 밖으로 escape하지 않도록 regular file만 선택하고 symlink를 follow하지 않는다.
- `--json` 명령의 오류는 JSON이 아닌 stderr 진단과 정해진 exit code로 전달한다. partial success의 상세 결과는 text mode와 JSON success object에 명시한다.

## 보안 고려 사항

- 업데이트 feed, appcast enclosure, GitHub release redirect의 최종 URL은 HTTPS여야 한다.
- CLIProxyAPI는 upstream `checksums.txt`와 extracted binary metadata를 모두 검증한다.
- app update DMG는 pinned Sparkle public key의 Ed25519 signature, expected length, mounted bundle identifier/version, `codesign --verify --deep --strict`를 모두 통과해야 한다.
- `cpm`은 Keychain secret을 `secret get`에서만 출력하고 status/update/log output에는 포함하지 않는다.
- `cpm`은 현재 사용자 홈과 user `launchctl` domain만 다룬다. root로 실행되었거나 SSH 사용자와 bundle owner가 맞지 않는 상황은 actionable error로 중단한다.
- app update apply는 권한 승격이나 AppleScript administrator prompt를 호출하지 않는다. SSH에서 보이지 않는 GUI credential prompt를 만들지 않기 위해서다.

## 테스트 전략

### Core unit tests

- command parser가 `start`, `stop`, `restart`, `logs`, `app`, `update` 문법과 대상 기본값 `all`을 정확히 해석한다.
- unknown command, 잘못된 update target, 비양수 `--lines`, `--yes` 위치 오류가 exit code `2`와 usage를 반환한다.
- command handler가 injected service를 올바른 순서로 호출하고 `apply`의 interactive confirmation과 `--yes`를 구분한다.
- text 및 JSON status가 version, running, staged 값을 일관되게 표시하고 secret/auth data를 포함하지 않는다.
- proxy lifecycle facade가 config port와 managed bundle resource를 사용하고, 기존 `ProxyServiceManager` orphan-cleanup regression test를 유지한다.
- log locator가 `auth/logs`만 선택하고 `main.log`, 최신 regular `.log`, 없는 로그 case, symlink 거부를 검증한다.
- proxy update service가 available/current/pending version 비교, archive verifier 성공·실패, apply 후 running proxy restart, stopped proxy 미시작을 검증한다.
- appcast parser가 malformed XML, missing field, non-HTTPS URL, invalid version, non-increasing build, invalid signature/length을 거부한다.
- Sparkle `sign_update`가 생성한 fixture DMG signature가 CLI verifier에서 통과하고, 한 byte 변조 시 실패한다.
- app stage가 mounted bundle identifier/version/helper 존재/code-signature 검증 실패 시 destination을 만들지 않는다.
- app apply가 write preflight 실패 시 아무 대상도 교체하지 않고, app/helper rename 중 실패하면 prior app과 두 helper 모두 자동 복구한다.
- GUI session 부재에서 app start/relaunch 실패가 proxy lifecycle 및 successful file update 결과와 분리되어 보고된다.
- compatibility launcher가 기존 `secret`과 `routing next` command behavior를 유지한다.

### App target regression tests

- `AutomaticShellInstallService`가 새로 생성한 function script에 `/usr/local/bin/cpm` 또는 bundle 내 `cpm`을 사용한다.
- Advanced Settings Diagnostics Reveal이 `proxyLogsDirectory`를 연다.
- GUI CLIProxyAPI updater가 새 Core update service adapter를 이용해 기존 available/pending/apply UI state를 유지한다.
- Sparkle `UpdaterService`와 기존 About update UI는 계속 컴파일·동작한다.

### Packaging and documentation tests

- Makefile bundle/verify target이 `Contents/Helpers/cpm`과 compatibility `Contents/Helpers/cliproxy-manager`를 모두 포함하고 code-sign verification한다.
- install target이 두 external helper를 원자적으로 설치하고 실패 시 둘 다 이전 상태로 복구한다.
- release DMG verification이 두 helper와 app bundle을 확인한다.
- README의 공식 command, update workflow, actual log path, GUI 비필수 동작, bootstrap requirement가 구현과 일치한다.

### 수동 개발 빌드 검증

개발 빌드 기준으로 다음을 검증한다.

1. 앱을 열지 않은 SSH-equivalent terminal에서 `cpm status`, `start`, `logs`, `restart`, `stop`을 실행한다.
2. GUI session이 있는 경우와 없는 경우에 `cpm app start/stop/restart` 결과를 확인한다.
3. local fixture release를 사용해 app/proxy check, stage, confirmation apply, `--yes` apply를 검증한다.
4. proxy가 실행 중/중지 상태 각각에서 proxy update apply 뒤의 running state 보존과 health 결과를 확인한다.
5. app/helper swap 중 의도적으로 실패를 주입해 자동 복구가 prior app과 두 helper를 모두 복원하는지 확인한다.
6. old generated shell function이 compatibility helper로 `secret`과 `routing next`를 계속 호출할 수 있는지 확인한 뒤, 새 shell function은 `cpm`을 사용하는지 확인한다.

## 수용 기준

- GUI가 실행되지 않은 상태에서 같은 macOS 사용자 계정의 SSH shell로 프록시 start/stop/restart/status/logs를 수행할 수 있다.
- `cpm start`는 GUI 앱을 시작하지 않고, `cpm app start`는 proxy를 시작하지 않는다.
- `cpm status`는 app, helper, proxy, active/pending/staged update 상태를 한 번에 표시하고 `--json`을 지원한다.
- `cpm logs`와 Advanced Settings Reveal은 실제 `auth/logs` proxy log directory를 사용한다.
- `cpm update check|stage|apply`는 app/proxy/all 대상과 safe staged flow를 지원한다.
- proxy update는 upstream checksum과 archive metadata 검증을 유지하고, app update는 pinned Ed25519 signature·length·mounted bundle·code signature 검증을 통과해야만 stage/apply한다.
- app update apply는 app bundle, `cpm`, legacy `cliproxy-manager`를 모두 교체하거나 실패 시 모두 복구한다.
- GUI session이 없어도 proxy control, proxy update, app/helper stage/apply는 GUI 실행과 독립적으로 동작한다.
- 새 공식 command는 `cpm`이며 이전 `cliproxy-manager secret`과 `routing next`는 계속 동작한다.
- 앱 업데이트, helper 업데이트, proxy binary update 중 어느 것도 API key나 OAuth profile 내용을 stdout/stderr/log에 노출하지 않는다.
