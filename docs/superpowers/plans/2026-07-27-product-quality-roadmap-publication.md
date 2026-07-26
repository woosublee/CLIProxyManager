# Product Quality Roadmap Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 승인된 2026 H2 제품 품질 로드맵을 `woosublee/CLIProxyManager` GitHub 저장소에 5개 milestone, 23개 label, 34개 신규 issue와 기존 Issue #18 업데이트로 게시하고 전체 35개 항목을 실제 issue 번호로 연결한다.

**Architecture:** 승인된 설계 문서를 단일 입력으로 사용해 임시 publication manifest와 issue body를 생성한다. 모든 원격 변경은 dry-run과 중복 검사를 먼저 수행하고, label → milestone → 기존 Issue #18 → M1 → M2 → M3 → M4 → Opportunity Validation → tracking issue 순으로 적용한다. 각 issue에는 안정적인 `roadmap-id:RNN` HTML marker를 넣어 재실행을 idempotent하게 만들고, 생성 완료 후 두 번째 pass에서 실제 issue 번호로 dependency와 tracking link를 갱신한다.

**Tech Stack:** GitHub CLI `gh`, GitHub REST API, Python 3 표준 라이브러리, zsh/Bash, Markdown

## Global Constraints

- 대상 저장소는 public personal repository `woosublee/CLIProxyManager`다.
- 개인 프로젝트이므로 GitHub에만 등록하며 Notion에는 기록하지 않는다.
- 설계 원본은 `docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md`다.
- 전체 추적 항목은 정확히 35개다: 신규 issue 34개와 기존 Issue #18 1개.
- 기존 Issue #18의 원문은 보존하고 roadmap context만 추가한다.
- 기존 기본 label은 삭제하거나 의미를 변경하지 않는다.
- 생성·수정 전 exact title, `roadmap-id` marker, milestone title로 중복을 검사한다.
- 각 remote mutation 직후 반환된 URL·number를 로컬 mapping에 기록한다.
- Partial failure 시 이미 생성된 issue를 삭제하지 않고 idempotent하게 재개한다.
- User-facing issue body와 label 설명은 한국어로 작성하되 code identifier와 고유 명사는 원문을 유지한다.
- Secret, email, account ID, local absolute path를 GitHub issue body에 기록하지 않는다.
- Public test·document 예시가 필요하면 `example.com` 식별자를 사용한다.
- 이 계획은 roadmap 게시만 수행하며 제품 기능 코드를 구현하지 않는다.

---

## File and Remote Resource Map

### Local files

