# CLIProxyAPI 바이너리 자체 업데이트 설계

## 요약

CLIProxyManager 앱 릴리스와 CLIProxyAPI 번들 바이너리 갱신을 분리한다. 앱은 `router-for-me/CLIProxyAPI`의 GitHub Releases를 직접 확인하고, 새 macOS arm64 CLIProxyAPI 릴리스가 있으면 사용자에게 업데이트 여부를 묻는다. 사용자가 승인한 경우에만 archive를 다운로드하고 상류 `checksums.txt`로 검증한 뒤 앱 관리 경로에 저장한다.

업데이트 적용은 사용자가 선택한다. 즉시 적용을 선택하면 검증된 바이너리를 active 바이너리로 승격하고 실행 중인 앱 관리 서버를 재시작한다. 다음 실행에 적용을 선택하면 검증된 바이너리를 pending 상태로 보관하고, 다음 서버 시작 또는 재시작의 prepare 단계에서 active로 승격한다.

## 목표

- CLIProxyManager 앱 자체를 새로 배포하지 않고 CLIProxyAPI 바이너리만 앱 안에서 업데이트할 수 있게 한다.
- 앱 실행 시 CLIProxyAPI 업데이트 가능 여부를 백그라운드로 확인하고, 앱이 계속 실행 중이면 이후 24시간마다 다시 확인한다.
- 사용자가 수동으로 즉시 업데이트 확인을 실행할 수 있게 한다.
- 새 버전이 있으면 사용자에게 업데이트 여부를 묻고, 승인한 경우에만 다운로드와 검증을 진행한다.
- 사용자가 업데이트 적용 방식을 “지금 적용 후 재시작” 또는 “다음 실행에 적용” 중 선택할 수 있게 한다.
- checksum 불일치, asset 누락, 압축 해제 실패, metadata 불일치가 있으면 기존 active 바이너리를 유지한다.
- user-updated 바이너리가 앱 번들 바이너리보다 최신이면 `ProxyServiceManager.prepare()`가 다시 번들 바이너리로 되돌리지 않게 한다.
- 기존 Sparkle 앱 업데이트 흐름은 그대로 유지한다.

## 비목표

- CLIProxyManager 앱 자체 업데이트를 변경하지 않는다.
- 별도 CLIProxyManager 관리 feed 또는 CDN을 운영하지 않는다.
- CLIProxyAPI prerelease, beta, nightly 채널을 지원하지 않는다.
- 사용자의 명시적 승인 없이 CLIProxyAPI 바이너리를 자동 교체하지 않는다.
- 실행 중 서버를 사용자 승인 없이 자동 재시작하지 않는다.
- Intel macOS 바이너리나 Linux/Windows 바이너리를 관리하지 않는다.
- `/usr/local/bin/cliproxy-manager` helper 설치 상태를 이 기능에서 수정하지 않는다.

## 현재 프로젝트 맥락

현재 앱은 `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`를 앱 리소스로 번들한다. 번들 metadata는 `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`에 있다. `scripts/vendor-cliproxyapi.sh`는 개발자가 앱 번들 기본 바이너리를 갱신할 때 사용하는 canonical vendoring 경로다.

런타임에서는 `BundledProxyBinary.serviceManager()`가 번들 바이너리 URL을 `ProxyServiceManager`에 주입한다. `ProxyServiceManager.prepare()`는 현재 `installBundledBinaryIfNeeded()`를 통해 `~/.cliproxy-manager/cliproxyapi/cliproxyapi`가 없거나 번들 바이너리와 다르면 번들 바이너리로 복사/교체한다. 이 동작은 앱 안에서 받은 최신 바이너리를 다음 prepare 때 번들 버전으로 되돌릴 수 있으므로, active/pending manifest와 버전 우선순위가 필요하다.

앱 자체 자동 업데이트는 Sparkle 2 기반 `UpdaterService`와 `About > Updates` UI가 담당한다. CLIProxyAPI 바이너리 업데이트는 Sparkle과 별개 기능으로 설계한다.

## 사용자 플로우

### 자동 확인

