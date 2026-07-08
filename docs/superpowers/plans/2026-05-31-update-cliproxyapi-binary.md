# CLIProxyAPI Binary Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the bundled CLIProxyAPI binary in CLIProxyManager to the latest upstream GitHub release using the existing vendoring flow.

**Architecture:** Keep the existing vendored-binary architecture unchanged. The app bundles `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`, and `scripts/vendor-cliproxyapi.sh` downloads the upstream release asset, verifies `checksums.txt`, copies the macOS arm64 binary, and rewrites `cliproxyapi.manifest.json` with version and checksum metadata.

**Tech Stack:** Swift Package Manager, Bash, GitHub CLI (`gh`), macOS `shasum`, existing vendoring script and script tests.

---

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
  - Responsibility: vendored macOS arm64 CLIProxyAPI executable bundled into the app resources.
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
  - Responsibility: records upstream version, source URL, upstream asset checksum, vendored binary checksum, binary size, and archive path.
- Read/Execute only: `scripts/vendor-cliproxyapi.sh`
  - Responsibility: canonical CLIProxyAPI vendoring flow. Do not bypass it.
- Read/Execute only: `Tests/ScriptTests/vendor-cliproxyapi-tests.sh`
  - Responsibility: regression test for the local vendoring mode and manifest generation.

## Current State

- Current bundled CLIProxyAPI version: `7.1.22`, from `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`.
- Existing update path: `scripts/vendor-cliproxyapi.sh <version>`.
- Expected changed files after update:
  - `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
  - `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`

---

### Task 1: Resolve the latest upstream release

**Files:**
- Read: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`

- [ ] **Step 1: Read the current vendored version**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
manifest = Path('Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json')
data = json.loads(manifest.read_text())
print(data['version'])
PY
```

Expected: prints the currently vendored version, currently `7.1.22`.

- [ ] **Step 2: Query the latest CLIProxyAPI release tag**

Run:

```bash
gh release view --repo router-for-me/CLIProxyAPI --json tagName --jq .tagName
```

Expected: prints a tag in the form `v<version>`, for example `v7.1.23`.

- [ ] **Step 3: Convert the latest tag to a version string**

Run:

```bash
LATEST_TAG="$(gh release view --repo router-for-me/CLIProxyAPI --json tagName --jq .tagName)"
LATEST_VERSION="${LATEST_TAG#v}"
printf '%s\n' "$LATEST_VERSION"
```

Expected: prints the version without the `v` prefix, for example `7.1.23`.

- [ ] **Step 4: Stop if no update is needed**

Run:

```bash
CURRENT_VERSION="$(python3 - <<'PY'
import json
from pathlib import Path
manifest = Path('Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json')
data = json.loads(manifest.read_text())
print(data['version'])
PY
)"
LATEST_TAG="$(gh release view --repo router-for-me/CLIProxyAPI --json tagName --jq .tagName)"
LATEST_VERSION="${LATEST_TAG#v}"
printf 'current=%s latest=%s\n' "$CURRENT_VERSION" "$LATEST_VERSION"
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
  echo "Bundled CLIProxyAPI is already current."
  exit 0
fi
```

Expected when an update exists: prints different `current` and `latest` values and exits successfully without the “already current” line. Expected when no update exists: prints “Bundled CLIProxyAPI is already current.” and no vendoring task is required.

---

### Task 2: Vendor the latest CLIProxyAPI binary

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`
- Execute: `scripts/vendor-cliproxyapi.sh`

- [ ] **Step 1: Run the canonical vendoring script**

Run:

```bash
LATEST_TAG="$(gh release view --repo router-for-me/CLIProxyAPI --json tagName --jq .tagName)"
LATEST_VERSION="${LATEST_TAG#v}"
scripts/vendor-cliproxyapi.sh "$LATEST_VERSION"
```

Expected:

```text
Vendored CLIProxyAPI <latest-version> to /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi
Wrote manifest to /Users/woosublee/Documents/dev/CLIProxyManager/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

The script must also show successful checksum verification from `shasum -a 256 -c --ignore-missing checksums.txt`, typically an `OK` line for the downloaded asset.

- [ ] **Step 2: Confirm only expected tracked files changed**

Run:

```bash
git status --short -- Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

Expected:

```text
 M Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi
 M Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

If `cliproxyapi` is unchanged because upstream latest equals the current binary, do not commit a binary update.

- [ ] **Step 3: Inspect the manifest content**

Run:

```bash
python3 -m json.tool Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

Expected: valid JSON with these properties populated and non-empty:

```json
{
  "name": "cliproxyapi",
  "version": "<latest-version>",
  "commit": "<upstream-commit>",
  "builtAt": "<upstream-build-time>",
  "source": "https://github.com/router-for-me/CLIProxyAPI/releases/download/v<latest-version>/CLIProxyAPI_<latest-version>_darwin_aarch64.tar.gz",
  "upstreamRepository": "router-for-me/CLIProxyAPI",
  "upstreamTag": "v<latest-version>",
  "upstreamAsset": "CLIProxyAPI_<latest-version>_darwin_aarch64.tar.gz",
  "upstreamAssetSha256": "<sha256>",
  "vendoredBinaryName": "cliproxyapi",
  "vendoredBinarySha256": "<sha256>",
  "vendoredBinarySizeBytes": 1,
  "vendoredFromArchivePath": "cli-proxy-api"
}
```

`vendoredBinarySizeBytes` must be a positive integer. The example value `1` above means “positive integer”, not the expected final size.

- [ ] **Step 4: Confirm the vendored binary reports the latest version**

Run:

```bash
Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi --version
```

Expected: output contains exactly one line with:

```text
CLIProxyAPI Version: <latest-version>, Commit: <upstream-commit>, BuiltAt: <upstream-build-time>
```

The version must match `cliproxyapi.manifest.json`.

---

### Task 3: Run regression checks

**Files:**
- Execute: `Tests/ScriptTests/vendor-cliproxyapi-tests.sh`
- Execute: Swift package tests via `swift test`

- [ ] **Step 1: Run the vendoring script regression test**

Run:

```bash
Tests/ScriptTests/vendor-cliproxyapi-tests.sh
```

Expected: exits with status `0` and prints no `FAIL:` line.

- [ ] **Step 2: Run the Swift test suite**

Run:

```bash
swift test
```

Expected: exits with status `0` and ends with a passing test summary. If warnings appear, report them, but do not treat warnings as failures unless `swift test` exits non-zero.

- [ ] **Step 3: Verify manifest checksum matches the vendored binary**

Run:

```bash
python3 - <<'PY'
import hashlib
import json
from pathlib import Path
binary = Path('Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi')
manifest = Path('Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json')
data = json.loads(manifest.read_text())
actual = hashlib.sha256(binary.read_bytes()).hexdigest()
expected = data['vendoredBinarySha256']
print(f'actual={actual}')
print(f'expected={expected}')
if actual != expected:
    raise SystemExit('vendored binary sha256 does not match manifest')
if data['vendoredBinarySizeBytes'] != binary.stat().st_size:
    raise SystemExit('vendored binary size does not match manifest')
print('manifest checksum and size match')
PY
```

Expected:

```text
manifest checksum and size match
```

---

### Task 4: Review and commit the binary update

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi`
- Modify: `Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json`

- [ ] **Step 1: Review the final tracked diff summary**

Run:

```bash
git diff --stat -- Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

Expected: shows the binary file changed and the manifest JSON changed.

- [ ] **Step 2: Review the manifest diff**

Run:

```bash
git diff -- Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

Expected: manifest version, commit, builtAt, source URL, upstream tag, upstream asset checksum, vendored binary checksum, and binary size changed to the latest release metadata.

- [ ] **Step 3: Check unrelated existing untracked files remain untouched**

Run:

```bash
git status --short
```

Expected: the CLIProxyAPI resource files are modified. Pre-existing untracked files such as `build 2/`, `docs/superpowers/plans/2026-05-17-account-profile-privacy-toggle.md`, and `docs/superpowers/specs/2026-05-17-account-profile-privacy-design.md` may still appear and must not be staged for this update.

- [ ] **Step 4: Commit only the CLIProxyAPI resource update when requested by the user**

Run only if the user asks to commit:

```bash
git add Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
git commit -m "Update bundled CLIProxyAPI to <latest-version>" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: a commit is created containing only the vendored binary and manifest update. Do not stage or commit unrelated untracked files.

---

## Self-Review

- Spec coverage: The plan covers latest release discovery, canonical vendoring via `scripts/vendor-cliproxyapi.sh`, changed-file review, manifest validation, binary version validation, script regression test, Swift test suite, checksum verification, and commit hygiene.
- Placeholder scan: The plan contains no `TBD`, `TODO`, or unspecified implementation steps. `<latest-version>`, `<upstream-commit>`, `<upstream-build-time>`, and `<sha256>` are runtime values obtained from the upstream release and generated manifest.
- Type consistency: File paths and command names match the existing repository structure and scripts.