- Read: `docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/manifest.json`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/render_issue_bodies.py`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/publish.py`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/issues/R01.md` through `R35.md`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/mapping.json`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/remote-before.json`
- Create temporarily: `/tmp/cliproxymanager-roadmap-2026/remote-after.json`

### GitHub resources

- Create: 23 roadmap labels
- Create: 5 milestones
- Modify: Issue #18
- Create: R02–R10, R12–R35 and R01 tracking issue, 총 34개
- Update: 생성된 모든 roadmap issue의 dependency·tracking links

## Publication Manifest

### Milestones

| Key | Title | Due date | Description |
|---|---|---:|---|
| M1 | `M1 — Release Truth & Safety` | 2026-08-23 | 설정과 runtime의 일치, CI, version, supply-chain 기준을 확립한다. |
| M2 | `M2 — Trusted Install & First Command` | 2026-10-04 | 공증 설치, readiness, account 연결과 첫 command 성공을 보장한다. |
| M3 | `M3 — Diagnosis, Recovery & Safe Change` | 2026-11-22 | Doctor, diagnostics, credential recovery, safe change, automatic rollback을 제공한다. |
| M4 | `M4 — Daily Confidence & Decision Support` | 2027-01-10 | Usage 알림, quick action, routing 설명, 성능·접근성 기준을 제공한다. |
| VALIDATION | `Opportunity Validation` | 없음 | 6개월 이후 후보의 사용자 수요와 foundation 진입 조건을 검증한다. |

GitHub API `due_on` 값은 각 날짜의 `23:59:59Z`를 사용한다. `Opportunity Validation`에는 `due_on`을 보내지 않는다.

### Labels

| Name | Color | Description |
|---|---|---|
| `type: product` | `0E8A16` | 사용자에게 직접 전달되는 제품 기능·경험 |
| `type: foundation` | `5319E7` | 기능의 신뢰성·유지보수성을 지탱하는 기반 작업 |
| `type: security` | `B60205` | Credential, privacy, supply-chain, 배포 신뢰 작업 |
| `type: discovery` | `FBCA04` | 사용자 수요와 구현 진입 조건을 검증하는 조사 |
| `area: onboarding` | `1D76DB` | 설치, readiness, 첫 성공 여정 |
| `area: account` | `0052CC` | Account profile, auth, credential lifecycle |
| `area: proxy` | `006B75` | CLIProxyAPI runtime과 network binding |
| `area: shell` | `0366D6` | Shell function, helper, terminal integration |
| `area: usage` | `0B7285` | Quota, API cost, usage state와 forecast |
| `area: routing` | `6F42C1` | Model, reasoning, context, account routing |
| `area: update` | `D93F0B` | App·proxy update와 rollback |
| `area: release` | `C24E00` | CI, signing, packaging, release process |
| `area: diagnostics` | `BFD4F2` | Logs, error code, doctor, support bundle |
| `area: accessibility` | `D4C5F9` | VoiceOver, keyboard, Reduce Motion |
| `area: architecture` | `C5DEF5` | State ownership, coordinator boundary, compatibility |
| `priority: P0` | `B60205` | 사용자 신뢰·보안·배포를 즉시 위협하는 작업 |
| `priority: P1` | `D93F0B` | 현재 milestone의 핵심 사용자 결과 |
| `priority: P2` | `FBCA04` | 중요하지만 선행 기반 이후 진행하는 작업 |
| `priority: validation` | `FEF2C0` | 수요 검증 전 production 구현 금지 |
| `impact: TTFC` | `1D76DB` | Time to First Command 개선 |
| `impact: MTTR` | `5319E7` | Mean Time to Recovery 개선 |
| `impact: reliability` | `0E8A16` | 예측 가능성·일관성·release 안정성 개선 |
| `impact: privacy` | `B60205` | Secret·개인정보 노출 위험 감소 |

### Issue metadata

| ID | Existing | Milestone | Title | Labels | Dependencies |
|---|---:|---|---|---|---|
| R01 | no | none | `[Roadmap] CLIProxyManager Product Quality Roadmap — 2026 H2` | `type: product`, `priority: P0`, `impact: reliability` | R02–R35 |
| R02 | no | M1 | `Bind address를 실제 proxy runtime에 반영` | `type: foundation`, `area: proxy`, `priority: P0`, `impact: reliability` | 없음 |
| R03 | no | M1 | `Log level을 app·proxy logging에 연결` | `type: foundation`, `area: diagnostics`, `priority: P0`, `impact: reliability` | 없음 |
| R04 | no | M1 | `Version/build number의 단일 진실 공급원 확립` | `type: foundation`, `area: release`, `priority: P0`, `impact: reliability` | 없음 |
| R05 | no | M1 | `PR/push CI와 main required checks 구성` | `type: foundation`, `area: release`, `priority: P0`, `impact: reliability` | R04 |
| R06 | no | M1 | `Test fixture 격리와 flaky test budget 도입` | `type: foundation`, `area: architecture`, `priority: P1`, `impact: reliability` | R05 |
| R07 | no | M1 | `지원 환경과 architecture compatibility 명시` | `type: product`, `area: onboarding`, `area: release`, `priority: P0`, `impact: TTFC` | 없음 |
| R08 | no | M1 | `GitHub Actions·dependency supply-chain 기준 강화` | `type: security`, `area: release`, `priority: P1`, `impact: reliability` | R05 |
| R09 | no | M2 | `Developer ID 서명·공증·stapling 도입` | `type: security`, `area: release`, `priority: P0`, `impact: TTFC` | R04, R05, R08 |
| R10 | no | M2 | `Packaging·install·update smoke test 자동화` | `type: foundation`, `area: release`, `area: update`, `priority: P1`, `impact: reliability` | R04, R05, R09 |
| R11 | #18 | M2 | `Refactor account settings into profile lifecycle storage` | preserve `enhancement`; add `type: foundation`, `area: account`, `area: architecture`, `priority: P0`, `impact: TTFC` | 없음 |
| R12 | no | M2 | `Guided readiness onboarding 구현` | `type: product`, `area: onboarding`, `priority: P1`, `impact: TTFC` | R07, R13 |
| R13 | no | M2 | `기본 command 추천·preflight·새 Terminal 열기` | `type: product`, `area: onboarding`, `area: shell`, `priority: P1`, `impact: TTFC` | R11 |
| R14 | no | M2 | `인증·model loading 실패 복구 UX 완성` | `type: product`, `area: account`, `priority: P1`, `impact: TTFC` | R11 |
| R15 | no | M3 | `Structured logging과 stable error code 도입` | `type: foundation`, `area: diagnostics`, `priority: P1`, `impact: MTTR` | R03 |
| R16 | no | M3 | `Redacted diagnostics bundle 제공` | `type: security`, `area: diagnostics`, `priority: P1`, `impact: privacy` | R15 |
| R17 | no | M3 | `cpm doctor 진단 엔진 구현` | `type: product`, `area: diagnostics`, `priority: P1`, `impact: MTTR` | R07, R15 |
| R18 | no | M3 | `Reversible repair와 one-click recovery 제공` | `type: product`, `area: diagnostics`, `priority: P1`, `impact: MTTR` | R17, R21 |
| R19 | no | M3 | `Credential health와 설정 보존 재인증` | `type: product`, `area: account`, `priority: P1`, `impact: MTTR` | R11, R15 |
| R20 | no | M3 | `Keychain 기본 저장과 secret migration` | `type: security`, `area: account`, `priority: P1`, `impact: privacy` | R11, R19 |
| R21 | no | M3 | `설정 변경 preview·영향 표시·undo` | `type: product`, `area: routing`, `priority: P1`, `impact: reliability` | R04, R11 |
| R22 | no | M3 | `CLIProxyAPI update health check·automatic rollback` | `type: foundation`, `area: update`, `area: proxy`, `priority: P0`, `impact: MTTR` | R04, R05, R10 |
| R23 | no | M3 | `App update health check·automatic rollback·result history` | `type: foundation`, `area: update`, `priority: P0`, `impact: MTTR` | R04, R05, R09, R10, R15 |
| R24 | no | M4 | `Usage 데이터 freshness·source·incomplete 상태 계약 통일` | `type: foundation`, `area: usage`, `priority: P1`, `impact: reliability` | R15 |
| R25 | no | M4 | `Quota reset·usage threshold·API budget 알림` | `type: product`, `area: usage`, `priority: P1`, `impact: reliability` | R15, R24 |
| R26 | no | M4 | `Menu bar account quick action` | `type: product`, `area: account`, `priority: P1`, `impact: TTFC` | R13, R19, R24 |
| R27 | no | M4 | `Effective route 설명과 routing preset` | `type: product`, `area: routing`, `priority: P1`, `impact: reliability` | R11, R21 |
| R28 | no | M4 | `App performance budget과 regression 측정` | `type: foundation`, `area: architecture`, `priority: P2`, `impact: reliability` | R05 |
| R29 | no | M4 | `Accessibility release gate` | `type: product`, `area: accessibility`, `priority: P1`, `impact: TTFC` | R12, R26, R27 |
| R30 | no | M4 | `7/30일 usage history·forecast beta` | `type: product`, `area: usage`, `priority: P2`, `impact: reliability` | R24 |
| R31 | no | M4 | `핵심 coordinator 책임 분리 완료` | `type: foundation`, `area: architecture`, `priority: P1`, `impact: reliability` | R06, R11, R15 |
| R32 | no | VALIDATION | `설정 이동성과 shell 확장 기회 검증` | `type: discovery`, `area: shell`, `priority: validation`, `impact: TTFC` | R11, R13 |
| R33 | no | VALIDATION | `고급 usage·account 의사결정 기능 검증` | `type: discovery`, `area: usage`, `area: account`, `priority: validation`, `impact: reliability` | R24, R30 |
| R34 | no | VALIDATION | `Localization과 배포 접근성 검증` | `type: discovery`, `area: onboarding`, `area: release`, `priority: validation`, `impact: TTFC` | R09, R12, R29 |
| R35 | no | VALIDATION | `Provider 확장 진입 조건 검증` | `type: discovery`, `area: account`, `area: routing`, `priority: validation`, `impact: reliability` | R07, R08, R11, R22, R23, R31 |

## Common Issue Body Contract

R02–R35 body는 설계 문서의 해당 `#### RNN.` section을 source로 사용하고 다음 구조로 게시한다.

