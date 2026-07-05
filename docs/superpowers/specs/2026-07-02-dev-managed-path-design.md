# 개발 빌드용 관리 경로 분리 설계

## 배경

CLIProxyManager의 CLIProxyAPI 바이너리 업데이트 기능은 현재 `ManagedPaths.defaultRootDirectory()`가 반환하는 `~/.cliproxy-manager` 아래에 active 바이너리, manifest, update state를 저장한다. 이 경로는 프로덕션 앱도 사용하는 실제 사용자 데이터 경로다.

개발 빌드에서 CLIProxyAPI 업데이트를 테스트하면 다음 파일들이 프로덕션 경로에 남을 수 있다.

- `~/.cliproxy-manager/cliproxyapi/active-manifest.json`
- `~/.cliproxy-manager/cliproxyapi/update-state.json`
- `~/.cliproxy-manager/cliproxyapi/pending/`

현재 배포된 이전 프로덕션 앱은 새 메타파일을 직접 사용하지 않지만, 같은 `cliproxyapi` 실행 파일 경로를 사용한다. 따라서 개발 빌드와 이전 프로덕션 앱을 번갈아 실행하면 stale manifest나 업데이트 테스트 상태가 섞일 수 있다.

## 목표

1. 프로덕션 앱의 기존 사용자 데이터와 실행 경로는 그대로 유지한다.
2. 개발 빌드는 프로덕션 경로와 분리된 관리 root를 사용한다.
3. 개발 빌드에서 CLIProxyAPI 업데이트 테스트를 반복해도 프로덕션 경로를 오염시키지 않는다.
4. 이미 프로덕션 경로에 생긴 업데이트 테스트 메타파일은 실제 설정과 바이너리를 보존한 채 안전하게 정리한다.

## 비목표

- 프로덕션 앱의 root 경로를 변경하지 않는다.
- 기존 `config.yaml`, 인증 정보, shell function, 실제 `cliproxyapi` 실행 파일을 삭제하지 않는다.
- 환경변수 override나 번들 위치 기반 자동 판별은 이번 변경에 포함하지 않는다.
- CLIProxyAPI 업데이트 UX 자체를 재설계하지 않는다.

## 선택한 접근

`ManagedPaths.defaultRootDirectory()`를 단일 진입점으로 유지하고, Swift 컴파일 조건에 따라 기본 root를 나눈다.

- DEBUG 빌드: `~/.cliproxy-manager/dev`
- non-DEBUG 빌드: `~/.cliproxy-manager`

대부분의 앱 서비스가 이미 `ManagedPaths()` 기본값을 사용하므로, 이 변경만으로 개발 빌드의 `AppConfigStore`, `AuthProfileStore`, `ShellProfileInstaller`, `ProxyServiceManager`, `CLIProxyAPIUpdateService`가 모두 개발 전용 root를 사용한다.

## 컴포넌트 영향

### `ManagedPaths`

- `defaultRootDirectory()`에 컴파일 조건 분기를 추가한다.
- `rootDirectory`를 명시적으로 주입하는 테스트와 서비스는 기존처럼 주입된 값을 그대로 사용한다.
- 경로 계산 프로퍼티(`clipProxyDirectory`, `clipProxyBinary`, `activeClipProxyManifest`, `clipProxyUpdateStateFile` 등)는 변경하지 않는다.

### 앱 런타임

DEBUG 개발 빌드는 다음 경로를 사용한다.

```text
~/.cliproxy-manager/dev/config.json
~/.cliproxy-manager/dev/functions.zsh
~/.cliproxy-manager/dev/auth/
~/.cliproxy-manager/dev/cliproxyapi/config.yaml
~/.cliproxy-manager/dev/cliproxyapi/cliproxyapi
~/.cliproxy-manager/dev/cliproxyapi/active-manifest.json
~/.cliproxy-manager/dev/cliproxyapi/update-state.json
~/.cliproxy-manager/dev/cliproxyapi/pending/
```

프로덕션과 release 빌드는 기존 경로를 유지한다.

```text
~/.cliproxy-manager/config.json
~/.cliproxy-manager/functions.zsh
~/.cliproxy-manager/auth/
~/.cliproxy-manager/cliproxyapi/config.yaml
~/.cliproxy-manager/cliproxyapi/cliproxyapi
```

## 프로덕션 경로 정리

정리 대상은 개발 테스트 중 생긴 CLIProxyAPI 업데이트 메타 상태로 제한한다.

삭제 대상:

```text
~/.cliproxy-manager/cliproxyapi/active-manifest.json
~/.cliproxy-manager/cliproxyapi/update-state.json
~/.cliproxy-manager/cliproxyapi/pending/
```

보존 대상:

```text
~/.cliproxy-manager/cliproxyapi/cliproxyapi
~/.cliproxy-manager/cliproxyapi/config.yaml
~/.cliproxy-manager/config.json
~/.cliproxy-manager/auth/
~/.cliproxy-manager/functions.zsh
```

정리 전에는 실제 파일 목록을 확인한다. 대상 외 파일이 섞여 있으면 삭제 범위를 넓히지 않는다.

## 오류 처리

- DEBUG 경로 생성은 기존 prepare/save 흐름의 `createDirectory` 호출에 맡긴다.
- 프로덕션 메타파일 삭제 중 일부 파일이 없으면 성공으로 간주한다.
- 삭제 권한이나 파일 시스템 오류가 발생하면 오류를 사용자에게 보고하고 임의로 추가 삭제를 시도하지 않는다.

## 테스트 전략

1. `ManagedPaths.defaultRootDirectory()`의 DEBUG 기본값이 `~/.cliproxy-manager/dev`인지 확인하는 테스트를 추가한다.
2. 명시적 root 주입(`ManagedPaths(rootDirectory:)`)은 기존처럼 그대로 동작하는지 확인한다.
3. CLIProxyAPI binary store와 update service의 기존 테스트가 주입된 sandbox root를 계속 사용하므로 깨지지 않는지 확인한다.
4. 필요하면 개발 빌드를 실행해 현재 버전/업데이트 상태가 dev 경로 기준으로 새로 잡히는지 확인한다.

## 성공 기준

- DEBUG 빌드에서 앱이 `~/.cliproxy-manager/dev` 아래에 CLIProxyAPI active binary와 update state를 만든다.
- release/prod 빌드의 기본 root는 `~/.cliproxy-manager`로 남는다.
- 프로덕션 경로의 `cliproxyapi` 실행 파일과 `config.yaml`은 삭제되지 않는다.
- 로컬 프로덕션 경로의 업데이트 메타파일만 정리된다.
- 관련 Swift 테스트가 통과한다.