앱 실행 직후 `CLIProxyAPIUpdateService`가 백그라운드로 업데이트 확인을 시작한다. 마지막 자동 확인 시각이 24시간 이내이면 확인하지 않는다. 앱이 계속 실행 중인 경우에도 24시간마다 한 번만 자동 확인한다.

자동 확인에서 새 버전이 없으면 사용자를 방해하지 않는다. 새 버전이 있으면 앱 내부 confirmation dialog 또는 그에 준하는 비침투적 UI로 알린다.

예시 문구:

```text
CLIProxyAPI 7.2.42 버전을 사용할 수 있습니다.
현재 버전: 7.2.41
업데이트하시겠습니까?
```

선택지는 `Update`와 `Later`다. 사용자가 `Later`를 선택한 버전은 `update-state.json`에 기록해 같은 자동 확인 주기에서 반복적으로 묻지 않는다. 수동 확인은 이 억제를 무시하고 다시 보여줄 수 있다.

### 수동 확인

Settings의 CLIProxyAPI binary row에서 `Check now`를 누르면 24시간 제한 없이 즉시 확인한다.

- 최신이면 `CLIProxyAPI is up to date.`를 표시한다.
- 실패하면 사람이 이해할 수 있는 오류 메시지를 표시한다.
- 새 버전이 있으면 자동 확인과 같은 업데이트 확인 UI를 띄운다.

### 업데이트 다운로드와 적용 방식 선택

사용자가 `Update`를 선택하면 앱은 먼저 다운로드와 검증을 완료하고, 검증된 바이너리를 pending 상태로 저장한다. 검증 성공 후 적용 방식을 다시 묻는다.

선택지는 다음과 같다.

1. `Apply now and restart server`
   - 검증된 pending 바이너리를 즉시 active 바이너리로 승격한다.
   - 앱 관리 서버가 실행 중이면 기존 `DashboardViewModel.restartServer()` 흐름으로 재시작한다.
   - 서버가 꺼져 있으면 바이너리만 교체하고 완료한다.
   - 서버가 꺼져 있을 때는 UI 문구를 `Apply now`로 줄일 수 있지만, 동작은 같은 즉시 active 승격이다.

2. `Apply on next server start`
   - 검증된 바이너리를 pending 상태로 보관한다.
   - 현재 실행 중인 서버는 건드리지 않는다.
   - 다음 `start`, `restart`, 또는 autostart prepare 단계에서 active로 승격한다.

## 저장 경로와 metadata

기존 active 실행 파일 경로는 유지한다.

```text
~/.cliproxy-manager/cliproxyapi/cliproxyapi
```

새 파일과 디렉터리는 `ManagedPaths`에서 노출한다.

```text
~/.cliproxy-manager/cliproxyapi/active-manifest.json
~/.cliproxy-manager/cliproxyapi/pending/
~/.cliproxy-manager/cliproxyapi/pending/cliproxyapi
~/.cliproxy-manager/cliproxyapi/pending/manifest.json
~/.cliproxy-manager/cliproxyapi/update-state.json
```

### active manifest

`active-manifest.json`은 현재 실행 파일의 출처와 검증 정보를 기록한다.

필드 예시:

```json
{
  "name": "cliproxyapi",
  "version": "7.2.42",
  "commit": "abcdef12",
  "builtAt": "2026-07-01T00:00:00Z",
  "sourceKind": "user-updated",
  "source": "https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.42/CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
  "upstreamRepository": "router-for-me/CLIProxyAPI",
  "upstreamTag": "v7.2.42",
  "upstreamAsset": "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
  "upstreamAssetSha256": "...",
  "vendoredBinaryName": "cliproxyapi",
  "vendoredBinarySha256": "...",
  "vendoredBinarySizeBytes": 41030450,
  "vendoredFromArchivePath": "cli-proxy-api",
  "downloadedAt": "2026-07-01T00:05:00Z",
  "appliedAt": "2026-07-01T00:06:00Z"
}
```

`sourceKind`는 최소한 `bundled`와 `user-updated`를 지원한다.

### pending manifest

`pending/manifest.json`은 active manifest와 같은 schema를 사용하되, `appliedAt`은 아직 없거나 null이다. pending manifest와 pending binary는 둘 다 존재하고 checksum/size가 일치할 때만 유효하다.