```markdown
<!-- roadmap-id:RNN -->

## 사용자 문제

[설계 문서 RNN section의 첫 설명 문단]

## 기대 결과

[설계 문서 RNN section의 요구 결과와 milestone exit condition 중 이 이슈에 해당하는 내용]

## Acceptance criteria

- [ ] 이 이슈의 설계 요구사항이 자동 검증 가능한 형태로 구현된다.
- [ ] 실패 시 기존 정상 account·shell·config·proxy 상태를 보존하거나 rollback한다.
- [ ] `loading`, `degraded`, `stale`, `unavailable` 중 관련 상태를 구분한다.
- [ ] User-facing error에는 원인, 영향, recovery action이 포함된다.
- [ ] Secret·email·prompt가 log, diagnostics, JSON output, test fixture에 포함되지 않는다.
- [ ] 필요한 unit·integration·script test와 development build 검증을 완료한다.
- [ ] 관련 README·troubleshooting·release note를 갱신한다.

## 검증

- 자동: 이슈별 unit·integration·script test와 development build
- 수동: 앱 실행 또는 UI 확인이 필요한 경우 release checklist에 검증 절차 기록

## 성공 지표

- Primary impact: `impact: ...`
- Milestone exit condition에 미친 결과를 완료 시 comment로 기록

## 의존성

- 선행: RXX, RYY
- 후속: publication second pass에서 실제 issue link로 갱신

## Roadmap

- Milestone: `...`
- Tracking issue: publication second pass에서 실제 issue link로 갱신
- Design: `docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md`
```

공통 acceptance criteria가 실제 이슈 요구와 맞지 않는 경우 다음 규칙을 적용한다.

- `type: discovery`: 구현·build 항목 대신 인터뷰 표본, evidence, go/no-go decision, 분리된 후속 구현 이슈를 요구한다.
- `type: security`: threat model, migration, downgrade, redaction, permission 검증을 추가한다.
- `area: release` 또는 `area: update`: artifact verification, health check, rollback을 추가한다.
- `area: accessibility`: VoiceOver, Full Keyboard Access, Reduce Motion 검증을 추가한다.
- `area: usage`: source, freshness, data gap, estimate disclosure를 추가한다.

---

### Task 1: Capture and verify the remote baseline

**Files:**
- Read: `docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md`
- Create: `/tmp/cliproxymanager-roadmap-2026/remote-before.json`

**Interfaces:**
- Consumes: authenticated `gh` session with write access to `woosublee/CLIProxyManager`
- Produces: immutable baseline snapshot used by duplicate and post-publication checks

- [ ] **Step 1: Verify repository identity and authentication**

Run:

```bash
gh auth status
gh repo view woosublee/CLIProxyManager --json nameWithOwner,url,defaultBranchRef,isPrivate
```

Expected:

- Authenticated GitHub account has write access.
- `nameWithOwner` is exactly `woosublee/CLIProxyManager`.
- Default branch is `main`.

- [ ] **Step 2: Create the temporary publication directory**

Run:

```bash
rm -rf /tmp/cliproxymanager-roadmap-2026
mkdir -p /tmp/cliproxymanager-roadmap-2026/issues
```

Expected: empty publication directory exists.

- [ ] **Step 3: Capture labels, milestones, and issues**

Run:

```bash
python3 - <<'PY'
import json, subprocess
from pathlib import Path

def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True))

snapshot = {
    "repo": gh("repo", "view", "woosublee/CLIProxyManager", "--json", "nameWithOwner,url,defaultBranchRef,isPrivate"),
    "labels": gh("label", "list", "--repo", "woosublee/CLIProxyManager", "--limit", "200", "--json", "name,color,description"),
    "issues": gh("issue", "list", "--repo", "woosublee/CLIProxyManager", "--state", "all", "--limit", "200", "--json", "number,title,state,labels,milestone,url"),
}
raw = subprocess.check_output([
    "gh", "api", "repos/woosublee/CLIProxyManager/milestones?state=all&per_page=100"
], text=True)
snapshot["milestones"] = json.loads(raw)
Path("/tmp/cliproxymanager-roadmap-2026/remote-before.json").write_text(
    json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n"
)
PY
```

