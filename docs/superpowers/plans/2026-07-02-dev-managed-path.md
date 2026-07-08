# Dev Managed Path Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DEBUG 개발 빌드는 `~/.cliproxy-manager/dev`를 사용하고, 프로덕션 경로에는 CLIProxyAPI 업데이트 메타파일만 남지 않게 정리한다.

**Architecture:** `ManagedPaths.defaultRootDirectory()`를 기본 root 결정의 단일 진입점으로 유지한다. Swift 컴파일 조건으로 DEBUG 빌드만 production root 아래 `dev` 하위 디렉터리를 반환하고, release/non-DEBUG 빌드는 기존 `~/.cliproxy-manager`를 그대로 반환한다. 로컬 프로덕션 정리는 코드 변경과 분리된 운영 작업으로 실행하며, 삭제 전후 보존 대상의 파일 해시를 비교한다.

**Tech Stack:** Swift 5.10, SwiftPM, XCTest, Foundation `URL`, macOS 파일 시스템, Python 3 표준 라이브러리(로컬 정리 검증 스크립트)

## Global Constraints

- DEBUG 빌드: `~/.cliproxy-manager/dev`
- non-DEBUG 빌드: `~/.cliproxy-manager`
- 프로덕션 앱의 root 경로를 변경하지 않는다.
- 기존 `config.yaml`, 인증 정보, shell function, 실제 `cliproxyapi` 실행 파일을 삭제하지 않는다.
- 환경변수 override나 번들 위치 기반 자동 판별은 이번 변경에 포함하지 않는다.
- CLIProxyAPI 업데이트 UX 자체를 재설계하지 않는다.
- 삭제 대상은 `~/.cliproxy-manager/cliproxyapi/active-manifest.json`, `~/.cliproxy-manager/cliproxyapi/update-state.json`, `~/.cliproxy-manager/cliproxyapi/pending/`로 제한한다.
- 보존 대상은 `~/.cliproxy-manager/cliproxyapi/cliproxyapi`, `~/.cliproxy-manager/cliproxyapi/config.yaml`, `~/.cliproxy-manager/config.json`, `~/.cliproxy-manager/auth/`, `~/.cliproxy-manager/functions.zsh`이다.
- 커밋 메시지는 `Co-Authored-By: Claude <noreply@anthropic.com>` 줄로 끝낸다.

---

## File Structure

- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
  - 책임: 앱의 기본 관리 root를 계산한다.
  - 변경: `defaultRootDirectory()`에서 production root를 만든 뒤 DEBUG 빌드만 `dev` 하위 디렉터리를 반환한다.
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - 책임: 설정 모델과 `ManagedPaths`의 기본/주입 경로 동작을 검증한다.
  - 변경: DEBUG 기본 root가 `~/.cliproxy-manager/dev`인지, non-DEBUG 기본 root가 `~/.cliproxy-manager`인지 컴파일 조건별로 검증하는 테스트를 추가한다.
- No source file change: 로컬 프로덕션 메타파일 정리
  - 책임: 사용자 컴퓨터의 기존 프로덕션 경로에서 업데이트 테스트 메타파일만 제거한다.
  - 변경: git-tracked 파일은 수정하지 않는다. 삭제 전후 보존 대상 파일의 크기와 SHA-256을 비교한다.

---

### Task 1: DEBUG 기본 관리 root 분리

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:182-200`
- Modify: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift:62-65`

**Interfaces:**
- Consumes: `ManagedPaths.defaultRootDirectory() -> URL`
- Produces: `ManagedPaths.defaultRootDirectory() -> URL` with these semantics:
  - DEBUG: `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cliproxy-manager", isDirectory: true).appendingPathComponent("dev", isDirectory: true)`
  - non-DEBUG: `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cliproxy-manager", isDirectory: true)`

- [ ] **Step 1: Write the failing test**

Add this test to `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift` immediately before `testManagedPathsCanBeRootedInTemporaryDirectory()`:

```swift
    func testDefaultRootDirectoryUsesDevelopmentSubdirectoryInDebugBuilds() {
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cliproxy-manager", isDirectory: true)

        #if DEBUG
        XCTAssertEqual(
            ManagedPaths.defaultRootDirectory(),
            productionRoot.appendingPathComponent("dev", isDirectory: true)
        )
        #else
        XCTAssertEqual(ManagedPaths.defaultRootDirectory(), productionRoot)
        #endif
    }
```

- [ ] **Step 2: Run the focused test and verify it fails before implementation**

Run:

```bash
swift test --filter AppConfigTests/testDefaultRootDirectoryUsesDevelopmentSubdirectoryInDebugBuilds
```

Expected result before implementation in the default DEBUG test build:

```text
Test Case '-[CLIProxyManagerCoreTests.AppConfigTests testDefaultRootDirectoryUsesDevelopmentSubdirectoryInDebugBuilds]' started.
... XCTAssertEqual failed ...
Executed 1 test, with 1 failure
```

The actual path should end with `~/.cliproxy-manager`, while the expected path should end with `~/.cliproxy-manager/dev`.

- [ ] **Step 3: Implement the minimal path split**

Replace `defaultRootDirectory()` in `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift` with this exact implementation:

```swift
    public static func defaultRootDirectory() -> URL {
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cliproxy-manager", isDirectory: true)
        #if DEBUG
        return productionRoot.appendingPathComponent("dev", isDirectory: true)
        #else
        return productionRoot
        #endif
    }
```

Keep every existing computed path property unchanged.

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
swift test --filter AppConfigTests/testDefaultRootDirectoryUsesDevelopmentSubdirectoryInDebugBuilds
```

Expected result:

```text
Executed 1 test, with 0 failures
```

- [ ] **Step 5: Run the core test suite**

Run:

```bash
swift test --filter CLIProxyManagerCoreTests
```

Expected result:

```text
Test Suite 'CLIProxyManagerCoreTests.xctest' passed
```

If SwiftPM prints a different suite wrapper name, success is still defined by `0 failures` and exit code `0`.

- [ ] **Step 6: Commit the code change**

Run:

```bash
git add Sources/CLIProxyManagerCore/Config/ManagedPaths.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m $'Use dev managed path for debug builds\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
```

Expected result:

```text
[worktree-cliproxyapi-binary-self-update <hash>] Use dev managed path for debug builds
 2 files changed
```

---

### Task 2: 로컬 프로덕션 CLIProxyAPI 업데이트 메타파일 정리

**Files:**
- Local filesystem only: `~/.cliproxy-manager/cliproxyapi/active-manifest.json`
- Local filesystem only: `~/.cliproxy-manager/cliproxyapi/update-state.json`
- Local filesystem only: `~/.cliproxy-manager/cliproxyapi/pending/`

**Interfaces:**
- Consumes: 승인된 삭제 대상 목록 from Global Constraints
- Produces: 프로덕션 경로에 업데이트 테스트 메타파일이 없는 상태
- Preserves: existing file content and metadata for these files when they exist:
  - `~/.cliproxy-manager/cliproxyapi/cliproxyapi`
  - `~/.cliproxy-manager/cliproxyapi/config.yaml`
  - `~/.cliproxy-manager/config.json`
  - `~/.cliproxy-manager/functions.zsh`

- [ ] **Step 1: Snapshot delete candidates and preserved files before deletion**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib
import json

home = Path.home()
root = home / ".cliproxy-manager"
clip = root / "cliproxyapi"
targets = [
    clip / "active-manifest.json",
    clip / "update-state.json",
    clip / "pending",
]
preserved_files = [
    clip / "cliproxyapi",
    clip / "config.yaml",
    root / "config.json",
    root / "functions.zsh",
]
preserved_dirs = [root / "auth"]

for path in targets + preserved_files + preserved_dirs:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        raise SystemExit(f"Refusing to inspect path outside production root: {path}")

snapshot = {}
for path in preserved_files:
    if path.is_file():
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        snapshot[str(path)] = {"sha256": h.hexdigest(), "size": path.stat().st_size}
    else:
        snapshot[str(path)] = {"missing": True}

snapshot_path = Path("/tmp/cliproxy-manager-preserve-before.json")
snapshot_path.write_text(json.dumps(snapshot, indent=2, sort_keys=True))

print("DELETE CANDIDATES")
for path in targets:
    if path.exists():
        kind = "dir" if path.is_dir() else "file"
        print(f"exists {kind}: {path}")
    else:
        print(f"missing: {path}")

print("PRESERVE FILE SNAPSHOT")
for path, info in snapshot.items():
    if info.get("missing"):
        print(f"missing: {path}")
    else:
        print(f"recorded: {path} size={info['size']} sha256={info['sha256']}")

print("PRESERVE DIRECTORIES")
for path in preserved_dirs:
    print(f"{'exists' if path.is_dir() else 'missing'}: {path}")
print(f"snapshot: {snapshot_path}")
PY
```

