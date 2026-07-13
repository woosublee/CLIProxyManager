# cpm 호환 revision 기반 업데이트 판정 설계

## 배경

`cpm`은 CLIProxyManager 앱과 함께 빌드되고 앱 번들의 `Contents/Helpers/cpm`에 포함된다. 별도 릴리스나 독립 업데이트 채널은 없다.

현재 `CPMInstallationService`는 `/usr/local/bin/cpm`을 설치할 때 바이너리 SHA-256과 앱 버전을 기록한다. 상태 확인 시 설치된 바이너리와 앱 번들 바이너리의 SHA-256을 직접 비교한다. Swift 빌드는 cpm 기능 변경이 없어도 공용 코드, 컴파일러 입력 또는 링크 결과에 따라 바이너리 hash가 달라질 수 있다. 이 때문에 앱만 변경된 릴리스에서도 cpm Update가 표시될 수 있다.

## 목표

- 앱 버전이 올라가더라도 cpm 기능이나 동작이 바뀌지 않았다면 기존 설치를 최신으로 간주한다.
- cpm 명령, 출력 계약, 런타임 동작 또는 필수 의존 동작이 실제로 바뀐 릴리스에서만 Update를 표시한다.
- 사용자가 `/usr/local/bin/cpm`을 외부에서 변경한 경우에는 기존처럼 `unmanaged`로 판정한다.
- cpm을 앱과 별도로 배포하거나 semantic version을 관리하지 않는다.

## 비목표

- 앱 업데이트 과정에서 관리자 권한을 자동 요청해 `/usr/local/bin/cpm`을 교체하지 않는다.
- cpm 독립 릴리스 채널이나 자동 업데이트 기능을 추가하지 않는다.
- 소스 파일 목록이나 빌드 산출물 hash로 cpm 기능 변경 여부를 자동 추론하지 않는다.

## 설계

### 명시적 compatibility revision

앱 코드에 정수형 cpm compatibility revision을 정의한다. 초기 revision은 `1`이다.

revision은 다음 변경에서만 수동으로 증가한다.

- cpm 명령 추가·삭제 또는 argument 계약 변경
- cpm 출력 형식이나 exit code 계약 변경
- 기존 명령의 사용자 관찰 가능 동작 변경
- cpm 실행에 필수적인 Core 동작 변경

앱 UI, 메뉴바, 설정 화면, 번들 CLIProxyAPI 또는 cpm과 무관한 Core 변경에서는 증가시키지 않는다.

### 설치 기록

설치 기록은 다음 필드를 저장한다.

```json
{
  "digest": "<installed binary SHA-256>",
  "appVersion": "0.1.17",
  "cpmRevision": 1
}
```

- `digest`: 설치 후 `/usr/local/bin/cpm`의 실제 SHA-256. 외부 변경 감지에 사용한다.
- `appVersion`: 사용자가 설치한 cpm이 어느 앱 릴리스에서 제공됐는지 표시하기 위한 정보다.
- `cpmRevision`: 업데이트 필요 여부를 판정하는 기준이다.

기존 기록의 `version` 필드는 decoding 호환을 위해 legacy 필드로 읽을 수 있지만 새 기록에는 `appVersion`을 사용한다.

### 상태 판정

`CPMInstallationService.status()`는 다음 순서로 판정한다.

1. `/usr/local/bin/cpm`이 없으면 `.notInstalled`.
2. 설치 기록이 없거나 기록된 `digest`와 설치 파일 hash가 다르면 `.unmanaged`.
3. 기록에 `cpmRevision`이 없으면 `.installedOutdated`.
4. 기록의 revision이 현재 번들 revision보다 낮으면 `.installedOutdated`.
5. 기록의 revision이 현재 번들 revision과 같으면, 번들 바이너리 hash가 달라도 `.installedCurrent`.
6. 기록 revision이 현재 revision보다 높으면 downgrade를 권장하지 않고 `.installedCurrent`로 취급한다.

설치 파일 hash와 기록 hash 비교는 유지하므로, revision 판정 완화가 외부 파일 덮어쓰기를 숨기지 않는다.

### 기존 설치 마이그레이션

기존 설치 기록에는 `digest`와 `version`만 있다. revision이 없는 기존 기록은 한 번 `.installedOutdated`로 표시한다. 사용자가 Update를 실행하면 현재 번들 cpm을 설치하고 revision 기반 기록으로 전환한다.

자동 마이그레이션으로 기존 파일을 최신으로 간주하지 않는다. 기존 cpm이 현재 revision의 계약을 만족하는지 기록만으로 증명할 수 없기 때문이다.

### UI 문구

기존 상태 enum 형태는 유지한다.

- current: `Installed at /usr/local/bin/cpm (from app <version>).`
- outdated: `Installed from app <old>; cpm update included with app <new>.`

버튼은 `Update`를 유지할 수 있지만, description은 앱 전체 업데이트가 아니라 cpm 동기화임을 명확히 한다. 후속 UI 정리가 필요하면 `Sync with app`으로 변경할 수 있으나 이번 구현의 필수 범위는 아니다.

## 오류 처리

- 설치 기록 decoding 실패는 기존처럼 `.unmanaged`로 처리한다.
- revision이 음수이거나 유효하지 않으면 legacy/invalid 기록으로 보고 `.installedOutdated`로 처리한다.
- 설치 후 source와 target hash가 다르면 설치 실패로 처리하고 기록을 쓰지 않는다.
- 파일이 외부에서 변경된 경우 revision과 관계없이 `.unmanaged`를 유지한다.

## 테스트

`CPMInstallationServiceTests`에 다음 회귀 테스트를 추가한다.

1. 설치 시 digest, appVersion, cpmRevision을 기록한다.
2. 앱 번들 cpm hash가 바뀌어도 revision이 같으면 current다.
3. 번들 revision이 증가하면 outdated다.
4. 설치 기록 revision이 현재보다 높으면 current다.
5. legacy 기록에 revision이 없으면 outdated다.
6. 설치 파일 hash가 기록과 다르면 revision이 같아도 unmanaged다.
7. update 후 새 revision 기록이 생성되고 current가 된다.

## 운영 규칙

cpm 사용자 관찰 가능 동작을 변경하는 PR은 compatibility revision 증가 여부를 체크한다. revision 값에는 앱 버전 의미를 부여하지 않으며 단조 증가하는 정수로만 사용한다.