### update state

`update-state.json`은 업데이트 확인 UX와 스케줄링 상태만 기록한다.

필드 예시:

```json
{
  "lastCheckedAt": "2026-07-01T00:00:00Z",
  "lastAvailableVersion": "7.2.42",
  "lastDeferredVersion": "7.2.42",
  "pendingVersion": "7.2.42",
  "lastFailureMessage": "GitHub release asset was not found.",
  "lastFailureAt": "2026-07-01T00:01:00Z"
}
```

## 컴포넌트 설계

### `CLIProxyAPIReleaseClient`

상류 GitHub Releases를 읽고 릴리스 metadata를 표준화한다.

책임:

- `router-for-me/CLIProxyAPI` latest release 조회
- latest tag에서 `v` prefix 제거
- macOS arm64 asset 이름 `CLIProxyAPI_<version>_darwin_aarch64.tar.gz` 찾기
- `checksums.txt` asset 찾기와 다운로드 URL 확보
- checksum 파일에서 macOS arm64 asset checksum 추출
- 릴리스 형식이 앱이 이해하는 형식인지 검증

네트워크 구현은 test double을 주입할 수 있는 HTTP client protocol 뒤에 둔다. 단위 테스트는 실제 GitHub를 호출하지 않는다.

### `CLIProxyAPIUpdateService`

앱 레이어의 상태와 orchestration을 담당하는 `ObservableObject`다.

책임:

- 앱 실행 시 자동 확인 시작
- 24시간 자동 확인 주기 관리
- 수동 확인 실행
- `isChecking`, `isUpdating`, `availableUpdate`, `pendingUpdate`, `lastError` 같은 UI 상태 publish
- 다운로드, 검증, pending 저장 orchestration
- “지금 적용”과 “다음 실행에 적용” 처리
- 서버 실행 상태에 따라 restart 요청

SwiftUI view는 이 서비스의 publish 상태를 표시하고, 네트워크·압축 해제·파일 교체를 직접 수행하지 않는다.

### `CLIProxyAPIBinaryStore`

core 레이어에서 파일 시스템과 바이너리 검증·교체를 담당한다.

책임:

- active/pending/update-state manifest 읽기와 쓰기
- archive sha256 검증
- archive 압축 해제
- archive 내부 `cli-proxy-api` 추출
- `cliproxyapi --version` 실행과 metadata 파싱
- binary sha256/size 검증
- pending 저장
- pending을 active로 atomic 승격
- 번들 manifest와 active manifest 비교
- 교체 실패 시 기존 active 바이너리 복구

### `ProxyServiceManager`

`prepare()` 단계에서 실행 파일 선택 정책을 적용한다.

새 순서:

1. 유효한 pending 바이너리가 있으면 active로 승격한다.
2. active 바이너리가 없으면 번들 바이너리를 설치하고 active manifest를 `sourceKind: bundled`로 기록한다.
3. active가 `bundled`이고 앱 번들 버전이 더 최신이면 번들 바이너리로 교체한다.
4. active가 `user-updated`이고 앱 번들 버전이 같거나 더 낮으면 유지한다.
5. active가 `user-updated`이지만 앱 번들 버전이 더 높으면 번들 바이너리로 교체한다.

이 정책은 앱에서 받은 최신 CLIProxyAPI가 앱 번들보다 최신인 동안 유지되게 하고, 나중에 앱 번들이 더 최신 버전을 포함하면 자연스럽게 번들 버전으로 수렴시킨다.

## 버전 비교 정책

CLIProxyAPI 릴리스 tag는 `v<major>.<minor>.<patch>` 형식을 기대한다. 비교는 문자열 비교가 아니라 semantic version 비교로 한다.

예:

- `7.2.9 < 7.2.10`
- `v7.2.41`과 `7.2.41`은 같은 버전으로 정규화한다.

형식이 예상과 다르면 자동 적용하지 않고 업데이트 확인 실패로 처리한다. prerelease suffix가 포함된 tag는 stable 업데이트 대상에서 제외한다.