Expected result:

```text
DELETE CANDIDATES
exists file: /Users/.../.cliproxy-manager/cliproxyapi/active-manifest.json
exists file: /Users/.../.cliproxy-manager/cliproxyapi/update-state.json
exists dir: /Users/.../.cliproxy-manager/cliproxyapi/pending
PRESERVE FILE SNAPSHOT
...
snapshot: /tmp/cliproxy-manager-preserve-before.json
```

It is acceptable for any delete candidate to print `missing`. Do not continue if the script exits with `Refusing to inspect path outside production root`.

- [ ] **Step 2: Delete only the approved metadata targets**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import shutil

home = Path.home()
root = home / ".cliproxy-manager"
clip = root / "cliproxyapi"
targets = [
    clip / "active-manifest.json",
    clip / "update-state.json",
    clip / "pending",
]

for path in targets:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        raise SystemExit(f"Refusing to delete path outside production root: {path}")

for path in targets:
    if not path.exists():
        print(f"already missing: {path}")
    elif path.is_dir():
        shutil.rmtree(path)
        print(f"deleted directory: {path}")
    else:
        path.unlink()
        print(f"deleted file: {path}")
PY
```

Expected result:

```text
deleted file: /Users/.../.cliproxy-manager/cliproxyapi/active-manifest.json
deleted file: /Users/.../.cliproxy-manager/cliproxyapi/update-state.json
deleted directory: /Users/.../.cliproxy-manager/cliproxyapi/pending
```

It is acceptable for already-deleted or never-created targets to print `already missing`.

- [ ] **Step 3: Verify delete targets are gone and preserved files are unchanged**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import hashlib
import json

home = Path.home()
root = home / ".cliproxy-manager"
clip = root / "cliproxyapi"
targets = [
    clip / "active-manifest.json",
    clip / "update-state.json",
    clip / "pending",
]
snapshot_path = Path("/tmp/cliproxy-manager-preserve-before.json")
if not snapshot_path.is_file():
    raise SystemExit(f"Missing snapshot file: {snapshot_path}")

before = json.loads(snapshot_path.read_text())
errors = []

for path in targets:
    if path.exists():
        errors.append(f"delete target still exists: {path}")

for raw_path, previous in before.items():
    path = Path(raw_path)
    if previous.get("missing"):
        if path.exists():
            errors.append(f"preserved file appeared after cleanup: {path}")
        continue
    if not path.is_file():
        errors.append(f"preserved file missing after cleanup: {path}")
        continue
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    current = {"sha256": h.hexdigest(), "size": path.stat().st_size}
    if current != previous:
        errors.append(f"preserved file changed: {path}")

if errors:
    for error in errors:
        print(error)
    raise SystemExit(1)

print("cleanup verified: delete targets absent and preserved file snapshots unchanged")
PY
```