Expected:

- Milestone list is empty at the captured baseline.
- Only Issue #18 is open and overlaps the roadmap.
- No issue body is modified in this task.

- [ ] **Step 4: Re-read Issue #18 immediately before planning its update**

Run:

```bash
gh issue view 18 --repo woosublee/CLIProxyManager \
  --json number,title,body,state,labels,milestone,url \
  > /tmp/cliproxymanager-roadmap-2026/issue-18-before.json
```

Expected title: `Refactor account settings into profile lifecycle storage`.

---

### Task 2: Build and validate the publication bundle

**Files:**
- Create: `/tmp/cliproxymanager-roadmap-2026/manifest.json`
- Create: `/tmp/cliproxymanager-roadmap-2026/render_issue_bodies.py`
- Create: `/tmp/cliproxymanager-roadmap-2026/publish.py`
- Create: `/tmp/cliproxymanager-roadmap-2026/issues/R01.md` through `R35.md`

**Interfaces:**
- Consumes: exact Milestones, Labels, Issue metadata tables and Common Issue Body Contract in this plan
- Produces: validated `manifest.json`, 35 deterministic Markdown bodies, idempotent publisher CLI

- [ ] **Step 1: Create the exact JSON manifest**

Use the Write tool to create `manifest.json` by transcribing every row from the three publication tables above. Use this exact schema:

```json
{
  "repo": "woosublee/CLIProxyManager",
  "labels": [
    {"name": "type: product", "color": "0E8A16", "description": "사용자에게 직접 전달되는 제품 기능·경험"}
  ],
  "milestones": [
    {
      "key": "M1",
      "title": "M1 — Release Truth & Safety",
      "description": "설정과 runtime의 일치, CI, version, supply-chain 기준을 확립한다.",
      "due_on": "2026-08-23T23:59:59Z"
    }
  ],
  "issues": [
    {
      "id": "R01",
      "title": "[Roadmap] CLIProxyManager Product Quality Roadmap — 2026 H2",
      "milestone_key": null,
      "labels": ["type: product", "priority: P0", "impact: reliability"],
      "dependencies": ["R02", "R03", "R04", "R05", "R06", "R07", "R08", "R09", "R10", "R11", "R12", "R13", "R14", "R15", "R16", "R17", "R18", "R19", "R20", "R21", "R22", "R23", "R24", "R25", "R26", "R27", "R28", "R29", "R30", "R31", "R32", "R33", "R34", "R35"],
      "existing_number": null,
      "body_file": "/tmp/cliproxymanager-roadmap-2026/issues/R01.md"
    },
    {
      "id": "R11",
      "title": "Refactor account settings into profile lifecycle storage",
      "milestone_key": "M2",
      "labels": ["enhancement", "type: foundation", "area: account", "area: architecture", "priority: P0", "impact: TTFC"],
      "dependencies": [],
      "existing_number": 18,
      "body_file": "/tmp/cliproxymanager-roadmap-2026/issues/R11.md"
    }
  ]
}
```

The two issue objects above demonstrate the exact field names. The final arrays must contain all 23 labels, 5 milestones, and R01–R35 in numeric order. Do not abbreviate dependencies or omit labels from the metadata table.

- [ ] **Step 2: Validate the manifest before rendering bodies**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
m = json.loads(Path('/tmp/cliproxymanager-roadmap-2026/manifest.json').read_text())
expected = [f'R{i:02d}' for i in range(1, 36)]
ids = [x['id'] for x in m['issues']]
assert m['repo'] == 'woosublee/CLIProxyManager'
assert len(m['labels']) == 23
assert len({x['name'] for x in m['labels']}) == 23
assert len(m['milestones']) == 5
assert {x['key'] for x in m['milestones']} == {'M1', 'M2', 'M3', 'M4', 'VALIDATION'}
assert ids == expected
assert len({x['title'] for x in m['issues']}) == 35
assert sum(x.get('existing_number') is None for x in m['issues']) == 34
assert [x for x in m['issues'] if x.get('existing_number') == 18][0]['id'] == 'R11'
for item in m['issues']:
    assert set(item['dependencies']) <= set(expected), item['id']
    assert item['body_file'].endswith(f"/{item['id']}.md")
print('manifest valid: 23 labels, 5 milestones, 35 tracked items, 34 creates, issue #18 reused')
PY
```

Expected output:

```text
manifest valid: 23 labels, 5 milestones, 35 tracked items, 34 creates, issue #18 reused
```

- [ ] **Step 3: Write the deterministic issue-body renderer**

Create `render_issue_bodies.py` with this complete rendering flow:

```python
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path('/tmp/cliproxymanager-roadmap-2026')
SPEC = Path('docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md')
MANIFEST = ROOT / 'manifest.json'
ISSUE_DIR = ROOT / 'issues'

DELIVERY_CHECKS = [
    '이 이슈의 설계 요구사항이 자동 검증 가능한 형태로 구현된다.',
    '실패 시 기존 정상 account·shell·config·proxy 상태를 보존하거나 rollback한다.',
    '`loading`, `degraded`, `stale`, `unavailable` 중 관련 상태를 구분한다.',
    'User-facing error에는 원인, 영향, recovery action이 포함된다.',
    'Secret·email·prompt가 log, diagnostics, JSON output, test fixture에 포함되지 않는다.',
    '필요한 unit·integration·script test와 development build 검증을 완료한다.',
    '관련 README·troubleshooting·release note를 갱신한다.',
]