## 데이터 흐름

### 업데이트 확인

1. `CLIProxyAPIUpdateService`가 현재 버전을 `CLIProxyAPIBinaryStore`에서 읽는다.
2. active manifest가 있으면 active version을 사용한다.
3. active manifest가 없으면 번들 manifest version을 사용한다.
4. `CLIProxyAPIReleaseClient`가 latest release metadata를 가져온다.
5. latest version이 현재 버전보다 높으면 `availableUpdate`를 publish한다.
6. 최신이 아니면 상태를 up-to-date로 갱신한다.

### 다운로드와 검증

1. release archive와 `checksums.txt`를 임시 디렉터리에 다운로드한다.
2. `checksums.txt`에서 archive checksum을 찾는다.
3. 다운로드 archive sha256이 checksum과 일치하는지 확인한다.
4. archive를 임시 디렉터리에 압축 해제한다.
5. `cli-proxy-api` 파일을 찾는다.
6. executable permission을 설정한다.
7. `--version` 출력에서 version, commit, builtAt을 파싱한다.
8. 파싱된 version이 release tag와 일치하는지 확인한다.
9. binary sha256과 size를 계산한다.
10. `pending/cliproxyapi`와 `pending/manifest.json`을 임시 파일에 쓴 뒤 rename으로 완료한다.

### 적용

`Apply now`는 pending을 active로 승격하고, 필요하면 서버를 재시작한다. `Apply on next server start`는 pending을 유지하고 현재 서버를 건드리지 않는다.

다음 `ProxyServiceManager.prepare()`가 실행되면 pending 검증 후 active로 승격한다. 승격이 성공하면 pending 디렉터리를 정리한다.

## 동시성 정책

- 업데이트 확인은 `isChecking` 또는 내부 task guard로 한 번만 실행한다.
- 다운로드와 적용은 `isUpdating` 또는 store lock으로 한 번만 실행한다.
- active/pending 교체는 파일 시스템 lock 또는 단일 actor/serial queue 안에서 수행한다.
- 중간 실패는 임시 디렉터리와 임시 파일만 남기고 active 바이너리를 변경하지 않는다.
- 앱 종료로 작업이 중단되면 다음 실행에서 불완전한 임시 파일을 정리한다.

## UI 설계

기존 `About > Updates`는 Sparkle 앱 업데이트 전용으로 유지한다. CLIProxyAPI 바이너리 업데이트는 서버 런타임과 직접 관련 있으므로 `Settings > Server`에 별도 row를 추가한다.

Row 예시:

- Label: `CLIProxyAPI binary`
- Description 상태:
  - 평상시: `Current version: 7.2.41`
  - 확인 중: `Checking for CLIProxyAPI updates…`
  - 새 버전 있음: `Version 7.2.42 is available.`
  - pending 있음: `Version 7.2.42 will be applied on next server start.`
  - 실패 있음: `Last check failed.`
- Button 상태:
  - 기본: `Check now`
  - 새 버전 있음: `Update…`
  - pending 있음: `Apply now` 또는 `Restart now`

자동 확인에서 새 버전이 발견되면 confirmation dialog로 `Update` 또는 `Later`를 묻는다. 다운로드와 검증 완료 후 두 번째 confirmation dialog로 `Apply now and restart server` 또는 `Apply on next server start`를 묻는다.

## 오류 처리

### 자동 확인 실패

자동 확인 실패는 사용자에게 즉시 alert하지 않는다. `update-state.json`에 마지막 실패 사유와 시간을 기록한다. Settings row는 필요한 경우 `Last check failed.` 정도만 표시한다.

### 수동 확인 실패

수동 확인 실패는 `settingsMessage`나 alert로 표시한다.

예:

```text
Failed to check CLIProxyAPI updates: GitHub release asset was not found.
```

### 다운로드와 검증 실패

기존 active 바이너리는 유지한다. 불완전한 pending 파일은 삭제한다. checksum 불일치는 보안 오류로 취급하고 절대 적용하지 않는다.

예:

```text
Downloaded CLIProxyAPI archive did not match upstream checksum. The existing binary was kept.
```

### 적용 실패

