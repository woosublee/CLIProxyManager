# Codex 쿨다운 복구와 CLIProxyAPI 호환성 보완

## 원인과 작업 범위

Codex에서 외부 사용량 리셋을 적용해도 CLIProxyAPI가 이전 429 응답에서 저장한 로컬 라우팅 cooldown은 남을 수 있다. 공급자 사용량 조회와 로컬 계정 선택 제한은 별개의 상태이므로 앱에서 사용량만 새로고침해도 제한이 풀리지 않는다.

업스트림 이슈 [#5728](https://github.com/router-for-me/CLIProxyAPI/issues/5728)의 안내 및 v7.2.152/v7.3.8 소스에서 계정별 `POST /v0/management/reset-quota`를 확인했다. 이번 변경은 이 공식 API를 사용하는 **명시적 수동 복구**다. 실제 공급자 사용량을 리셋하거나 reset credit을 소비하지 않는다. 자동 cooldown 해제나 서버 자동 재시작은 추가하지 않는다.

## 적용 사항

### 로컬 cooldown 조회와 수동 해제

- `auth-files`의 `observed_at`과 credential별 `cooldowns`를 사용량 snapshot과 분리해서 보관한다. 진단은 디스크에 지속화하지 않는다.
- 빈 배열은 관측된 cooldown 없음, 누락/null은 관측 미지원, 형식 오류와 조회 실패는 확인 불가로 구별한다. 빈 배열을 전체 계정 정상 판정으로 사용하지 않는다.
- 사용량 요청 실패 시에도 성공한 관리 API 진단을 표시할 수 있다. 추가 진단 필드의 오류가 정상 사용량 결과를 폐기하지 않는다.
- 활성 OAuth 계정 카드에서 제한 범위, 모델, quota 여부, 재시도 시각과 관측 시각을 확인할 수 있다. 이메일이나 토큰을 진단 문구에 포함하지 않는다.
- 계정 메뉴의 `Clear quota cooldown…`은 확인 후에만 실행된다. 해당 계정의 모델별 cooldown도 함께 해제될 수 있음을 설명한다.
- 요청마다 filename/provider를 유일하게 다시 매칭해 최신 `auth_index`를 사용한다. disabled/expired credential, 빈 index, 중복/없는 대상, 잘못된 port, management key 부재는 POST 전에 거부한다.
- 최신 관측에 quota 차단이 없으면 POST하지 않는다. 구버전에서 관측만 미지원인 경우에는 수동 시도를 허용한다.
- 성공 응답의 status와 auth_index를 검증한다. 대상 소멸, API 미지원, 인증 거부, 통신 실패, 잘못된 응답을 구별하고 실패한 POST를 자동 반복하지 않는다.
- 복구 및 재조회가 진행되는 동안 중복 요청을 막는다. 포트/서버 세대, 계정 삭제·비활성화·재로그인, 서버 준비 상태 변경 시 작업과 진단을 무효화한다. 이전 세대의 늦은 응답을 현재 진단으로 표시하지 않는다.
- 복구 종료 시 같은 세대에서 대기 중인 사용량 새로고침을 먼저 처리하고 자동 조회를 예약한다. 실패·취소 또는 성공 후 검증 조회 중에 대기한 수동 요청을 다음 polling 주기까지 미루지 않는다. 비동기 후속 처리 전후에도 세대를 확인한다.
- 해제 후 재조회에서 cooldown이 다시 관측되거나 상태를 확인하지 못한 경우를 별도로 안내한다. 기존 마지막 성공 사용량 캐시는 유지한다.

### Claude OAuth 재로그인

이 변경은 **Claude에만 적용**한다. 기존 Codex migration 경로는 변경하지 않는다.

업스트림은 Claude 인증 파일을 이메일 기반 이름에서 `claude-<identity SHA256 앞 8자리>-<email>.json`으로 변경한다. identity는 organization UUID 우선, 없으면 account UUID다. 새 파일 저장 후 legacy 파일을 삭제하기 때문에, 앱의 기존 다중 변경 방어가 정상 재로그인을 실패로 판단할 수 있었다.

대상 하나의 삭제와 canonical 파일 하나의 생성만 발생하고 이메일·organization/account identity·파일명이 일치할 때만 migration으로 허용한다. 다른 파일의 변경/삭제, 다른 조직/이메일, 잘못된 hash, identity 없는 모호한 변화는 거부한다. 새 credential을 원래 target ID로 옮기고 disabled/prefix를 복원해 앱의 profile 참조를 보존한다. 오류와 취소에는 기존 snapshot rollback 경로를 사용한다.

### Usage queue와 GPT-6 Astra 가격

- 선택적 `response_model`을 실제 가격 모델로 우선 사용한다. 누락/null/공백이면 요청 모델을 사용한다.
- provider/executor/auth_index/alias 기반 계정 매핑, accounting/schema version 2 검증과 OAuth 비용 집계 제외 정책은 유지한다.
- 미등록 응답 모델을 요청 모델의 가격으로 임의 대체하지 않는다.
- GPT-6 Astra의 입력 토큰 272,000 **초과**를 long context로 분류한다.
- 가격표 version은 2로 증가한다. 아래 가격은 USD/1M tokens 기준이다.

| Variant | 입력 | 캐시 읽기 | 캐시 쓰기 | 출력 |
|---|---:|---:|---:|---:|
| Standard | 10 | 1 | 12.5 | 50 |
| Standard long context | 20 | 2 | 25 | 75 |
| Priority | 20 | 2 | 25 | 100 |
| Priority long context | 40 | 4 | 50 | 150 |

공식 가격 확인일인 `2026-09-19T00:00:00Z`부터 새 epoch를 적용한다. 별도의 공식 적용 시작일을 확인하지 못했으므로 그 이전 기록에 소급 적용하지 않는다. 기존 가격 epoch와 ledger는 유지한다. 응답 service tier가 요청 tier보다 우선하며 `ultrafast` 요금은 추정하지 않는다.

출처:
- [GPT-6 Astra 모델 문서](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [OpenAI 가격표](https://developers.openai.com/api/docs/pricing)

### 기본 CLIProxyAPI 번들

기본 번들을 v7.2.152에서 **v7.3.8**로 갱신했다.

- Commit: `c93978c4`
- Built at: `2026-09-18T21:18:43Z`
- Darwin arm64 archive SHA256: `4676f94066fae3b10fc16c8d181e893ef40075257b2ce581202ab978381ce293`
- Binary SHA256: `195570a35172481b9240be02371d92c194a655c58e3516f373d77f92dbc71e46`
- Binary size: `62113762` bytes

공식 release checksum과 archive를 대조하고 binary의 architecture/hash/size/version을 확인했다. 기존 resolver의 hash-addressed 작업 디렉터리 캐시를 사용한다. 프로덕션 설치본과 캐시는 변경하지 않는다.

pagination 인자를 생략한 `auth-files` 전체 목록 호출은 유지한다. discovery는 기본 비활성화 상태를 유지하고, force-refresh/retry/affinity/cloaking/model-level-cooling 등의 옵션을 함께 활성화하지 않는다.

## 검증 방법과 안전 경계

- runtime 테스트는 별도 test port와 fake transport/launcher, 임시 경로를 사용한다.
- 실제 계정에 reset-quota나 reset-credit 요청을 보내지 않는다. 프로덕션 usage queue도 소비하지 않는다.
- 테스트·빌드 전후에 launchctl/PID/listening port를 읽기 전용으로 비교한다. 프로덕션 앱/서버의 실행·중지·재시작·signal 전송은 하지 않는다.
- 테스트 bundle의 FinderInfo 서명 오류를 피하기 위해 Swift scratch 경로는 `/tmp/cpm-upstream-swift-build`를 사용한다.

주요 자동 검증:

```sh
swift test --scratch-path /tmp/cpm-upstream-swift-build
bash Tests/ScriptTests/resolve-bundled-cliproxyapi-tests.sh
bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh
bash Tests/ScriptTests/verify-app-structure-tests.sh
git diff --check
```

전체 Swift 테스트는 `-Xswiftc -warnings-as-errors`를 추가한 설정에서 Core 725개와 App 863개, 합계 **1,588개가 통과**했다. 위 스크립트 테스트 3종과 `git diff --check`도 통과했다.

2026-09-20 리뷰 반영에서는 자동 polling을 진행시키지 않는 회귀 테스트 2개로 대기 요청의 지연을 먼저 재현했다. 복구 실패·취소 후 및 성공 후 검증 조회 중에 대기한 새로고침이 즉시 진단을 갱신하는지 확인했다. 수정 후 쿨다운 관련 13개 테스트와 전체 Swift 테스트가 통과했고 development bundle 생성·구조·무결성 검증도 다시 통과했다.

현재 Xcode의 기본 `swiftbuild` 엔진은 리소스 bundle 안에 `Contents/Resources`를 생성한다. 기존 Makefile은 flat 리소스 구조를 전제로 하므로 첫 development bundle 생성은 컴파일 후 `App structure validation failed: resource contents`에서 멈췄다. 이번 작업에서는 Makefile 변경으로 범위를 확대하지 않고 기존 패키징과 호환되는 `native` 모드를 명시한다. 이 모드는 현 도구에서 사용 가능하지만 deprecated 경고가 있으므로 빌드 엔진 전환 대응은 별도 후속 과제다.

Development bundle 재현 명령(현재 ARM64 환경):

```sh
make development-bundle BUILD_DIR=build-development \
  SWIFT_BUILD_FLAGS="--build-system native --scratch-path /tmp/cpm-upstream-swift-build -Xswiftc -warnings-as-errors" \
  SWIFT_BUILD_DIR=/tmp/cpm-upstream-swift-build/arm64-apple-macosx/debug \
  SPARKLE_FRAMEWORK=/tmp/cpm-upstream-swift-build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  CLIPROXYAPI_OFFLINE=1
```

`CLIPROXYAPI_OFFLINE=1`은 위 manifest에 맞는 바이너리가 작업 디렉터리의 `.build/cliproxyapi` 캐시에 검증·준비된 경우에 사용한다. 앱 실행이나 수동 UI 검증은 자동으로 수행하지 않는다.

위 명령은 exit 0으로 완료됐고 `App structure verification passed`를 확인했다. 산출물은 `build-development/CLIProxyManager.app`이며 앱 버전 0.1.42, build 45, development channel이다. 포함된 v7.3.8 manifest가 소스와 일치하고 바이너리 SHA256·크기가 manifest와 일치함도 별도로 확인했다. 패키징 과정의 `install_name_tool` 서명 무효화 경고는 남아 있으며, 배포용 서명·공증이나 앱 실행은 수행하지 않았다.

빌드 후 읽기 전용 확인에서도 프로덕션 앱 PID 2440, 서버 PID 66055, `127.0.0.1:18317` LISTEN 상태가 빌드 전과 동일했다.

## 사용자 수동 확인

1. Development 앱에서 계정 카드의 cooldown 상태와 관측 시각을 확인한다.
2. Codex의 외부 사용량 리셋이 실제로 적용된 뒤, 해당 활성 OAuth 계정의 `Clear quota cooldown…` 확인 대화상자를 확인한다.
3. 해제 전후 서버 PID가 유지되는지, 재조회 결과가 cooldown 없음/재차 제한/확인 불가 중 무엇인지 확인한다.
4. 다음 실제 Codex 요청이 정상 처리되는지 확인한다. 공급자 quota가 여전히 없으면 다시 제한될 수 있다.
5. Claude 재로그인 후 계정 ID, nickname/명령 참조, disabled/prefix가 유지되는지 확인한다.
6. API-key 사용 기록에서 실제 응답 모델과 tier에 맞는 비용이 표시되는지 확인한다.

자동 테스트는 로컬 복구 요청 계약과 앱 동작을 검증하며, 실계정의 외부 quota 회복 자체를 검증한 것은 아니다. 초기 구현 이후 사용자 승인으로 [PR #174](https://github.com/woosublee/CLIProxyManager/pull/174)를 등록하고 리뷰 지적을 반영한다. 머지·릴리스·프로덕션 배포는 포함하지 않는다.