DISCOVERY_CHECKS = [
    'User evidence source와 sample size를 기록한다.',
    '현재 JTBD와 대안 제품·workflow를 문서화한다.',
    'Privacy, maintenance, support 비용을 추정한다.',
    'Go/no-go decision과 production 진입 조건을 기록한다.',
    'Go이면 별도 implementation issue를 만들고 이 discovery issue에 연결한다.',
]

SPECIAL_CHECKS = {
    'type: security': [
        'Threat model과 secret·개인정보 data flow를 기록한다.',
        'Migration failure와 downgrade 또는 rollback을 검증한다.',
    ],
    'area: release': [
        'Artifact identity, signature, version, compatibility를 검증한다.',
    ],
    'area: update': [
        '새 version health 확인 전 previous artifact를 보존한다.',
    ],
    'area: accessibility': [
        'VoiceOver, Full Keyboard Access, Reduce Motion을 검증한다.',
    ],
    'area: usage': [
        'Source, freshness, data gap, estimate 여부를 사용자에게 표시한다.',
    ],
}


def sections(text: str) -> dict[str, tuple[str, str]]:
    matches = list(re.finditer(r'^#### (R\d{2})\. (.+)$', text, re.MULTILINE))
    result: dict[str, tuple[str, str]] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        result[match.group(1)] = (match.group(2).strip(), text[match.end():end].strip())
    return result


def render(item: dict, requirement: str) -> str:
    marker = f"<!-- roadmap-id:{item['id']} -->"
    if item['id'] == 'R01':
        return f"{marker}\n\n{requirement}\n"
    checks = list(DISCOVERY_CHECKS if 'type: discovery' in item['labels'] else DELIVERY_CHECKS)
    for label, extra in SPECIAL_CHECKS.items():
        if label in item['labels']:
            checks.extend(extra)
    acceptance = '\n'.join(f'- [ ] {check}' for check in dict.fromkeys(checks))
    dependencies = item['dependencies'] or ['없음']
    dependency_lines = '\n'.join(f'- {value}' for value in dependencies)
    milestone = item['milestone_key'] or '없음'
    return f'''{marker}

## 사용자 문제와 기대 결과

{requirement}

## Acceptance criteria

{acceptance}

## 검증

- 자동: 관련 unit·integration·script test와 development build
- 수동: 앱 실행 또는 UI 확인이 필요한 경우 release checklist에 절차 기록

## 성공 지표

- Primary impact: `{next(label for label in item['labels'] if label.startswith('impact: '))}`
- Milestone exit condition에 미친 결과를 완료 comment로 기록

## 의존성

{dependency_lines}

실제 GitHub issue link는 publication second pass에서 갱신한다.

## Roadmap

- Milestone key: `{milestone}`
- Tracking issue: publication second pass에서 갱신
- Design: `docs/superpowers/specs/2026-07-27-product-quality-roadmap-design.md`
'''


def main() -> None:
    manifest = json.loads(MANIFEST.read_text())
    extracted = sections(SPEC.read_text())
    assert list(extracted) == [f'R{i:02d}' for i in range(1, 36)]
    ISSUE_DIR.mkdir(parents=True, exist_ok=True)
    for item in manifest['issues']:
        title, requirement = extracted[item['id']]
        normalized_title = title.replace('`', '')
        if item['id'] == 'R11':
            assert normalized_title.startswith('기존 Issue #18 — account profile lifecycle')
        else:
            assert normalized_title == item['title'], (item['id'], normalized_title, item['title'])
        Path(item['body_file']).write_text(render(item, requirement))


if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Write the idempotent publisher CLI**

Create `publish.py` with this exact command contract:

```text
publish.py labels (--dry-run | --apply | --verify)
publish.py milestones (--dry-run | --apply | --verify)
publish.py issues --phase {M1,M2,M3,M4,VALIDATION} (--dry-run | --apply | --verify)
publish.py links (--dry-run | --apply | --verify)
publish.py audit
```

Required implementation behavior:

- Load `manifest.json` and merge state into `mapping.json` after every successful mutation.
- Execute `gh` with `subprocess.run(..., check=True, text=True, capture_output=True)`.
- Read labels with `gh label list --repo woosublee/CLIProxyManager --limit 200 --json name,color,description`.
- Read milestones with `gh api repos/woosublee/CLIProxyManager/milestones?state=all&per_page=100`.
- Read the issue list with `gh api repos/woosublee/CLIProxyManager/issues?state=all&per_page=100` only for pre-create duplicate detection and ignore objects containing `pull_request`.
- After a create or update, verify each issue through `GET /repos/woosublee/CLIProxyManager/issues/{number}` using the number persisted in `mapping.json`; do not rely on the eventually consistent list endpoint for read-after-write verification.
- Identify roadmap issues by exact `<!-- roadmap-id:RNN -->` marker before exact title.
- Treat an exact title without the expected marker as a conflict and exit nonzero.
- Create labels with `gh label create ... --force`; never delete labels.
- Create milestones with `POST /repos/woosublee/CLIProxyManager/milestones`; reuse exact-title milestones after verifying description and due date.
- Create issues with JSON payload containing title, body, label names, and mapped milestone number.
- Persist `{number, url, existing}` under `mapping.json.issues[RNN]` immediately after each create.
- `--dry-run` must print actions without remote mutation or mapping changes.
- `--verify` must compare every relevant remote field with the manifest and exit nonzero on mismatch.
- `links --apply` must preserve existing body content while replacing raw dependency IDs with mapped `#number — title` links and adding the R01 tracking link.
- `audit` must emit the exact count assertions from Task 12 as JSON and exit nonzero if any assertion fails.

