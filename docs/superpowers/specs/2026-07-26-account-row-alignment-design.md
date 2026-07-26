# 메인 계정 카드 내부 정렬 개선 설계

**작성일:** 2026-07-26
**상태:** 설계 승인

## 문제

메인 계정 카드의 프로바이더 아이콘이 카드 콘텐츠 기준으로 상하 중앙에 정렬되지 않고 위쪽으로 치우쳐 보인다. 계정명과 그 아래 계정 이메일·상태 상세정보 사이의 간격도 다른 조밀한 요소들에 비해 넓다.

최근 command badge와 account actions를 계정명 줄로 이동하면서 첫째 줄 높이가 26pt action control 기준으로 커졌지만, 바깥 컨테이너는 여전히 `HStack(alignment: .top)`을 사용한다. drag handle만 별도로 전체 높이의 가운데에 배치되고 32pt `ProviderAvatar`는 top alignment를 그대로 따르는 것이 아이콘 정렬 문제의 원인이다.

계정 정보 `VStack`은 4pt spacing을 사용하며 `accountDetailRow`에 2pt 상단 padding을 추가한다. 따라서 계정명과 상세정보의 실질 간격은 6pt가 되어 의도보다 넓다.

## 목표

- 32pt 프로바이더 아이콘을 카드 내부 콘텐츠 높이 기준으로 상하 중앙 정렬한다.
- 계정명과 이메일·상태 상세정보의 실질 간격을 2pt로 줄인다.
- 카드의 바깥 세로 padding과 전체 높이는 유지한다.
- 계정명, command badge, HUD·설정·더보기 action의 현재 배치와 동작은 유지한다.

## 비목표

- 메인 창 폭이나 계정 수에 따른 창 높이 계산을 변경하지 않는다.
- drag handle, drag preview, Add provider 카드의 정렬을 변경하지 않는다.
- 프로바이더 아이콘 크기·모양·이미지 리소스를 변경하지 않는다.
- 계정 privacy, status, command 복사, account action 동작을 변경하지 않는다.

## 레이아웃

바깥 계정 카드 `HStack`의 top alignment는 유지한다. 계정명과 우측 controls의 현재 수직 위치를 보존하기 위해 컨테이너 전체를 center alignment로 바꾸지 않는다.

`ProviderAvatar`에 drag handle과 동일한 전체 높이 중앙 정렬 frame을 적용한다. 이렇게 하면 프로바이더 아이콘만 카드의 실제 콘텐츠 높이를 기준으로 중앙에 배치되고, 제목·상세정보·trailing controls에는 불필요한 이동이 발생하지 않는다.

계정 정보 `VStack`의 spacing을 2pt로 줄이고 `accountDetailRow`의 추가 2pt 상단 padding을 제거한다. 두 텍스트 행 사이의 간격은 하나의 spacing 값만 소유하게 하여 실질 2pt가 되도록 한다.

```text
[drag: center] [avatar: center] [계정명                   command/actions]
                               [status · 이메일]
```

## 구성요소 변경

### `ProviderAccountCardView`

- `ProviderAvatar`를 카드 콘텐츠 높이의 가운데에 배치한다.
- 계정 정보 `VStack` spacing을 2pt로 조정한다.
- `accountDetailRow`의 별도 상단 padding을 제거한다.
- 카드의 `.padding(.vertical, 10)`과 `.padding(.horizontal, 12)`는 유지한다.

### `ProviderAccountDragPreview`

변경하지 않는다. drag preview는 action controls가 없는 별도 레이아웃이며 현재 가운데 정렬 `HStack`이 이미 아이콘을 적절히 배치한다.

## 테스트

기존 source-contract UI 테스트 관례에 맞춰 다음 회귀 계약을 추가한다.

1. 메인 계정 카드의 `ProviderAvatar`가 전체 높이 중앙 정렬 frame을 가져야 한다.
2. 계정 정보 `VStack`은 2pt spacing을 사용해야 한다.
3. `accountDetailRow`에 중복 상단 padding이 없어야 한다.
4. 기존 command badge 단일 행과 계정 상세정보 가시성 렌더링 테스트가 계속 통과해야 한다.

## 자동 검증

1. 계정 카드 내부 정렬 회귀 테스트
2. `DashboardCommandBadgeLayoutUITests`
3. 전체 `swift test`
4. `CONFIGURATION=debug` development app bundle build 및 codesign verification

production 앱은 실행·종료·활성화하지 않는다. development 앱 실행과 수동 UI 확인은 사용자가 담당한다.