Expected result:

```text
cleanup verified: delete targets absent and preserved file snapshots unchanged
```

- [ ] **Step 4: Confirm cleanup did not create git changes**

Run:

```bash
git status --short
```

Expected result after Task 1 is committed and no implementation task is in progress:

```text
```

No output means the working tree is clean. If the plan file itself remains uncommitted, the only acceptable output is this plan path:

```text
?? docs/superpowers/plans/2026-07-02-dev-managed-path.md
```

---

### Task 3: 통합 검증

**Files:**
- Read-only verification: `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- Read-only verification: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
- Build output only: `.build/`

**Interfaces:**
- Consumes: Task 1's `ManagedPaths.defaultRootDirectory()` semantics
- Consumes: Task 2's cleaned local production metadata state
- Produces: confidence that DEBUG builds compile and tests pass with the isolated dev root

- [ ] **Step 1: Run all Swift tests**

Run:

```bash
swift test
```

Expected result:

```text
Test Suite 'All tests' passed
```

Success is defined by exit code `0` and `0 failures`.

- [ ] **Step 2: Build the DEBUG app product**

Run:

```bash
swift build -c debug --product CLIProxyManager
```

Expected result:

```text
Build complete!
```

- [ ] **Step 3: Build the release app product to ensure the non-DEBUG branch compiles**

Run:

```bash
swift build -c release --product CLIProxyManager
```

Expected result:

```text
Build complete!
```

- [ ] **Step 4: Verify the default root implementation still contains both branches**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path("Sources/CLIProxyManagerCore/Config/ManagedPaths.swift").read_text()
required = [
    "#if DEBUG",
    'return productionRoot.appendingPathComponent("dev", isDirectory: true)',
    "#else",
    "return productionRoot",
    "#endif",
]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit("missing expected branch text: " + ", ".join(missing))
print("default root debug/release branches verified")
PY
```

Expected result:

```text
default root debug/release branches verified
```

- [ ] **Step 5: Report final state**

Run:

```bash
git status --short
```

Expected result:

```text
```

If the plan file is intentionally uncommitted, the only acceptable output is:

```text
?? docs/superpowers/plans/2026-07-02-dev-managed-path.md
```

Summarize these facts to the user:

```text
- DEBUG 기본 root: ~/.cliproxy-manager/dev
- release 기본 root: ~/.cliproxy-manager
- 프로덕션 업데이트 메타파일 정리 완료
- 보존 대상 파일 해시 변경 없음
- swift test 통과
- debug/release build 통과
```

---

## Self-Review

### Spec coverage

- DEBUG 빌드가 `~/.cliproxy-manager/dev`를 사용한다: Task 1 Step 3, Task 1 Step 4, Task 3 Step 4.
- release/prod 빌드는 `~/.cliproxy-manager`를 유지한다: Task 1 Step 3의 `#else`, Task 3 Step 3, Task 3 Step 4.
- 프로덕션 경로의 `cliproxyapi`와 `config.yaml`을 보존한다: Task 2 Step 1과 Step 3의 preserved file snapshot 비교.
- 업데이트 메타파일만 삭제한다: Task 2 Step 2의 target list.
- 관련 Swift 테스트 통과: Task 1 Step 5, Task 3 Step 1.

### Placeholder scan

이 계획에는 `TBD`, 미완성 섹션, 정의되지 않은 함수명, “나중에 구현” 지시가 없다.

### Type consistency

- `ManagedPaths.defaultRootDirectory() -> URL` 서명은 모든 작업에서 동일하다.
- 테스트와 구현 모두 `productionRoot.appendingPathComponent("dev", isDirectory: true)`를 사용한다.
- 삭제 대상과 보존 대상은 Global Constraints, Task 2 Step 1, Step 2, Step 3에서 같은 경로를 사용한다.