Use this mapping schema:

```json
{
  "milestones": {
    "M1": {"number": 1, "url": "https://github.com/woosublee/CLIProxyManager/milestone/1", "title": "M1 — Release Truth & Safety"}
  },
  "issues": {
    "R11": {"number": 18, "url": "https://github.com/woosublee/CLIProxyManager/issues/18", "existing": true}
  }
}
```

- [ ] **Step 5: Render and scan all issue bodies**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/render_issue_bodies.py
find /tmp/cliproxymanager-roadmap-2026/issues -name 'R*.md' -type f | wc -l
```

Expected file count: 35.

Run the red-flag scan:

```bash
if rg --pcre2 -n '\b(TODO|FIXME|PLACEHOLDER)\b|(^|[^A-Za-z])TBD([^A-Za-z]|$)|/Users/|[A-Za-z0-9._%+-]+@(?!example\.com)' \
  /tmp/cliproxymanager-roadmap-2026/issues; then
  exit 1
fi
```

Expected: no matches.

- [ ] **Step 6: Print dry-run publication order**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
m = json.loads(Path('/tmp/cliproxymanager-roadmap-2026/manifest.json').read_text())
for phase in ['M1', 'M2', 'M3', 'M4', 'VALIDATION', None]:
    print(f'[{phase or "TRACKING"}]')
    for item in m['issues']:
        if item['milestone_key'] == phase:
            action = f"update #{item['existing_number']}" if item.get('existing_number') else 'create'
            print(item['id'], action, item['title'])
PY
```

Expected phase order는 dependency topological sort를 따른다. 주요 재정렬은 M2의 R13→R12, M3의 R21→R18이며, phase 순서는 M1→M2→M3→M4→VALIDATION→R01이다.

---

### Task 3: Create or normalize roadmap labels

**Files:**
- Read: `/tmp/cliproxymanager-roadmap-2026/manifest.json`
- Modify remote: GitHub labels

**Interfaces:**
- Consumes: 23 label definitions
- Produces: all issue creation calls can reference stable label names

- [ ] **Step 1: Run a label dry-run diff**

Use Python to compare manifest labels to `gh label list`. Print `create`, `update-description/color`, `unchanged`. Do not delete any label.

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py labels --dry-run
```

Expected: 23 roadmap labels are reported as create unless they appeared after baseline capture.

- [ ] **Step 2: Create labels idempotently**

For each manifest label run the equivalent of:

```bash
gh label create 'type: product' --repo woosublee/CLIProxyManager \
  --color 0E8A16 \
  --description '사용자에게 직접 전달되는 제품 기능·경험' \
  --force
```

`--force` is allowed only for the 23 roadmap labels in the manifest. Existing default labels are untouched.

- [ ] **Step 3: Verify labels**

Run:

```bash
gh label list --repo woosublee/CLIProxyManager --limit 200 --json name,color,description \
  > /tmp/cliproxymanager-roadmap-2026/labels-after.json
python3 /tmp/cliproxymanager-roadmap-2026/publish.py labels --verify
```

Expected: all 23 names, colors, descriptions match the manifest.

---

### Task 4: Create milestones

**Files:**
- Read: `/tmp/cliproxymanager-roadmap-2026/manifest.json`
- Modify remote: GitHub milestones
- Update: `/tmp/cliproxymanager-roadmap-2026/mapping.json`

**Interfaces:**
- Consumes: exact milestone titles and due dates
- Produces: `mapping.json.milestones[key] = {number, url, title}`

- [ ] **Step 1: Dry-run milestone creation**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py milestones --dry-run
```

Expected: 5 creates, or exact-title reuse if another process created one.

- [ ] **Step 2: Create milestones by exact title**

Use `POST /repos/woosublee/CLIProxyManager/milestones` with JSON payload. Example:

```json
{
  "title": "M1 — Release Truth & Safety",
  "state": "open",
  "description": "설정과 runtime의 일치, CI, version, supply-chain 기준을 확립한다.",
  "due_on": "2026-08-23T23:59:59Z"
}
```

If an exact-title milestone exists, verify its description and due date, then use its number instead of creating a duplicate.

- [ ] **Step 3: Record and verify milestone numbers**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py milestones --verify
```

Expected: mapping has M1, M2, M3, M4, VALIDATION with unique GitHub milestone numbers.

---

### Task 5: Align existing Issue #18 as R11

**Files:**
- Read: `/tmp/cliproxymanager-roadmap-2026/issue-18-before.json`
- Read: `/tmp/cliproxymanager-roadmap-2026/issues/R11.md`
- Modify remote: GitHub Issue #18
- Update: `/tmp/cliproxymanager-roadmap-2026/mapping.json`

**Interfaces:**
- Consumes: existing Issue #18 body and R11 roadmap appendix
- Produces: R11→#18 mapping; Issue #18 assigned to M2 with roadmap labels

- [ ] **Step 1: Verify the target still matches**

Run:

```bash
gh issue view 18 --repo woosublee/CLIProxyManager --json title,state,body,labels,milestone
```

Expected:

- State is `OPEN`.
- Title is `Refactor account settings into profile lifecycle storage`.
- Body still describes account-scoped settings, app-wide settings, migration, and recommended defaults.

If these assumptions no longer hold, stop before editing and report the contradiction.

- [ ] **Step 2: Build a preservation-safe updated body**

The updated body must be:

```text
<!-- roadmap-id:R11 -->

