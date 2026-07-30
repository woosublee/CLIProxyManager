# Version/build 단일 진실 공급원 설계

- 작성일: 2026-07-30
- 상태: 승인됨
- 대상 이슈: [#99 — Version/build number의 단일 진실 공급원 확립](https://github.com/woosublee/CLIProxyManager/issues/99)
- 상위 로드맵: [#130 — CLIProxyManager Product Quality Roadmap — 2026 H2](https://github.com/woosublee/CLIProxyManager/issues/130)
- 마일스톤: M1 — Release Truth & Safety

## 1. 목적

CLIProxyManager의 app version과 build number를 하나의 canonical metadata에서 관리한다. Makefile, source plist, local release, GitHub Actions, built app, DMG, Sparkle appcast가 동일한 resolver 결과를 사용하도록 바꾸고, 불일치와 build number 역행을 원격 tag 또는 GitHub Release 생성 전에 차단한다.

완료 후에는 다음이 성립해야 한다.

- version/build의 수동 편집 가능한 source는 정확히 하나다.
- 같은 commit의 local release와 CI release는 같은 version, build, tag, DMG filename을 만든다.
- source plist와 모든 release artifact identity가 canonical metadata와 일치한다.
- latest published build 이하의 release는 기본적으로 fail closed 한다.
- 오류는 기대값, 실제값, source, 복구 명령을 제공하되 secret과 raw local path를 포함하지 않는다.

## 2. 현재 문제

현재 release identity는 여러 위치에서 독립적으로 관리된다.

- `Makefile`은 version `0.1.32`, build `35`를 기본값으로 가진다.
- `Info.plist`에는 version `0.1.12`, build `15`가 남아 있다.
- `scripts/release-local.sh`는 입력 tag에서 version을 만들고 source plist에서 build를 읽는다.
- `.github/workflows/release.yml`은 Makefile print target을 읽은 뒤 workflow 안에서 tag와 path를 다시 계산한다.
- `scripts/generate-sparkle-appcast.sh`는 외부 환경변수의 version/build/tag/path를 신뢰한다.

따라서 같은 commit도 실행 경로에 따라 다른 artifact identity를 만들 수 있고, source plist가 stale이어도 bundle 단계의 덮어쓰기로 문제가 가려질 수 있다. 현재 release workflow에는 published build보다 build number가 큰지 확인하는 공통 gate도 없다.

## 3. 결정 사항

### 3.1 Canonical metadata

`release/version.json`을 version/build의 유일한 수동 편집 source로 둔다.

```json
{
  "version": "0.1.32",
  "build": 35
}
```

Validation 규칙은 다음과 같다.

- root는 JSON object여야 한다.
- key는 `version`, `build` 두 개만 허용한다.
- `version`은 문자열이며 정규식 `^[0-9]+\.[0-9]+\.[0-9]+$`를 만족해야 한다.
- prerelease와 build metadata는 이번 범위에서 허용하지 않는다.
- `build`는 JSON number인 1 이상의 정수여야 한다.
- 문자열형 build, 0, 음수, 소수, 누락 key, 추가 key를 거부한다.
- version 값의 leading/trailing whitespace를 거부한다.

Stable SemVer만 허용하는 이유는 현재 release workflow와 공개 release가 모두 `vX.Y.Z`를 전제로 하며 release channel 설계는 #99의 비목표이기 때문이다.

### 3.2 도구 의존성

Resolver와 parity script는 지원 macOS와 GitHub macOS runner에서 사용할 수 있는 system tool을 우선한다.

- JSON/plist parsing 및 type 검증: `/usr/bin/plutil`
- XML appcast parsing 및 구조 검증: `/usr/bin/xmllint`
- GitHub release 조회·download: `gh`
- HTTP 또는 GitHub 조회 실패는 성공으로 간주하지 않는다.

Python, Node, 별도 package 설치를 release identity 해석의 필수 의존성으로 추가하지 않는다.

### 3.3 Published identity 기준

이전 release identity의 authoritative source는 최신 non-draft, non-prerelease GitHub Release에 첨부된 `appcast.xml`이다.

Sparkle가 실제 update 판단에 사용하는 값이 appcast의 `sparkle:version`이므로 build monotonicity도 이 값을 기준으로 한다. 이전 appcast의 item element와 enclosure attribute에 있는 build/version이 서로 다르면 이전 release metadata 자체를 손상 상태로 보고 release를 중단한다.

## 4. 컴포넌트 설계

### 4.1 `scripts/resolve-release-version.sh`

책임은 canonical metadata 읽기와 strict validation이다. 다른 release script는 JSON을 직접 해석하지 않는다.

지원 command는 다음과 같다.

```text
validate
version
build
tag
dmg-name
dmg-path
appcast-path
shell
json
```

대표 출력은 다음과 같다.

```text
version      → 0.1.32
build        → 35
tag          → v0.1.32
dmg-name     → CLIProxyManager-0.1.32.dmg
dmg-path     → build/CLIProxyManager-0.1.32.dmg
appcast-path → build/appcast.xml
```

`shell`은 caller가 안전하게 `eval`할 수 있도록 고정된 변수 이름과 shell-escaped 값만 출력한다.

```bash
RELEASE_VERSION='0.1.32'
RELEASE_BUILD='35'
RELEASE_TAG='v0.1.32'
RELEASE_DMG_NAME='CLIProxyManager-0.1.32.dmg'
RELEASE_DMG_PATH='build/CLIProxyManager-0.1.32.dmg'
RELEASE_APPCAST_PATH='build/appcast.xml'
```

`json`은 CI와 provenance consumer를 위한 machine-readable object를 출력한다. 출력 schema는 canonical metadata와 derived fields로 고정한다.

오류 메시지는 다음 정보를 포함한다.

- logical source: `release/version.json`
- 위반한 field 또는 형식
- 기대 형식
- 가능한 경우 실제 값
- 복구 명령 또는 편집 대상

오류에는 absolute repository path를 출력하지 않는다.

### 4.2 `scripts/sync-release-version.sh`

Source `Info.plist`를 canonical metadata의 generated mirror로 관리한다.

기본 실행:

1. resolver를 검증한다.
2. `Info.plist`와 같은 directory에 temporary copy를 만든다.
3. temporary copy의 `CFBundleShortVersionString`과 `CFBundleVersion`을 canonical 값으로 교체한다.
4. `plutil -lint`와 exact value 검증을 수행한다.
5. 성공하면 atomic rename으로 `Info.plist`를 교체한다.
6. 실패하면 temporary file만 제거하고 기존 plist는 보존한다.

`--check` 실행:

- 파일을 변경하지 않는다.
- version/build 각각의 기대값과 실제값을 비교한다.
- mismatch이면 `scripts/sync-release-version.sh`를 복구 명령으로 출력하고 non-zero로 종료한다.

`Info.plist`는 commit되는 generated mirror다. Version bump commit에는 `release/version.json`과 동기화된 `Info.plist`가 함께 포함되어야 한다.

### 4.3 `scripts/check-release-monotonic.sh`

현재 canonical build가 latest published build보다 큰지 검사한다.

기본 online mode:

1. repository를 명시적 option 또는 `gh repo view`에서 결정한다.
2. latest non-draft, non-prerelease release를 조회한다.
3. release가 하나도 없으면 `no previous release` 결과로 통과한다.
4. 조회 command 자체가 실패하면 network/API failure로 중단한다.
5. latest release의 `appcast.xml`을 temporary directory에 download한다.
6. appcast element와 enclosure의 version/build parity를 검증한다.
7. 현재 build가 이전 build보다 큰 경우에만 통과한다.

Local fallback mode:

- `--previous-appcast <file>`을 명시한 local release에서만 사용할 수 있다.
- CI에서는 이 option을 전달하지 않으며 workflow도 관련 환경변수를 참조하지 않는다.
- fallback appcast도 구조와 내부 parity를 동일하게 검증한다.
- fallback은 monotonic rule을 완화하지 않는다. 현재 build는 제공된 이전 build보다 반드시 커야 한다.
- provenance에는 `trust: local-fallback`을 기록한다.
- 오류와 provenance에 fallback file의 raw local path를 기록하지 않는다.

출력 provenance는 `build/release-provenance.json`에 atomic write한다.

```json
{
  "trust": "official",
  "current": {
    "version": "0.1.32",
    "build": 35,
    "tag": "v0.1.32"
  },
  "previous": {
    "version": "0.1.31",
    "build": 34,
    "tag": "v0.1.31"
  },
  "source": "github-release-appcast"
}
```

첫 release는 `previous: null`, `source: "no-previous-release"`를 기록한다. Timestamp와 machine/user identity는 재현 가능한 artifact identity에 필요하지 않으므로 포함하지 않는다.

### 4.4 `scripts/verify-release-artifacts.sh`

Canonical metadata와 generated artifact의 parity만 검증한다.

검증 대상:

- source `Info.plist`
- built app의 `Contents/Info.plist`
- DMG filename
- DMG 내부 app의 plist
- appcast item의 `sparkle:version`과 `sparkle:shortVersionString`
- appcast enclosure의 동일 attribute
- appcast enclosure URL의 tag와 DMG filename
- provenance current identity

각 검사에는 `--source-plist`, `--app`, `--dmg`, `--appcast`, `--provenance`처럼 명시적인 입력 option을 사용한다. 제공된 입력만 검사할 수 있지만 official release preflight는 전체 입력을 요구한다.

Mismatch 오류는 기대값, 실제값, artifact의 logical name을 출력한다. Temporary mount path와 absolute local path는 출력하지 않는다.

### 4.5 Makefile

Makefile의 `VERSION ?=`와 `BUILD_NUMBER ?=` 기본값을 제거한다.

- `print-app-version`, `print-build-number`, `print-build-tag`는 호환성을 유지하되 resolver command에 delegate한다.
- `bundle`, `sign`, `verify`, `dmg`, `verify-dmg`, `sign-dmg`는 canonical resolver validation과 source plist `--check`를 prerequisite로 사용한다.
- Bundle plist에는 resolver가 반환한 version/build를 기록한다.
- DMG path도 resolver에서 가져온다.
- Official artifact target은 command-line `VERSION` 또는 `BUILD_NUMBER` override를 오류로 거부한다. 같은 값을 전달해도 중복 source로 간주한다.

개발용 identity override가 필요한 경우 기존 official 변수 이름을 재사용하지 않는다.

```bash
make ARTIFACT_CHANNEL=development \
  DEVELOPMENT_VERSION=0.1.32 \
  DEVELOPMENT_BUILD_NUMBER=9001 bundle
```

Development override 규칙:

- `ARTIFACT_CHANNEL=development`가 명시돼야 한다.
- version/build validation 규칙은 official metadata와 동일하다.
- DMG filename에는 `-development` suffix를 붙인다.
- built plist에는 `CLIProxyManagerReleaseChannel=development`를 기록한다.
- official release script와 parity checker는 development artifact를 거부한다.
- development override가 없으면 일반 development build도 canonical identity를 사용한다.

### 4.6 `scripts/release-local.sh`

Local release는 tag를 version source로 사용하지 않는다. 입력 tag는 canonical tag와 같은지 확인하는 assertion이다.

순서:

1. resolver validation과 source plist parity
2. 입력 tag와 canonical tag parity
3. remote tag state 확인
4. online monotonic check 또는 명시적 local fallback check
5. signing identity 확인
6. canonical identity로 DMG build 및 verification
7. canonical identity로 appcast 생성
8. app, DMG, appcast, provenance 전체 parity
9. remote tag state와 monotonic source 재확인
10. 신규 release이면 현재 HEAD에 canonical tag를 생성하고 push
11. GitHub Release 생성 및 DMG, appcast, provenance upload

기본 mode에서는 remote canonical tag가 없어야 한다. `ALLOW_LOCAL_RELEASE_CLOBBER=1`은 이미 정상 publish된 release의 artifact를 임의 교체하는 용도가 아니라, 이전 실행이 tag push 이후 release 또는 asset upload에서 실패한 경우에만 사용하는 resume mode로 제한한다. Resume mode에서는 remote tag가 현재 HEAD를 가리키고, canonical identity의 valid appcast가 아직 publish되지 않았음을 확인해야 한다. 기존 valid appcast가 있거나 tag가 다른 commit을 가리키면 실패한다.

`VERSION`, `BUILD_NUMBER`, `RELEASE_TAG`, `DMG_PATH` 환경변수를 identity override로 받지 않는다. `REPOSITORY`, signing material, output directory와 같은 identity 외 설정만 허용한다.

Local fallback을 사용하면 release note에 remote published appcast 대신 명시적 fallback appcast를 검증했다는 사실을 표시한다. 두 번째 검사는 첫 번째와 같은 comparison source를 다시 검증한다. Online mode는 latest remote appcast를 다시 내려받고, fallback mode는 제공된 appcast를 다시 검증하면서 remote tag state를 별도로 재확인한다.

### 4.7 `.github/workflows/release.yml`

Workflow의 inline version/tag/path parsing을 제거하고 resolver output만 사용한다.

- `Resolve release version` step은 `scripts/resolve-release-version.sh shell` 또는 `json`을 사용한다.
- source plist check, input tag parity, tag absence, monotonic check를 build 전에 수행한다.
- Make invocation에서 `VERSION=... BUILD_NUMBER=...`를 제거한다.
- Appcast step에서도 version/build/tag/path 환경변수를 제거한다.
- Artifact parity와 두 번째 monotonic check가 끝난 뒤 tag를 생성한다.
- DMG, appcast와 함께 `build/release-provenance.json`을 upload한다.

Workflow에는 official release를 직렬화하는 concurrency를 추가한다.

```yaml
concurrency:
  group: cliproxymanager-official-release
  cancel-in-progress: false
```

이 설정은 두 official CI release가 같은 published build를 기준으로 동시에 진행되는 것을 막는다. Local fallback은 낮은 신뢰 수준의 수동 경로이며 CI concurrency에 참여하지 않으므로 release 운영 문서에서 CI와 동시에 실행하지 않도록 명시한다. Local path도 artifact 생성 후 tag 생성 직전에 remote tag state와 최초 검사에서 선택한 monotonic comparison source를 다시 확인한다.

### 4.8 `scripts/generate-sparkle-appcast.sh`

Appcast generator는 version/build/tag/DMG path를 canonical resolver에서 가져온다.

허용되는 외부 설정:

- `REPOSITORY`
- `APP_NAME`
- `APPCAST_PATH` 또는 별도 output option
- `SPARKLE_PRIVATE_KEY`와 Sparkle tool/keychain 설정

`VERSION`, `BUILD_NUMBER`, `RELEASE_TAG`, `DMG_PATH`가 설정되어 있으면 silent override하지 않는다. Legacy caller를 조기에 발견할 수 있도록 제거 방법을 포함한 오류로 거부한다.

생성 직후 appcast 내부 element와 enclosure identity를 다시 검증한다.

## 5. Data flow

### 5.1 Version bump

```text
release/version.json 편집
  → scripts/sync-release-version.sh
  → temporary plist 수정·검증
  → Info.plist atomic rename
  → scripts/sync-release-version.sh --check
  → 변경된 두 파일을 같은 commit으로 review
```

Build가 stale plist를 자동으로 고쳐서 drift를 숨기지 않는다. `--check` 실패 시 사용자가 sync command를 명시적으로 실행해야 한다.

### 5.2 Official CI release

```text
Canonical metadata validate
  → source plist parity
  → workflow input tag parity
  → remote tag absence
  → latest appcast monotonic check
  → tests
  → build/sign/DMG
  → appcast generation
  → app/bundled plist/DMG/appcast/provenance parity
  → remote tag state + latest appcast second check
  → tag push
  → GitHub Release + artifacts upload
```

원격 쓰기는 모든 local artifact 검증과 두 번째 release identity 검사 이후에만 시작한다.

### 5.3 Local fallback release

```text
Official preflight
  → online latest appcast monotonic check
     또는 explicit previous appcast + local-fallback provenance
  → build/sign/verify
  → remote tag state + selected comparison source second check
  → tag push 또는 verified resume
  → release publish
```

Remote appcast 조회 실패는 자동으로 fallback mode로 전환되지 않는다. Fallback은 사용자가 이전 appcast를 명시적으로 제공했을 때만 활성화된다. Release publish에는 remote tag 확인과 GitHub 쓰기 연결이 필요하므로 GitHub 자체에 접근할 수 없는 완전한 offline 상태에서는 artifact 검증까지만 가능하고 publish는 실패한다.

## 6. 실패와 rollback

### 6.1 원격 쓰기 전 실패

다음 오류는 tag push와 GitHub Release 생성 전에 실패한다.

- malformed canonical metadata
- source plist drift
- workflow/local input tag mismatch
- 기본 mode의 existing remote tag 또는 resume mode의 tag/commit mismatch
- Online mode의 latest release 조회 실패
- Online mode의 latest appcast 누락·손상·내부 mismatch
- Fallback mode의 explicit previous appcast 누락·손상·내부 mismatch
- build 역행 또는 중복
- built plist, DMG, appcast, provenance mismatch
- development artifact의 official release 시도

이 단계는 repository source, 설치된 app, account, shell, config, proxy runtime을 수정하지 않는다.

### 6.2 Atomic local writes

- Plist sync는 same-directory temporary file과 atomic rename을 사용한다.
- Provenance도 temporary file을 검증한 뒤 atomic rename한다.
- Appcast는 temporary file에 생성·XML 검증·identity parity를 수행한 뒤 final path로 이동한다.
- 실패 시 기존 source plist와 기존 valid output을 부분 상태로 교체하지 않는다.

### 6.3 원격 쓰기 이후 실패

Tag push 이후 GitHub Release API 또는 asset upload가 실패하면 자동으로 tag를 삭제하지 않는다. 원격 tag 삭제는 destructive하고 release race에서 다른 정상 상태를 제거할 수 있기 때문이다.

대신 오류에 다음을 제공한다.

- 생성된 tag
- 누락된 release 또는 asset
- 안전한 재실행 command
- clobber가 필요한 경우 명시적인 opt-in

## 7. 동시 실행 정책

- Official GitHub Actions release는 repository-wide concurrency group으로 직렬화한다.
- Artifact 생성 전과 tag push 직전에 remote tag state와 선택된 monotonic comparison source를 확인한다.
- 동일 canonical commit과 tag의 중복 실행은 기본적으로 remote tag check로 차단하고, 검증된 partial publish만 explicit resume mode로 재개한다.
- 같은 build를 가진 다른 version의 official CI 실행은 concurrency와 두 번째 monotonic check로 먼저 publish된 실행만 통과한다.
- Local fallback은 official concurrency lock에 참여하지 않으므로 CI release와 동시에 실행하지 않는 운영 제약을 문서화하고, 두 번째 tag/source check를 필수로 한다.

## 8. 테스트 설계

### 8.1 새 script test

`Tests/ScriptTests/release-version-tests.sh`를 추가한다.

Resolver:

- valid metadata의 `version`, `build`, `tag`, path, `shell`, `json` 출력
- malformed JSON
- root object가 아닌 JSON
- 누락 key와 추가 key
- whitespace가 포함된 version
- prerelease와 build metadata version
- build 0, 음수, 소수, 문자열
- shell output에서 임의 command가 실행되지 않는 안전한 quoting

Plist sync:

- stale plist `--check` 실패와 복구 명령
- sync 후 exact parity
- `plutil` 또는 rename 실패 시 기존 plist 보존
- 이미 일치하면 내용 변경 없음

Monotonic check:

- previous build보다 큰 current build 통과
- 같은 build와 작은 build 실패
- release가 없는 repository 통과
- Online mode의 GitHub/latest appcast 조회 실패가 explicit fallback 없이 fail closed
- Remote tag state 조회 실패는 fallback mode에서도 fail closed
- Appcast asset 누락·malformed XML·element/enclosure mismatch 실패
- local fallback 통과와 `trust: local-fallback` provenance
- fallback local path가 output/provenance에 포함되지 않음

Artifact parity:

- source plist, app plist, DMG name, DMG 내부 plist, appcast, provenance 정상 조합
- 각 source별 version/build mismatch
- enclosure URL tag/filename mismatch
- development artifact 거부

### 8.2 기존 script test

`Tests/ScriptTests/release-local-tests.sh`:

- resolver → monotonic check → signing → build → appcast → parity → second tag/source check → tag push 또는 resume → upload 순서
- tag mismatch, monotonic failure, parity failure에서 tag push와 `gh release create/upload`을 호출하지 않음
- version/build를 plist와 tag에서 직접 읽지 않음
- fallback provenance와 release note 표시
- 기존 signing identity를 유지하고 explicit clobber를 검증된 partial publish resume로 제한

`Tests/ScriptTests/generate-sparkle-appcast-tests.sh`:

- canonical resolver identity로 appcast 생성
- legacy identity environment override 거부
- item element와 enclosure parity
- temporary output 검증 후 atomic replace
- 기존 Sparkle private key와 Keychain fallback 유지

### 8.3 Workflow policy test

`Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`:

- workflow가 공통 resolver, plist check, monotonic check, artifact parity를 호출함
- inline SemVer parsing과 duplicate path 계산이 없음
- Makefile에 independent version/build default가 없음
- release Make invocation에 version/build override가 없음
- concurrency group과 second tag/latest-appcast check가 tag step 앞에 있음
- provenance가 release asset에 포함됨
- signing과 Sparkle 관련 기존 보안 검증을 유지함

### 8.4 자동 검증 명령

```bash
bash Tests/ScriptTests/release-version-tests.sh
bash Tests/ScriptTests/release-local-tests.sh
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
swift test --filter ReleaseWorkflowTests
swift test
swift build -c debug
```

Development artifact 검증:

1. Canonical metadata로 development app bundle을 생성한다.
2. Source plist, built plist, expected DMG identity를 parity script로 검사한다.
3. `plutil`로 built plist의 version/build를 독립 확인한다.

자동 검증은 development build까지 수행한다. 실제 앱 실행과 About/update UI의 version/build 확인은 사용자가 담당한다.

## 9. 문서 변경

`README.md`와 `README.en.md`에 다음을 기록한다.

- `release/version.json`이 canonical source라는 점
- version bump와 plist sync/check 절차
- official CI release preflight와 build monotonicity
- local fallback의 명시적 사용법과 낮은 trust level
- development override와 official artifact 구분
- 원격 쓰기 이후 실패 시 안전한 재실행 절차

## 10. 보안·개인정보·접근성

- Resolver와 parity error에는 certificate, signing key, token, email을 출력하지 않는다.
- Absolute repository path와 fallback appcast local path를 출력하거나 provenance에 저장하지 않는다.
- Workflow input과 metadata는 strict validation 후 shell-escaped output으로만 전달한다.
- User-controlled metadata를 `eval`할 때 resolver가 고정된 변수 이름과 escaped literal만 생성한다.
- About/update UI에 기존 version/build 표시를 유지하며, UI 변경이 발생하면 VoiceOver가 version과 build를 구분해 읽는 label을 사용한다.

## 11. 명시적 비목표

- Developer ID signing, notarization, stapling
- 자동 version/build bump 정책
- prerelease 또는 다중 release channel의 production 설계
- CLIProxyAPI version과 app version 통합
- App update 또는 CLIProxyAPI update health rollback
- GitHub tag와 Release의 destructive automatic rollback
- Release telemetry 추가

## 12. 완료 기준

- `release/version.json` 외에 수동 편집 가능한 app version/build source가 없다.
- Makefile, source plist, local/CI release, built app, DMG, appcast, provenance가 canonical identity와 일치한다.
- Official artifact는 `VERSION` 또는 `BUILD_NUMBER` command-line override로 identity를 바꿀 수 없다.
- Stable SemVer와 positive integer 규칙을 벗어난 metadata는 artifact 생성 전에 실패한다.
- Build 역행과 중복은 tag push 전에 차단된다.
- Network/API failure는 기본적으로 fail closed 한다.
- Local fallback은 명시적으로만 활성화되며 낮은 trust level이 artifact와 release note에 남는다.
- 관련 script test, workflow test, 전체 `swift test`, debug build, development artifact parity가 통과한다.
- README의 한국어·영어 release 절차가 실제 command와 일치한다.