교체 전 active 바이너리를 backup으로 보존하고, 승격 실패 시 복구한다. 서버 재시작 실패는 바이너리 적용 성공/실패와 구분해 표시한다.

예:

```text
CLIProxyAPI was updated, but the server failed to restart: <reason>
```

## 테스트 전략

### Core 테스트

- `ManagedPaths`가 새 경로를 노출한다.
- bundled만 있을 때 active 바이너리와 active manifest를 설치한다.
- pending이 있으면 prepare 전에 active로 승격한다.
- `user-updated` active가 bundled보다 최신이면 유지한다.
- bundled가 `user-updated` active보다 최신이면 bundled로 교체한다.
- checksum/size가 맞지 않는 pending은 적용하지 않는다.
- active 교체 실패 시 기존 active를 유지하거나 복구한다.
- semantic version comparison이 `7.2.9 < 7.2.10`을 올바르게 처리한다.
- `v` prefix를 정규화한다.
- prerelease 또는 잘못된 버전 문자열을 stable 업데이트 대상에서 제외한다.

### Release client 테스트

- fake HTTP client로 latest release JSON을 파싱한다.
- macOS arm64 asset URL을 찾는다.
- `checksums.txt`에서 asset checksum을 추출한다.
- macOS arm64 asset 누락 시 오류를 반환한다.
- checksum entry 누락 시 오류를 반환한다.
- 실제 GitHub 네트워크 호출 없이 테스트한다.

### Update service 테스트

- 앱 실행 시 24시간이 지난 경우만 자동 확인한다.
- 수동 확인은 24시간 제한을 무시한다.
- 새 버전 발견 상태를 publish한다.
- `Later`로 미룬 버전은 같은 자동 확인 주기에서 반복 alert하지 않는다.
- 다운로드 검증 성공 시 pending을 만든다.
- `Apply now`는 서버가 실행 중이면 restart를 요청한다.
- `Apply now`는 서버가 꺼져 있으면 restart 없이 active만 교체한다.
- `Apply on next server start`는 restart를 요청하지 않는다.

### UI 테스트

- Server settings에 CLIProxyAPI binary row가 표시된다.
- 상태별 description과 button title이 올바르다.
- 새 버전 발견 시 update confirmation이 표시된다.
- 검증 완료 후 적용 방식 선택 confirmation이 표시된다.
- pending 상태가 있을 때 next-start 적용 문구가 표시된다.

### 문서와 기존 스크립트

- `scripts/vendor-cliproxyapi.sh`는 개발자가 앱 번들 기본 바이너리를 갱신하는 경로로 유지한다.
- README는 앱 자체 Sparkle 업데이트와 CLIProxyAPI 바이너리 업데이트가 분리되어 있음을 설명한다.
- README는 앱이 상류 GitHub Releases를 직접 확인하고 checksum 검증 후 적용한다는 보안 모델을 설명한다.

## 수용 기준

- 앱 실행 시 CLIProxyAPI 최신 릴리스를 백그라운드로 확인하되, 자동 확인은 24시간에 한 번만 수행한다.
- 사용자는 수동으로 즉시 확인할 수 있다.
- 새 CLIProxyAPI 버전이 있으면 앱이 사용자에게 업데이트 여부를 묻는다.
- 사용자가 업데이트를 선택하면 앱은 상류 checksum 검증 후에만 pending 바이너리를 만든다.
- 사용자는 “지금 적용 후 재시작” 또는 “다음 실행에 적용” 중 선택할 수 있다.
- “다음 실행에 적용”은 현재 실행 중인 서버를 건드리지 않는다.
- pending 바이너리는 다음 서버 시작/재시작 prepare 단계에서 active로 승격된다.
- checksum 불일치, asset 누락, 압축 해제 실패, metadata 불일치 시 기존 바이너리는 변경되지 않는다.
- user-updated 바이너리는 앱 번들 바이너리가 더 최신이 아닌 한 번들 버전으로 되돌아가지 않는다.
- 기존 Sparkle 앱 업데이트 흐름은 그대로 유지된다.
- 기존 vendoring script와 앱/코어 테스트는 계속 통과한다.