[existing Issue #18 body without modification]

---

## 2026 H2 제품 품질 로드맵 연결

- Milestone: M2 — Trusted Install & First Command
- Primary impact: TTFC
- 이 이슈는 guided readiness, command preflight, credential health, provider 확장의 설정 소유권 기반이다.

### 추가 acceptance criteria

- [ ] Account-owned setting과 app preference의 소유권 경계가 문서화된다.
- [ ] Profile 삭제·재인증·이름 변경 시 setting 정합성이 유지된다.
- [ ] Migration failure와 downgrade가 기존 account·shell command를 손상시키지 않는다.
- [ ] Provider lifecycle 상태 머신을 UI 없이 테스트할 수 있다.

### 선행·후속 관계

- 후속: R12, R13, R14, R19, R20, R27, R31, R32, R35
- 실제 issue link는 publication second pass에서 갱신한다.
```

- [ ] **Step 3: Apply milestone and labels without removing `enhancement`**

Use `gh issue edit 18` with:

- M2 milestone title
- Existing `enhancement`
- `type: foundation`
- `area: account`
- `area: architecture`
- `priority: P0`
- `impact: TTFC`

- [ ] **Step 4: Record R11 mapping**

Write:

```json
{
  "issues": {
    "R11": {
      "number": 18,
      "url": "https://github.com/woosublee/CLIProxyManager/issues/18",
      "existing": true
    }
  }
}
```

Merge with existing milestone mapping rather than replacing it.

- [ ] **Step 5: Verify preservation**

Confirm the original `## Summary`, `## Background`, `## Problems`, `## Desired behavior`, `## Acceptance criteria`, and `## Notes` headings still exist once each.

---

### Task 6: Publish M1 issues R02–R08

**Files:**
- Read: issue bodies R02–R08
- Modify remote: 7 GitHub issues
- Update: `mapping.json`

**Interfaces:**
- Consumes: M1 milestone number and label names
- Produces: R02–R08 issue numbers and URLs

- [ ] **Step 1: Dry-run exact-title and marker duplicate checks**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase M1 --dry-run
```

Expected: 7 creates unless an exact marker already exists. A same title without the expected marker is a conflict and must stop the batch.

- [ ] **Step 2: Create R02–R08 in roadmap order**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase M1 --apply
```

Each successful response must be persisted to `mapping.json` before the next create.

- [ ] **Step 3: Verify M1 count and assignments**

Expected:

- 7 open issues
- All assigned to `M1 — Release Truth & Safety`
- Each has exactly one type label, one priority label, one impact label, and declared area labels
- Each body contains its unique `roadmap-id`

---

### Task 7: Publish M2 issues R09–R14 except existing R11

**Files:**
- Read: issue bodies R09, R10, R12, R13, R14
- Modify remote: 5 new GitHub issues
- Update: `mapping.json`

**Interfaces:**
- Consumes: M2 milestone and R11→#18 mapping
- Produces: complete R09–R14 mapping

- [ ] **Step 1: Dry-run M2**

Expected actions:

- Create R09, R10, R12, R13, R14
- Reuse R11 as Issue #18

- [ ] **Step 2: Apply M2 publication**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase M2 --apply
```

- [ ] **Step 3: Verify M2**

Expected: 6 tracked M2 items total, of which 5 are newly created and one is Issue #18.

---

### Task 8: Publish M3 issues R15–R23

**Files:**
- Read: issue bodies R15–R23
- Modify remote: 9 new GitHub issues
- Update: `mapping.json`

**Interfaces:**
- Consumes: M3 milestone and earlier dependency mappings
- Produces: R15–R23 mapping

- [ ] **Step 1: Dry-run M3 duplicate and dependency checks**

The script must confirm every dependency is either already mapped or belongs to the same batch and appears earlier in topological order.

- [ ] **Step 2: Apply M3 publication**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase M3 --apply
```

- [ ] **Step 3: Verify M3**

Expected: 9 open issues assigned to M3 with R15–R23 markers.

---

### Task 9: Publish M4 issues R24–R31

**Files:**
- Read: issue bodies R24–R31
- Modify remote: 8 new GitHub issues
- Update: `mapping.json`

**Interfaces:**
- Consumes: M4 milestone and R11/R13/R15/R19/R21/R24 mappings
- Produces: R24–R31 mapping

- [ ] **Step 1: Dry-run M4**

Expected: 8 creates with no conflicts.

- [ ] **Step 2: Apply M4 publication**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase M4 --apply
```

- [ ] **Step 3: Verify M4**

Expected: 8 open issues assigned to M4 with correct labels.

---

### Task 10: Publish Opportunity Validation issues R32–R35

**Files:**
- Read: issue bodies R32–R35
- Modify remote: 4 new GitHub issues
- Update: `mapping.json`

**Interfaces:**
- Consumes: VALIDATION milestone
- Produces: R32–R35 mapping

- [ ] **Step 1: Verify discovery-specific bodies**

Each body must replace implementation acceptance with:

- [ ] User evidence source and sample size are recorded.
- [ ] Current JTBD and alternative solutions are documented.
- [ ] Privacy, maintenance, and support costs are estimated.
- [ ] Go/no-go decision and entry conditions are recorded.
- [ ] Go이면 implementation issue를 별도로 생성하고 이 discovery issue에 연결한다.

- [ ] **Step 2: Dry-run and apply**

Run:

```bash
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase VALIDATION --dry-run
python3 /tmp/cliproxymanager-roadmap-2026/publish.py issues --phase VALIDATION --apply
```

- [ ] **Step 3: Verify validation assignments**

Expected: 4 issues, `type: discovery`, `priority: validation`, `Opportunity Validation` milestone.

---

### Task 11: Create R01 tracking issue and link the roadmap

**Files:**
- Read: complete `mapping.json`
- Read: R01 body draft
- Modify remote: tracking issue and R02–R35 bodies

**Interfaces:**
- Consumes: complete R02–R35 number mapping
- Produces: R01 issue number; all roadmap bodies use actual `#number` links

- [ ] **Step 1: Assert child mapping completeness**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
m = json.loads(Path('/tmp/cliproxymanager-roadmap-2026/mapping.json').read_text())
missing = [f'R{i:02d}' for i in range(2, 36) if f'R{i:02d}' not in m['issues']]
assert not missing, missing
assert m['issues']['R11']['number'] == 18
print('all 34 child roadmap entries mapped')
PY
```

- [ ] **Step 2: Render R01 with actual checklists**

R01 body must include:

- Product positioning
- Core user
- TTFC and MTTR targets
- M1–M4 and Opportunity Validation sections
- `- [ ] #123 — title` checklist for R02–R35
- Milestone entry and exit conditions
- Link to the committed design spec path
- `<!-- roadmap-id:R01 -->`

- [ ] **Step 3: Create R01 without a milestone**

Create with labels:

- `type: product`
- `priority: P0`
- `impact: reliability`

Record its number and URL in `mapping.json`.

- [ ] **Step 4: Replace roadmap IDs with actual dependency links**

For each R02–R35 body:

- Preserve the marker and all existing body content.
- Replace each dependency `RNN` with `#<mapped number> — <title>`.
- Add `Tracking issue: #<R01 number>`.
- Add a `Blocked by` or `Blocks` section only where the manifest declares a relation.

Do not create GitHub task-list backlinks by comments; keep the canonical relationship in issue bodies and the R01 checklist.

- [ ] **Step 5: Verify no unresolved roadmap references remain**

The only allowed raw `RNN` strings are the issue's own HTML marker and parenthetical roadmap ID. Dependency and tracking sections must contain actual GitHub issue numbers.

---

### Task 12: Run the final remote audit

**Files:**
- Create: `/tmp/cliproxymanager-roadmap-2026/remote-after.json`
- Read: `manifest.json`, `mapping.json`, `remote-before.json`

**Interfaces:**
- Consumes: final GitHub state
- Produces: verified publication report and user-facing links

- [ ] **Step 1: Capture final remote state**

Capture:

- All labels
- All open milestones
- All issues with `roadmap-id` markers
- Issue #18
- R01 tracking issue

- [ ] **Step 2: Verify exact resource counts**

Assertions:

```text
Roadmap labels present: 23/23
Milestones present: 5/5
Tracked roadmap IDs: 35/35
New issues created: 34
Existing issues reused: 1 (#18)
Duplicate roadmap IDs: 0
Duplicate exact titles among roadmap issues: 0
Issues with missing milestone: 0 except R01
Issues with unresolved dependency link: 0
```

- [ ] **Step 3: Verify milestone distribution**

Expected:

```text
M1: 7 issues
M2: 6 issues including #18
M3: 9 issues
M4: 8 issues
Opportunity Validation: 4 issues
No milestone: 1 tracking issue
```

- [ ] **Step 4: Spot-check bodies**

Read and verify at minimum:

- R02: current defect and runtime truth outcome
- R09: Developer ID·notarization acceptance
- R11/#18: original body preserved plus roadmap appendix
- R17: doctor human/JSON output and stable exit code
- R20: Keychain migration, downgrade, redaction
- R23: app health check and rollback
- R25: quota/reset/budget notification behavior
- R31: coordinator boundary outcome, not line-count-only goal
- R35: demand and foundation gates
- R01: all 34 child links

- [ ] **Step 5: Produce the completion report**

Report:

- Tracking issue URL
- Five milestone URLs
- Issue #18 reuse
- Created issue number range or explicit list
- Any deviation from the design
- Final counts
- Confirmation that Notion was not modified

- [ ] **Step 6: Preserve the local mapping until user confirms**

Do not delete `/tmp/cliproxymanager-roadmap-2026` before the completion report is delivered. It is the recovery record for any partial GitHub mutation.

---

## Rollback and Partial Failure Policy

GitHub issue publication is outward-facing and deletion would destroy discussion history or URLs. Therefore rollback means **stop and repair**, not delete.

- Label creation failure: stop before milestone or issue creation if a required label is unavailable.
- Milestone failure: stop before issue creation for that milestone.
- Issue batch failure: keep successfully created issues, persist mapping, fix the cause, rerun idempotently.
- Wrong metadata: edit the affected issue or milestone in place.
- Duplicate marker: stop and resolve which issue is canonical before continuing.
- Issue #18 contradiction: do not edit; report the changed state to the user.
- Tracking issue failure: child issues remain valid; retry R01 creation after mapping verification.

## Plan Self-Review

- Spec coverage: R01–R35, five milestones, label taxonomy, TTFC·MTTR, dependencies, privacy, rollback, tests, Definition of Ready/Done are covered.
- Existing-state coverage: no milestones, default labels only, Issue #18 reuse, GitHub-only personal project policy are reflected.
- 미완성 문구 검사: 생성된 issue body에는 미완성 표식이나 해결되지 않은 구현 문구를 허용하지 않는다.
- Type consistency: `roadmap-id`, milestone keys, issue IDs, mapping schema, dependency IDs use the same names throughout.
- Scope: this plan publishes the roadmap only; product implementation is intentionally excluded.
