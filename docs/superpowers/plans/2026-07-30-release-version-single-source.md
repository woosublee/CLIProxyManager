# Release Version Single Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Version/build metadata를 `release/version.json` 하나로 통합하고 local·CI release가 동일 identity와 monotonic build gate를 사용하도록 만든다.

**Architecture:** Executable Bash scripts expose one canonical resolver, atomic plist synchronization, published-appcast monotonic validation, and artifact parity validation. Makefile, local release, GitHub Actions, and Sparkle appcast generation consume those scripts instead of parsing version data independently. Script tests exercise behavior in sandbox repositories, while `ReleaseWorkflowTests` pins repository-wide release policy.

**Tech Stack:** Bash 3.2-compatible shell, GNU/Unix Make, `/usr/bin/plutil`, `/usr/bin/xmllint`, `gh`, GitHub Actions YAML, Swift XCTest, Sparkle appcast XML.

## Global Constraints

- Canonical file is exactly `release/version.json` with keys `version` and `build` only.
- Official `version` must match `^[0-9]+\.[0-9]+\.[0-9]+$`; prerelease and build metadata are rejected.
- Official and development `build` values must be JSON/shell positive integers greater than zero.
- Official artifact identity cannot be overridden through `VERSION`, `BUILD_NUMBER`, `RELEASE_TAG`, or `DMG_PATH`.
- Development overrides require `ARTIFACT_CHANNEL=development`, `DEVELOPMENT_VERSION`, and `DEVELOPMENT_BUILD_NUMBER`; development artifacts must be visibly non-official.
- Latest non-draft, non-prerelease GitHub Release `appcast.xml` is the published build authority.
- Network/API failure is fail closed unless a local release explicitly provides `--previous-appcast`; fallback never relaxes build monotonicity.
- Resolver, diagnostics, provenance, and test fixtures must not expose secret, email, raw user path, or prompt data.
- Plist, appcast, and provenance writes must use same-directory temporary files followed by atomic rename.
- Automatic verification stops at development app bundle validation; the user performs app launch and About/update UI checks.

---

## File Structure

### New files

- `release/version.json`
  - Sole manually edited official version/build source.
- `scripts/release-version-lib.sh`
  - Internal shared Bash functions for logical errors, canonical identity validation, appcast identity parsing, path-neutral messages, and atomic replacement.
- `scripts/resolve-release-version.sh`
  - Public resolver CLI for official/development identity and derived fields.
- `scripts/sync-release-version.sh`
  - Atomic source `Info.plist` mirror sync and read-only parity check.
- `scripts/check-release-monotonic.sh`
  - Previous published appcast lookup, build comparison, and provenance generation.
- `scripts/verify-release-artifacts.sh`
  - Source plist, built app, DMG, appcast, and provenance parity verifier.
- `Tests/ScriptTests/release-version-tests.sh`
  - Sandbox behavior tests for all new release identity scripts and Makefile identity behavior.

### Modified files

- `Makefile:1-45,52-75,129-146,211-247`
  - Remove independent version/build defaults; delegate identity and artifact names to the resolver; enforce source plist parity; mark development overrides.
- `Info.plist:17-20`
  - Update generated mirror to canonical version/build.
- `scripts/generate-sparkle-appcast.sh:1-119`
  - Resolve identity canonically, reject legacy overrides, write atomically, verify output parity.
- `Tests/ScriptTests/generate-sparkle-appcast-tests.sh:1-123`
  - Exercise canonical identity, override rejection, and atomic output behavior.
- `scripts/release-local.sh:1-47`
  - Add canonical preflight, monotonic checks, tag creation/resume rules, final parity, and provenance upload.
- `Tests/ScriptTests/release-local-tests.sh:1-174`
  - Pin orchestration order and no-remote-write failure behavior.
- `.github/workflows/release.yml:1-175`
  - Replace inline parsing with shared scripts, add release concurrency and repeated preflight, upload provenance.
- `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift:3-162`
  - Replace old Makefile/environment assertions with single-source and release-gate policy assertions.
- `README.md:118-132`
  - Add Korean maintainer release identity and fallback procedure.
- `README.en.md:118-132`
  - Add matching English maintainer procedure.

---

### Task 1: Canonical Metadata and Resolver

**Files:**
- Create: `release/version.json`
- Create: `scripts/release-version-lib.sh`
- Create: `scripts/resolve-release-version.sh`
- Create: `Tests/ScriptTests/release-version-tests.sh`

**Interfaces:**
- Produces executable `scripts/resolve-release-version.sh COMMAND` where `COMMAND` is `validate`, `version`, `build`, `tag`, `dmg-name`, `dmg-path`, `appcast-path`, `channel`, `shell`, or `json`.
- Produces sourced functions in `scripts/release-version-lib.sh`:
  - `release_fail MESSAGE`
  - `release_load_identity REPO_ROOT`
  - `release_atomic_replace STAGED_PATH DESTINATION_PATH`
- Sets validated globals after `release_load_identity`:
  - `RELEASE_CHANNEL`
  - `RELEASE_VERSION`
  - `RELEASE_BUILD`
  - `RELEASE_TAG`
  - `RELEASE_DMG_NAME`
  - `RELEASE_DMG_PATH`
  - `RELEASE_APPCAST_PATH`
- Official mode is the default. Development mode is selected only by `ARTIFACT_CHANNEL=development` with both development identity variables.

- [ ] **Step 1: Write resolver tests that currently fail because the files do not exist**

Create `Tests/ScriptTests/release-version-tests.sh` with a sandbox-copy harness and exact assertions:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_RESOLVER="$REPO_ROOT/scripts/resolve-release-version.sh"
SOURCE_LIB="$REPO_ROOT/scripts/release-version-lib.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_failure_contains() {
  local expected="$1"
  shift
  local stdout stderr
  stdout="$(mktemp /tmp/release-version-stdout.XXXXXX)"
  stderr="$(mktemp /tmp/release-version-stderr.XXXXXX)"
  if "$@" >"$stdout" 2>"$stderr"; then
    fail "command should fail: $*"
  fi
  grep -F "$expected" "$stderr" >/dev/null || {
    printf '%s\n' '--- stderr ---' >&2
    perl -ne 'print' "$stderr" >&2
    fail "missing error text: $expected"
  }
  rm -f "$stdout" "$stderr"
}

new_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/release"
  cp "$SOURCE_RESOLVER" "$root/scripts/resolve-release-version.sh"
  cp "$SOURCE_LIB" "$root/scripts/release-version-lib.sh"
  chmod +x "$root/scripts/resolve-release-version.sh"
}

sandbox="$(mktemp -d /tmp/release-version-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
repo="$sandbox/repo"
new_repo "$repo"

cat > "$repo/release/version.json" <<'JSON'
{
  "version": "0.2.0",
  "build": 7
}
JSON

resolver="$repo/scripts/resolve-release-version.sh"
[[ "$($resolver version)" == "0.2.0" ]] || fail "version output mismatch"
[[ "$($resolver build)" == "7" ]] || fail "build output mismatch"
[[ "$($resolver tag)" == "v0.2.0" ]] || fail "tag output mismatch"
[[ "$($resolver dmg-name)" == "CLIProxyManager-0.2.0.dmg" ]] || fail "DMG name mismatch"
[[ "$($resolver dmg-path)" == "build/CLIProxyManager-0.2.0.dmg" ]] || fail "DMG path mismatch"
[[ "$($resolver appcast-path)" == "build/appcast.xml" ]] || fail "appcast path mismatch"
[[ "$($resolver channel)" == "official" ]] || fail "official channel mismatch"

shell_output="$($resolver shell)"
grep -Fx "RELEASE_VERSION='0.2.0'" <<<"$shell_output" >/dev/null || fail "missing shell version"
grep -Fx "RELEASE_BUILD='7'" <<<"$shell_output" >/dev/null || fail "missing shell build"
grep -Fx "RELEASE_TAG='v0.2.0'" <<<"$shell_output" >/dev/null || fail "missing shell tag"
grep -Fx "RELEASE_CHANNEL='official'" <<<"$shell_output" >/dev/null || fail "missing shell channel"

eval "$shell_output"
[[ "$RELEASE_VERSION" == "0.2.0" ]] || fail "shell output should be evaluable"
[[ "$RELEASE_BUILD" == "7" ]] || fail "shell build should be evaluable"

json_output="$($resolver json)"
printf '%s' "$json_output" | plutil -lint - >/dev/null || fail "JSON output should parse"
[[ "$(printf '%s' "$json_output" | plutil -extract version raw -)" == "0.2.0" ]] || fail "JSON version mismatch"
[[ "$(printf '%s' "$json_output" | plutil -extract build raw -)" == "7" ]] || fail "JSON build mismatch"
[[ "$(printf '%s' "$json_output" | plutil -extract channel raw -)" == "official" ]] || fail "JSON channel mismatch"
```

Append a table-driven invalid metadata section:

```bash
write_metadata() {
  printf '%s\n' "$1" > "$repo/release/version.json"
}

write_metadata '{'
assert_failure_contains 'release/version.json must be valid JSON' "$resolver" validate

write_metadata '[]'
assert_failure_contains 'release/version.json root must be an object' "$resolver" validate

write_metadata '{"version":"0.2.0"}'
assert_failure_contains 'release/version.json must contain exactly version and build' "$resolver" validate

write_metadata '{"version":"0.2.0","build":7,"extra":true}'
assert_failure_contains 'release/version.json must contain exactly version and build' "$resolver" validate

write_metadata '{"version":" 0.2.0","build":7}'
assert_failure_contains 'version must use stable SemVer x.y.z' "$resolver" validate

write_metadata '{"version":"0.2.0-beta.1","build":7}'
assert_failure_contains 'version must use stable SemVer x.y.z' "$resolver" validate

write_metadata '{"version":"0.2.0+ci","build":7}'
assert_failure_contains 'version must use stable SemVer x.y.z' "$resolver" validate

write_metadata '{"version":"0.2.0","build":0}'
assert_failure_contains 'build must be a positive integer' "$resolver" validate

write_metadata '{"version":"0.2.0","build":-1}'
assert_failure_contains 'build must be a positive integer' "$resolver" validate

write_metadata '{"version":"0.2.0","build":7.5}'
assert_failure_contains 'build must be a positive integer' "$resolver" validate

write_metadata '{"version":"0.2.0","build":"7"}'
assert_failure_contains 'build must be a JSON integer' "$resolver" validate
```

Append development identity tests:

```bash
write_metadata '{"version":"0.2.0","build":7}'

dev_shell="$(
  ARTIFACT_CHANNEL=development \
  DEVELOPMENT_VERSION=0.2.0 \
  DEVELOPMENT_BUILD_NUMBER=9001 \
  "$resolver" shell
)"
grep -Fx "RELEASE_CHANNEL='development'" <<<"$dev_shell" >/dev/null || fail "development channel missing"
grep -Fx "RELEASE_DMG_NAME='CLIProxyManager-0.2.0-development.dmg'" <<<"$dev_shell" >/dev/null || fail "development DMG must be marked"

assert_failure_contains 'development artifacts do not have a release tag' \
  env ARTIFACT_CHANNEL=development DEVELOPMENT_VERSION=0.2.0 DEVELOPMENT_BUILD_NUMBER=9001 \
  "$resolver" tag
assert_failure_contains 'DEVELOPMENT_VERSION is required' \
  env ARTIFACT_CHANNEL=development DEVELOPMENT_BUILD_NUMBER=9001 "$resolver" validate
assert_failure_contains 'DEVELOPMENT_BUILD_NUMBER is required' \
  env ARTIFACT_CHANNEL=development DEVELOPMENT_VERSION=0.2.0 "$resolver" validate
assert_failure_contains 'ARTIFACT_CHANNEL must be official or development' \
  env ARTIFACT_CHANNEL=preview "$resolver" validate
assert_failure_contains 'DEVELOPMENT_VERSION is only valid for development artifacts' \
  env DEVELOPMENT_VERSION=0.2.0 "$resolver" validate
```

End with:

```bash
printf 'release version resolver tests passed\n'
```

- [ ] **Step 2: Run the new test and confirm the expected missing-script failure**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
```

Expected: FAIL before assertions because `scripts/resolve-release-version.sh` and `scripts/release-version-lib.sh` do not exist.

- [ ] **Step 3: Add the canonical metadata file**

Create `release/version.json`:

```json
{
  "version": "0.1.32",
  "build": 35
}
```

- [ ] **Step 4: Implement the shared identity loader**

Create executable-source-compatible `scripts/release-version-lib.sh`. Use Bash 3.2 syntax only—no associative arrays, `mapfile`, or `${var,,}`.

Core shape:

```bash
#!/usr/bin/env bash

release_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

release_repo_root() {
  local script_path="$1"
  cd "$(dirname "$script_path")/.." && pwd
}

release_atomic_replace() {
  local staged="$1"
  local destination="$2"
  mv -f "$staged" "$destination"
}

release_load_identity() {
  local repo_root="$1"
  local metadata="$repo_root/release/version.json"
  local metadata_xml key_count version_type build_type

  plutil -lint "$metadata" >/dev/null 2>&1 ||
    release_fail 'release/version.json must be valid JSON' || return 1

  metadata_xml="$(mktemp /tmp/cliproxymanager-version.XXXXXX.xml)" || return 1
  if ! plutil -convert xml1 -o "$metadata_xml" "$metadata" >/dev/null; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json must be valid JSON'
    return 1
  fi

  if [[ "$(xmllint --xpath 'name(/plist/*[1])' "$metadata_xml" 2>/dev/null)" != 'dict' ]]; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json root must be an object'
    return 1
  fi

  key_count="$(xmllint --xpath 'count(/plist/dict/key)' "$metadata_xml")"
  if [[ "$key_count" != '2' ]] ||
     [[ "$(xmllint --xpath 'count(/plist/dict/key[text()="version"])' "$metadata_xml")" != '1' ]] ||
     [[ "$(xmllint --xpath 'count(/plist/dict/key[text()="build"])' "$metadata_xml")" != '1' ]]; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json must contain exactly version and build'
    return 1
  fi
  rm -f "$metadata_xml"

  version_type="$(plutil -type version "$metadata" 2>/dev/null || true)"
  build_type="$(plutil -type build "$metadata" 2>/dev/null || true)"
  [[ "$version_type" == 'string' ]] || release_fail 'version must be a JSON string' || return 1
  [[ "$build_type" == 'integer' ]] || release_fail 'build must be a JSON integer' || return 1

  RELEASE_VERSION="$(plutil -extract version raw "$metadata")"
  RELEASE_BUILD="$(plutil -extract build raw "$metadata")"
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    release_fail 'version must use stable SemVer x.y.z without whitespace, prerelease, or build metadata' || return 1
  [[ "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]] ||
    release_fail 'build must be a positive integer' || return 1

  RELEASE_CHANNEL="${ARTIFACT_CHANNEL:-official}"
  case "$RELEASE_CHANNEL" in
    official)
      [[ -z "${DEVELOPMENT_VERSION:-}" ]] || release_fail 'DEVELOPMENT_VERSION is only valid for development artifacts' || return 1
      [[ -z "${DEVELOPMENT_BUILD_NUMBER:-}" ]] || release_fail 'DEVELOPMENT_BUILD_NUMBER is only valid for development artifacts' || return 1
      RELEASE_TAG="v$RELEASE_VERSION"
      RELEASE_DMG_NAME="CLIProxyManager-$RELEASE_VERSION.dmg"
      ;;
    development)
      [[ -n "${DEVELOPMENT_VERSION:-}" ]] || release_fail 'DEVELOPMENT_VERSION is required for development artifacts' || return 1
      [[ -n "${DEVELOPMENT_BUILD_NUMBER:-}" ]] || release_fail 'DEVELOPMENT_BUILD_NUMBER is required for development artifacts' || return 1
      [[ "$DEVELOPMENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail 'development version must use stable SemVer x.y.z' || return 1
      [[ "$DEVELOPMENT_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || release_fail 'development build must be a positive integer' || return 1
      RELEASE_VERSION="$DEVELOPMENT_VERSION"
      RELEASE_BUILD="$DEVELOPMENT_BUILD_NUMBER"
      RELEASE_TAG=''
      RELEASE_DMG_NAME="CLIProxyManager-$RELEASE_VERSION-development.dmg"
      ;;
    *)
      release_fail 'ARTIFACT_CHANNEL must be official or development'
      return 1
      ;;
  esac

  RELEASE_DMG_PATH="build/$RELEASE_DMG_NAME"
  RELEASE_APPCAST_PATH='build/appcast.xml'
}
```

Use a `trap` or explicit cleanup for every temporary file path. Do not print `$repo_root` or `$metadata` in user-facing failures.

- [ ] **Step 5: Implement the resolver CLI**

Create `scripts/resolve-release-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

command_name="${1:-}"
[[ $# -eq 1 ]] || release_fail 'Usage: scripts/resolve-release-version.sh {validate|version|build|tag|dmg-name|dmg-path|appcast-path|channel|shell|json}'
release_load_identity "$REPO_ROOT"

case "$command_name" in
  validate) ;;
  version) printf '%s\n' "$RELEASE_VERSION" ;;
  build) printf '%s\n' "$RELEASE_BUILD" ;;
  tag)
    [[ "$RELEASE_CHANNEL" == 'official' ]] || release_fail 'development artifacts do not have a release tag'
    printf '%s\n' "$RELEASE_TAG"
    ;;
  dmg-name) printf '%s\n' "$RELEASE_DMG_NAME" ;;
  dmg-path) printf '%s\n' "$RELEASE_DMG_PATH" ;;
  appcast-path) printf '%s\n' "$RELEASE_APPCAST_PATH" ;;
  channel) printf '%s\n' "$RELEASE_CHANNEL" ;;
  shell)
    printf "RELEASE_CHANNEL='%s'\n" "$RELEASE_CHANNEL"
    printf "RELEASE_VERSION='%s'\n" "$RELEASE_VERSION"
    printf "RELEASE_BUILD='%s'\n" "$RELEASE_BUILD"
    printf "RELEASE_TAG='%s'\n" "$RELEASE_TAG"
    printf "RELEASE_DMG_NAME='%s'\n" "$RELEASE_DMG_NAME"
    printf "RELEASE_DMG_PATH='%s'\n" "$RELEASE_DMG_PATH"
    printf "RELEASE_APPCAST_PATH='%s'\n" "$RELEASE_APPCAST_PATH"
    ;;
  json)
    if [[ "$RELEASE_CHANNEL" == 'official' ]]; then
      printf '{"channel":"official","version":"%s","build":%s,"tag":"%s","dmgName":"%s","dmgPath":"%s","appcastPath":"%s"}\n' \
        "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_TAG" "$RELEASE_DMG_NAME" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH"
    else
      printf '{"channel":"development","version":"%s","build":%s,"tag":null,"dmgName":"%s","dmgPath":"%s","appcastPath":"%s"}\n' \
        "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_DMG_NAME" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH"
    fi
    ;;
  *) release_fail 'Usage: scripts/resolve-release-version.sh {validate|version|build|tag|dmg-name|dmg-path|appcast-path|channel|shell|json}' ;;
esac
```

Mark both new scripts executable where appropriate:

```bash
chmod +x scripts/resolve-release-version.sh Tests/ScriptTests/release-version-tests.sh
```

The library may remain non-executable (`0644`).

- [ ] **Step 6: Run resolver tests and fix only resolver-scope failures**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
```

Expected: PASS and final line `release version resolver tests passed`.

Also run:

```bash
scripts/resolve-release-version.sh validate
scripts/resolve-release-version.sh json | plutil -lint -
```

Expected: both exit 0; `plutil` reports stdin is valid.

- [ ] **Step 7: Commit canonical metadata and resolver**

```bash
git add release/version.json scripts/release-version-lib.sh scripts/resolve-release-version.sh Tests/ScriptTests/release-version-tests.sh
git commit -m "feat: add canonical release identity resolver (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Atomic Plist Mirror and Makefile Identity

**Files:**
- Modify: `scripts/release-version-lib.sh`
- Create: `scripts/sync-release-version.sh`
- Modify: `Tests/ScriptTests/release-version-tests.sh`
- Modify: `Makefile:1-45,52-75,129-146,211-247`
- Modify: `Info.plist:17-20`
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift:9-27`

**Interfaces:**
- Produces `scripts/sync-release-version.sh [--check]`.
- `--check` is read-only and compares source `Info.plist` against the official canonical identity, regardless of development artifact overrides.
- Makefile public compatibility targets remain `print-app-version`, `print-build-number`, and `print-build-tag`.
- Makefile accepts development identity only through `ARTIFACT_CHANNEL`, `DEVELOPMENT_VERSION`, and `DEVELOPMENT_BUILD_NUMBER`.

- [ ] **Step 1: Append failing plist sync and Makefile policy tests**

Append to `Tests/ScriptTests/release-version-tests.sh` before its final success line. Build a second sandbox repository containing a minimal plist:

```bash
sync_repo="$sandbox/sync-repo"
new_repo "$sync_repo"
cp "$REPO_ROOT/scripts/sync-release-version.sh" "$sync_repo/scripts/sync-release-version.sh"
chmod +x "$sync_repo/scripts/sync-release-version.sh"
cat > "$sync_repo/release/version.json" <<'JSON'
{"version":"0.2.0","build":7}
JSON
cat > "$sync_repo/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST

assert_failure_contains 'Info.plist version mismatch: expected 0.2.0, actual 0.1.0' \
  "$sync_repo/scripts/sync-release-version.sh" --check
assert_failure_contains 'Run scripts/sync-release-version.sh to update the generated mirror' \
  "$sync_repo/scripts/sync-release-version.sh" --check

before_mode="$(stat -f '%Lp' "$sync_repo/Info.plist")"
"$sync_repo/scripts/sync-release-version.sh"
[[ "$(plutil -extract CFBundleShortVersionString raw "$sync_repo/Info.plist")" == '0.2.0' ]] || fail "sync should update version"
[[ "$(plutil -extract CFBundleVersion raw "$sync_repo/Info.plist")" == '7' ]] || fail "sync should update build"
[[ "$(stat -f '%Lp' "$sync_repo/Info.plist")" == "$before_mode" ]] || fail "sync should preserve file mode"
"$sync_repo/scripts/sync-release-version.sh" --check
```

Add atomic failure coverage by setting `PLUTIL` to a fake command that fails on mutation while the real plist checksum is recorded:

```bash
checksum_before="$(shasum -a 256 "$sync_repo/Info.plist" | cut -d' ' -f1)"
fake_plutil="$sandbox/fail-plutil"
cat > "$fake_plutil" <<'SH'
#!/usr/bin/env bash
exit 42
SH
chmod +x "$fake_plutil"
assert_failure_contains 'Unable to update the Info.plist mirror' \
  env PLUTIL="$fake_plutil" "$sync_repo/scripts/sync-release-version.sh"
checksum_after="$(shasum -a 256 "$sync_repo/Info.plist" | cut -d' ' -f1)"
[[ "$checksum_before" == "$checksum_after" ]] || fail "failed sync must preserve the original plist"
```

Add repository Makefile assertions:

```bash
makefile="$REPO_ROOT/Makefile"
! grep -Eq '^VERSION[[:space:]]*\?=' "$makefile" || fail "Makefile must not own VERSION"
! grep -Eq '^BUILD_NUMBER[[:space:]]*\?=' "$makefile" || fail "Makefile must not own BUILD_NUMBER"
[[ "$(make -s -C "$REPO_ROOT" print-app-version)" == '0.1.32' ]] || fail "Makefile version must delegate to resolver"
[[ "$(make -s -C "$REPO_ROOT" print-build-number)" == '35' ]] || fail "Makefile build must delegate to resolver"
[[ "$(make -s -C "$REPO_ROOT" print-build-tag)" == 'v0.1.32' ]] || fail "Makefile tag must delegate to resolver"
assert_failure_contains 'VERSION is derived from release/version.json' make -s -C "$REPO_ROOT" VERSION=9.9.9 print-app-version
assert_failure_contains 'BUILD_NUMBER is derived from release/version.json' make -s -C "$REPO_ROOT" BUILD_NUMBER=999 print-build-number
[[ "$(make -s -C "$REPO_ROOT" ARTIFACT_CHANNEL=development DEVELOPMENT_VERSION=0.2.0 DEVELOPMENT_BUILD_NUMBER=9001 print-app-version)" == '0.2.0' ]] || fail "development version should be explicit"
```

- [ ] **Step 2: Update the policy XCTest first and verify red state**

In `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`, replace the old Makefile version assertions at lines 21-24 with:

```swift
XCTAssertFalse(makefile.contains("VERSION ?="))
XCTAssertFalse(makefile.contains("BUILD_NUMBER ?="))
XCTAssertTrue(makefile.contains("RELEASE_RESOLVER := scripts/resolve-release-version.sh"))
XCTAssertTrue(makefile.contains("release-metadata-check:"))
XCTAssertTrue(makefile.contains("scripts/sync-release-version.sh --check"))
XCTAssertTrue(makefile.contains("print-app-version:"))
XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) version"))
XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) build"))
XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) tag"))
XCTAssertTrue(makefile.contains("CLIProxyManagerReleaseChannel"))
```

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
swift test --filter ReleaseWorkflowTests.testReleaseWorkflowBuildsAndUploadsSelfSignedDMG
```

Expected: FAIL because `sync-release-version.sh` and Makefile delegation are not implemented.

- [ ] **Step 3: Implement atomic plist synchronization**

Add a helper to `scripts/release-version-lib.sh` that resolves `PLUTIL` without exposing paths:

```bash
release_plutil() {
  printf '%s\n' "${PLUTIL:-/usr/bin/plutil}"
}
```

Create `scripts/sync-release-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-version-lib.sh"

mode="${1:-sync}"
[[ $# -le 1 ]] || release_fail 'Usage: scripts/sync-release-version.sh [--check]'
[[ "$mode" == 'sync' || "$mode" == '--check' ]] || release_fail 'Usage: scripts/sync-release-version.sh [--check]'

ARTIFACT_CHANNEL=official
unset DEVELOPMENT_VERSION DEVELOPMENT_BUILD_NUMBER
release_load_identity "$REPO_ROOT"
PLUTIL_BIN="$(release_plutil)"
plist="$REPO_ROOT/Info.plist"
actual_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)"
actual_build="$($PLUTIL_BIN -extract CFBundleVersion raw "$plist" 2>/dev/null || true)"

if [[ "$mode" == '--check' ]]; then
  status=0
  if [[ "$actual_version" != "$RELEASE_VERSION" ]]; then
    printf 'ERROR: Info.plist version mismatch: expected %s, actual %s\n' "$RELEASE_VERSION" "${actual_version:-missing}" >&2
    status=1
  fi
  if [[ "$actual_build" != "$RELEASE_BUILD" ]]; then
    printf 'ERROR: Info.plist build mismatch: expected %s, actual %s\n' "$RELEASE_BUILD" "${actual_build:-missing}" >&2
    status=1
  fi
  if [[ $status -ne 0 ]]; then
    printf 'ERROR: Run scripts/sync-release-version.sh to update the generated mirror\n' >&2
  fi
  exit "$status"
fi

staged="$(mktemp "$REPO_ROOT/.Info.plist.XXXXXX")" || release_fail 'Unable to stage the Info.plist mirror'
cleanup() { rm -f "$staged"; }
trap cleanup EXIT
cp -p "$plist" "$staged" || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -replace CFBundleShortVersionString -string "$RELEASE_VERSION" "$staged" || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -replace CFBundleVersion -string "$RELEASE_BUILD" "$staged" || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -lint "$staged" >/dev/null || release_fail 'Unable to validate the Info.plist mirror'
[[ "$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$staged")" == "$RELEASE_VERSION" ]] || release_fail 'Unable to validate the Info.plist mirror'
[[ "$($PLUTIL_BIN -extract CFBundleVersion raw "$staged")" == "$RELEASE_BUILD" ]] || release_fail 'Unable to validate the Info.plist mirror'
release_atomic_replace "$staged" "$plist"
trap - EXIT
```

Make the script executable.

- [ ] **Step 4: Replace Makefile-owned identity with resolver delegation**

At the top of `Makefile`, reject legacy official overrides before assigning derived variables:

```make
ifneq ($(filter command line environment,$(origin VERSION)),)
$(error VERSION is derived from release/version.json; edit the canonical file and run scripts/sync-release-version.sh)
endif
ifneq ($(filter command line environment,$(origin BUILD_NUMBER)),)
$(error BUILD_NUMBER is derived from release/version.json; edit the canonical file and run scripts/sync-release-version.sh)
endif

APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
ARTIFACT_CHANNEL ?= official
DEVELOPMENT_VERSION ?=
DEVELOPMENT_BUILD_NUMBER ?=
RELEASE_RESOLVER := scripts/resolve-release-version.sh
RELEASE_RESOLVE = ARTIFACT_CHANNEL="$(ARTIFACT_CHANNEL)" DEVELOPMENT_VERSION="$(DEVELOPMENT_VERSION)" DEVELOPMENT_BUILD_NUMBER="$(DEVELOPMENT_BUILD_NUMBER)" $(RELEASE_RESOLVER)
VERSION := $(shell $(RELEASE_RESOLVE) version 2>/dev/null)
BUILD_NUMBER := $(shell $(RELEASE_RESOLVE) build 2>/dev/null)
RELEASE_CHANNEL := $(shell $(RELEASE_RESOLVE) channel 2>/dev/null)
DMG_NAME := $(shell $(RELEASE_RESOLVE) dmg-name 2>/dev/null)
```

Keep `DMG_PATH := $(BUILD_DIR)/$(DMG_NAME)` so custom build directories continue to work.

Add `release-metadata-check` to `.PHONY` and define:

```make
release-metadata-check:
	@$(RELEASE_RESOLVE) validate
	@scripts/sync-release-version.sh --check
```

Replace print target recipes:

```make
print-app-version:
	@$(RELEASE_RESOLVE) version

print-build-number:
	@$(RELEASE_RESOLVE) build

print-build-tag:
	@$(RELEASE_RESOLVE) tag
```

Make `bundle` depend on `release-metadata-check` before build work:

```make
bundle: release-metadata-check swift-build $(INFO_PLIST) $(ENTITLEMENTS) $(ICON_FILE)
```

After writing bundle version/build, add channel normalization:

```make
	plutil -remove CLIProxyManagerReleaseChannel "$(CONTENTS_DIR)/Info.plist" 2>/dev/null || true
	@if [ "$(RELEASE_CHANNEL)" = "development" ]; then \
		plutil -insert CLIProxyManagerReleaseChannel -string development "$(CONTENTS_DIR)/Info.plist"; \
	fi
```

Ensure `sign-dmg` also depends on `release-metadata-check`:

```make
sign-dmg: release-metadata-check
```

Do not add a source-plist channel key. Only built development artifacts receive it.

- [ ] **Step 5: Synchronize the committed source plist**

Run:

```bash
scripts/sync-release-version.sh
scripts/sync-release-version.sh --check
plutil -extract CFBundleShortVersionString raw Info.plist
plutil -extract CFBundleVersion raw Info.plist
```

Expected output:

```text
0.1.32
35
```

- [ ] **Step 6: Run focused sync, Makefile, and policy tests**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
swift test --filter ReleaseWorkflowTests.testReleaseWorkflowBuildsAndUploadsSelfSignedDMG
make -s print-app-version
make -s print-build-number
make -s print-build-tag
```

Expected: all pass; print commands return `0.1.32`, `35`, `v0.1.32`.

- [ ] **Step 7: Commit plist and Makefile integration**

```bash
git add Makefile Info.plist scripts/release-version-lib.sh scripts/sync-release-version.sh Tests/ScriptTests/release-version-tests.sh Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift
git commit -m "build: derive app identity from release metadata (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Published Build Monotonicity and Provenance

**Files:**
- Modify: `scripts/release-version-lib.sh`
- Create: `scripts/check-release-monotonic.sh`
- Modify: `Tests/ScriptTests/release-version-tests.sh`

**Interfaces:**
- Produces `scripts/check-release-monotonic.sh [--repository OWNER/REPO] [--previous-appcast FILE] [--exclude-tag TAG] [--provenance FILE]`.
- Default provenance path: `build/release-provenance.json` under repository root.
- Adds library function `release_read_appcast_identity APPCAST_PATH` setting:
  - `APPCAST_VERSION`
  - `APPCAST_BUILD`
  - `APPCAST_TAG`
  - `APPCAST_DMG_NAME`
- Previous appcast parser requires item element/enclosure version/build parity and a GitHub-style release URL containing tag and DMG filename.

- [ ] **Step 1: Append failing appcast parser and monotonic tests**

Add fixture helpers to `Tests/ScriptTests/release-version-tests.sh`:

```bash
write_appcast() {
  local path="$1" version="$2" build="$3" enclosure_version="$4" enclosure_build="$5" tag="$6" dmg="$7"
  cat > "$path" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>$build</sparkle:version>
    <sparkle:shortVersionString>$version</sparkle:shortVersionString>
    <enclosure url="https://github.com/example/CLIProxyManager/releases/download/$tag/$dmg"
      sparkle:version="$enclosure_build"
      sparkle:shortVersionString="$enclosure_version" />
  </item></channel>
</rss>
XML
}

monotonic_repo="$sandbox/monotonic-repo"
new_repo "$monotonic_repo"
cp "$REPO_ROOT/scripts/check-release-monotonic.sh" "$monotonic_repo/scripts/check-release-monotonic.sh"
chmod +x "$monotonic_repo/scripts/check-release-monotonic.sh"
cat > "$monotonic_repo/release/version.json" <<'JSON'
{"version":"0.2.0","build":7}
JSON
previous_appcast="$sandbox/previous-appcast.xml"
write_appcast "$previous_appcast" 0.1.9 6 0.1.9 6 v0.1.9 CLIProxyManager-0.1.9.dmg

"$monotonic_repo/scripts/check-release-monotonic.sh" \
  --previous-appcast "$previous_appcast" \
  --provenance "$monotonic_repo/build/release-provenance.json"
[[ "$(plutil -extract trust raw "$monotonic_repo/build/release-provenance.json")" == 'local-fallback' ]] || fail "fallback trust mismatch"
[[ "$(plutil -extract current.build raw "$monotonic_repo/build/release-provenance.json")" == '7' ]] || fail "current provenance mismatch"
[[ "$(plutil -extract previous.build raw "$monotonic_repo/build/release-provenance.json")" == '6' ]] || fail "previous provenance mismatch"
! grep -F "$previous_appcast" "$monotonic_repo/build/release-provenance.json" >/dev/null || fail "provenance must not contain local paths"
```

Add equal/smaller and malformed fixture cases:

```bash
write_appcast "$previous_appcast" 0.2.0 7 0.2.0 7 v0.2.0 CLIProxyManager-0.2.0.dmg
assert_failure_contains 'current build 7 must be greater than previous build 7' \
  "$monotonic_repo/scripts/check-release-monotonic.sh" --previous-appcast "$previous_appcast"

write_appcast "$previous_appcast" 0.2.1 8 0.2.1 8 v0.2.1 CLIProxyManager-0.2.1.dmg
assert_failure_contains 'current build 7 must be greater than previous build 8' \
  "$monotonic_repo/scripts/check-release-monotonic.sh" --previous-appcast "$previous_appcast"

write_appcast "$previous_appcast" 0.1.9 6 0.1.9 5 v0.1.9 CLIProxyManager-0.1.9.dmg
existing_provenance="$monotonic_repo/build/release-provenance.json"
printf '%s\n' '{"existing":true}' > "$existing_provenance"
provenance_checksum="$(shasum -a 256 "$existing_provenance" | cut -d' ' -f1)"
assert_failure_contains 'appcast build mismatch between item and enclosure' \
  "$monotonic_repo/scripts/check-release-monotonic.sh" \
  --previous-appcast "$previous_appcast" \
  --provenance "$existing_provenance"
[[ "$(shasum -a 256 "$existing_provenance" | cut -d' ' -f1)" == "$provenance_checksum" ]] || fail "failed monotonic check must preserve existing provenance"
```

Add online mode with a fake `gh` command. The fake must support `release list` and `release download`, log exact calls, return empty output for `GH_SCENARIO=no-release`, and exit 71 for `GH_SCENARIO=network-failure`:

```bash
fake_gh="$sandbox/fake-gh"
cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$GH_LOG"
case "${GH_SCENARIO:-published}" in
  no-release)
    [[ "$1 $2" == 'release list' ]] || exit 72
    exit 0
    ;;
  network-failure)
    exit 71
    ;;
  published)
    if [[ "$1 $2" == 'release list' ]]; then
      printf 'v0.1.9\n'
    elif [[ "$1 $2" == 'release download' ]]; then
      output_dir=''
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == '--dir' ]]; then output_dir="$2"; shift 2; else shift; fi
      done
      cp "$GH_APPCAST" "$output_dir/appcast.xml"
    else
      exit 73
    fi
    ;;
esac
SH
chmod +x "$fake_gh"

write_appcast "$previous_appcast" 0.1.9 6 0.1.9 6 v0.1.9 CLIProxyManager-0.1.9.dmg
GH="$fake_gh" GH_LOG="$sandbox/gh.log" GH_APPCAST="$previous_appcast" \
  "$monotonic_repo/scripts/check-release-monotonic.sh" --repository example/CLIProxyManager

GH="$fake_gh" GH_LOG="$sandbox/no-release.log" GH_SCENARIO=no-release \
  "$monotonic_repo/scripts/check-release-monotonic.sh" --repository example/CLIProxyManager
[[ "$(plutil -extract source raw "$monotonic_repo/build/release-provenance.json")" == 'no-previous-release' ]] || fail "first release source mismatch"

assert_failure_contains 'Unable to query the latest published release' \
  env GH="$fake_gh" GH_LOG="$sandbox/network.log" GH_SCENARIO=network-failure \
  "$monotonic_repo/scripts/check-release-monotonic.sh" --repository example/CLIProxyManager
```

Extend the fake `gh` with an `exclude-current` scenario that returns the first tag not filtered by the supplied `--jq` expression, then assert the current partial tag is excluded:

```bash
: > "$sandbox/exclude.log"
GH="$fake_gh" GH_LOG="$sandbox/exclude.log" GH_APPCAST="$previous_appcast" GH_SCENARIO=exclude-current \
  "$monotonic_repo/scripts/check-release-monotonic.sh" \
  --repository example/CLIProxyManager \
  --exclude-tag v0.2.0

grep -F 'release download v0.1.9' "$sandbox/exclude.log" >/dev/null || fail "exclude-tag must compare against the prior release"
! grep -F 'release download v0.2.0' "$sandbox/exclude.log" >/dev/null || fail "exclude-tag must not download the partial current release"
```

Implement the fake branch as:

```bash
exclude-current)
  if [[ "$1 $2" == 'release list' ]]; then
    case "$*" in
      *'.tagName != "v0.2.0"'*) printf 'v0.1.9\n' ;;
      *) printf 'v0.2.0\n' ;;
    esac
  elif [[ "$1 $2" == 'release download' && "$3" == 'v0.1.9' ]]; then
    output_dir=''
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == '--dir' ]]; then output_dir="$2"; shift 2; else shift; fi
    done
    cp "$GH_APPCAST" "$output_dir/appcast.xml"
  else
    exit 74
  fi
  ;;
```

- [ ] **Step 2: Run the test and confirm missing checker failure**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
```

Expected: FAIL because `scripts/check-release-monotonic.sh` does not exist.

- [ ] **Step 3: Add strict appcast identity parsing to the shared library**

Implement `release_read_appcast_identity` using `XMLLINT="${XMLLINT:-/usr/bin/xmllint}"` and namespace-independent XPath through `local-name()`:

```bash
release_read_appcast_identity() {
  local appcast="$1"
  local xml="${XMLLINT:-/usr/bin/xmllint}"
  local item_version enclosure_version item_build enclosure_build enclosure_url

  "$xml" --noout "$appcast" >/dev/null 2>&1 || release_fail 'appcast.xml must be valid XML' || return 1
  item_build="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="version"])[1])' "$appcast")"
  item_version="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' "$appcast")"
  enclosure_build="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="version"])' "$appcast")"
  enclosure_version="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="shortVersionString"])' "$appcast")"
  enclosure_url="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@url)' "$appcast")"

  [[ "$item_build" =~ ^[1-9][0-9]*$ ]] || release_fail 'appcast build must be a positive integer' || return 1
  [[ "$item_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail 'appcast version must use stable SemVer x.y.z' || return 1
  [[ "$item_build" == "$enclosure_build" ]] || release_fail 'appcast build mismatch between item and enclosure' || return 1
  [[ "$item_version" == "$enclosure_version" ]] || release_fail 'appcast version mismatch between item and enclosure' || return 1

  case "$enclosure_url" in
    */releases/download/v[0-9]*/*) ;;
    *) release_fail 'appcast enclosure URL must identify a GitHub release tag and DMG' || return 1 ;;
  esac

  APPCAST_BUILD="$item_build"
  APPCAST_VERSION="$item_version"
  APPCAST_TAG="$(printf '%s' "$enclosure_url" | sed -E 's#^.*/releases/download/([^/]+)/.*$#\1#')"
  APPCAST_DMG_NAME="$(basename "$enclosure_url")"
  [[ "$APPCAST_TAG" == "v$APPCAST_VERSION" ]] || release_fail 'appcast tag must match appcast version' || return 1
  [[ "$APPCAST_DMG_NAME" == "CLIProxyManager-$APPCAST_VERSION.dmg" ]] || release_fail 'appcast DMG filename must match appcast version' || return 1
}
```

Use logical `appcast.xml` text in errors, never `$appcast`.

- [ ] **Step 4: Implement online/fallback comparison and atomic provenance**

Create `scripts/check-release-monotonic.sh` with this option parser. Resolve `GH="${GH:-gh}"`, validate repository as `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`, and require official channel.

```bash
repository=''
previous_appcast=''
exclude_tag=''
provenance_path="$REPO_ROOT/build/release-provenance.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository) [[ $# -ge 2 ]] || release_fail '--repository requires OWNER/REPO'; repository="$2"; shift 2 ;;
    --previous-appcast) [[ $# -ge 2 ]] || release_fail '--previous-appcast requires a file'; previous_appcast="$2"; shift 2 ;;
    --exclude-tag) [[ $# -ge 2 ]] || release_fail '--exclude-tag requires a tag'; exclude_tag="$2"; shift 2 ;;
    --provenance) [[ $# -ge 2 ]] || release_fail '--provenance requires a file'; provenance_path="$2"; shift 2 ;;
    *) release_fail "Unknown option: $1" ;;
  esac
done

[[ -z "$exclude_tag" || "$exclude_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail '--exclude-tag must use vX.Y.Z'
if [[ -z "$repository" && -z "$previous_appcast" ]]; then
  repository="$($GH repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || release_fail 'Unable to determine the GitHub repository'
fi
[[ -z "$repository" || "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_fail 'Repository must use OWNER/REPO'
[[ -z "$previous_appcast" || -f "$previous_appcast" ]] || release_fail 'The explicit previous appcast does not exist'
```

Online latest-tag lookup:

```bash
latest_tag="$($GH release list \
  --repo "$repository" \
  --exclude-drafts \
  --exclude-pre-releases \
  --limit 100 \
  --json tagName \
  --jq ".[] | select(.tagName != \"$exclude_tag\") | .tagName" 2>/dev/null | sed -n '1p')" ||
  release_fail 'Unable to query the latest published release'
```

If `latest_tag` is empty, write `previous: null` provenance and pass. Otherwise download only `appcast.xml` to a temporary directory and call `release_read_appcast_identity`. Require `APPCAST_TAG == latest_tag`.

Fallback mode skips release-list/download, parses the supplied file, and sets:

```bash
trust='local-fallback'
source_name='explicit-previous-appcast'
```

Online mode sets:

```bash
trust='official'
source_name='github-release-appcast'
```

Compare numerically using Bash arithmetic only after positive-integer validation:

```bash
if (( RELEASE_BUILD <= APPCAST_BUILD )); then
  release_fail "current build $RELEASE_BUILD must be greater than previous build $APPCAST_BUILD"
fi
```

Write provenance to a same-directory temporary file with fixed validated values, run `plutil -lint`, then call `release_atomic_replace`. For first release emit:

```json
{
  "trust": "official",
  "current": {"version": "0.2.0", "build": 7, "tag": "v0.2.0"},
  "previous": null,
  "source": "no-previous-release"
}
```

- [ ] **Step 5: Run monotonic tests and inspect real latest release without publishing**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
mkdir -p build
if scripts/check-release-monotonic.sh \
  --repository woosublee/CLIProxyManager \
  --provenance build/release-provenance.json \
  >build/monotonic-check.out 2>build/monotonic-check.err; then
  printf 'FAIL: published build 35 should reject current build 35\n' >&2
  exit 1
fi
grep -F 'current build 35 must be greater than previous build 35' build/monotonic-check.err
rm -f build/monotonic-check.out build/monotonic-check.err build/release-provenance.json
```

Expected: script tests pass and the guarded real check confirms the exact monotonic rejection without publishing or leaving provenance behind.

- [ ] **Step 6: Commit monotonic release validation**

```bash
git add scripts/release-version-lib.sh scripts/check-release-monotonic.sh Tests/ScriptTests/release-version-tests.sh
git commit -m "feat: enforce monotonic release builds (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Artifact Identity Parity Verifier

**Files:**
- Create: `scripts/verify-release-artifacts.sh`
- Modify: `Tests/ScriptTests/release-version-tests.sh`
- Modify: `Makefile:129-146,229-241`

**Interfaces:**
- Produces:

```text
scripts/verify-release-artifacts.sh
  [--source-plist FILE]
  [--app APP_BUNDLE]
  [--dmg DMG_FILE]
  [--appcast XML_FILE]
  [--provenance JSON_FILE]
  [--official]
```

- At least one artifact option is required.
- `--official` requires canonical official identity and rejects `CLIProxyManagerReleaseChannel=development` and `-development.dmg`.
- DMG verification mounts read-only/no-browse through `HDIUTIL="${HDIUTIL:-/usr/bin/hdiutil}"` and always detaches in cleanup.

- [ ] **Step 1: Append failing parity tests with logical mismatch assertions**

In the test sandbox, create canonical source and app plists, fake DMG, appcast, and provenance:

```bash
verify_repo="$sandbox/verify-repo"
new_repo "$verify_repo"
cp "$REPO_ROOT/scripts/verify-release-artifacts.sh" "$verify_repo/scripts/verify-release-artifacts.sh"
chmod +x "$verify_repo/scripts/verify-release-artifacts.sh"
cat > "$verify_repo/release/version.json" <<'JSON'
{"version":"0.2.0","build":7}
JSON
mkdir -p "$verify_repo/build/CLIProxyManager.app/Contents"
cat > "$verify_repo/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
PLIST
cp "$verify_repo/Info.plist" "$verify_repo/build/CLIProxyManager.app/Contents/Info.plist"
printf 'fake dmg' > "$verify_repo/build/CLIProxyManager-0.2.0.dmg"
write_appcast "$verify_repo/build/appcast.xml" 0.2.0 7 0.2.0 7 v0.2.0 CLIProxyManager-0.2.0.dmg
cat > "$verify_repo/build/release-provenance.json" <<'JSON'
{"trust":"official","current":{"version":"0.2.0","build":7,"tag":"v0.2.0"},"previous":{"version":"0.1.9","build":6,"tag":"v0.1.9"},"source":"github-release-appcast"}
JSON
```

Provide a fake `hdiutil` that copies a fixture app into the requested mount point on `attach` and succeeds on `detach`:

```bash
fake_hdiutil="$sandbox/fake-hdiutil"
cat > "$fake_hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == 'attach' ]]; then
  mount=''
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == '-mountpoint' ]]; then mount="$2"; shift 2; else shift; fi
  done
  mkdir -p "$mount"
  cp -R "$HDIUTIL_APP_FIXTURE" "$mount/CLIProxyManager.app"
elif [[ "$1" == 'detach' ]]; then
  exit 0
else
  exit 64
fi
SH
chmod +x "$fake_hdiutil"
```

Assert all-artifact success:

```bash
HDIUTIL="$fake_hdiutil" HDIUTIL_APP_FIXTURE="$verify_repo/build/CLIProxyManager.app" \
  "$verify_repo/scripts/verify-release-artifacts.sh" \
  --source-plist "$verify_repo/Info.plist" \
  --app "$verify_repo/build/CLIProxyManager.app" \
  --dmg "$verify_repo/build/CLIProxyManager-0.2.0.dmg" \
  --appcast "$verify_repo/build/appcast.xml" \
  --provenance "$verify_repo/build/release-provenance.json" \
  --official
```

Then mutate one source at a time and assert exact logical errors:

```bash
plutil -replace CFBundleVersion -string 6 "$verify_repo/build/CLIProxyManager.app/Contents/Info.plist"
assert_failure_contains 'built app build mismatch: expected 7, actual 6' \
  "$verify_repo/scripts/verify-release-artifacts.sh" --app "$verify_repo/build/CLIProxyManager.app" --official
plutil -replace CFBundleVersion -string 7 "$verify_repo/build/CLIProxyManager.app/Contents/Info.plist"

cp "$verify_repo/build/CLIProxyManager-0.2.0.dmg" "$verify_repo/build/CLIProxyManager-0.2.1.dmg"
assert_failure_contains 'DMG filename mismatch: expected CLIProxyManager-0.2.0.dmg, actual CLIProxyManager-0.2.1.dmg' \
  "$verify_repo/scripts/verify-release-artifacts.sh" --dmg "$verify_repo/build/CLIProxyManager-0.2.1.dmg" --official

plutil -insert CLIProxyManagerReleaseChannel -string development "$verify_repo/build/CLIProxyManager.app/Contents/Info.plist"
assert_failure_contains 'official release cannot use a development app artifact' \
  "$verify_repo/scripts/verify-release-artifacts.sh" --app "$verify_repo/build/CLIProxyManager.app" --official
```

Capture stderr and assert it does not contain `$verify_repo`.

Pin Makefile integration in the same test:

```bash
grep -F 'scripts/verify-release-artifacts.sh --source-plist "$(INFO_PLIST)" --app "$(APP_BUNDLE)"' "$REPO_ROOT/Makefile" >/dev/null || fail "make verify must check app identity"
grep -F -- '--dmg "$(DMG_PATH)"' "$REPO_ROOT/Makefile" >/dev/null || fail "make verify-dmg must check DMG identity"
```

- [ ] **Step 2: Run parity tests and confirm missing verifier failure**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
```

Expected: FAIL because `scripts/verify-release-artifacts.sh` does not exist.

- [ ] **Step 3: Implement focused artifact readers and mismatch reporting**

Create `scripts/verify-release-artifacts.sh`. Parse options without GNU `getopt`. Load resolver identity, and if `--official` is present force `ARTIFACT_CHANNEL=official` and reject development environment variables.

Use helpers shaped as:

```bash
verify_plist_identity() {
  local logical_name="$1" plist="$2"
  local actual_version actual_build
  actual_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)"
  actual_build="$($PLUTIL_BIN -extract CFBundleVersion raw "$plist" 2>/dev/null || true)"
  [[ "$actual_version" == "$RELEASE_VERSION" ]] || release_fail "$logical_name version mismatch: expected $RELEASE_VERSION, actual ${actual_version:-missing}"
  [[ "$actual_build" == "$RELEASE_BUILD" ]] || release_fail "$logical_name build mismatch: expected $RELEASE_BUILD, actual ${actual_build:-missing}"
}

verify_appcast() {
  release_read_appcast_identity "$1"
  [[ "$APPCAST_VERSION" == "$RELEASE_VERSION" ]] || release_fail "appcast version mismatch: expected $RELEASE_VERSION, actual $APPCAST_VERSION"
  [[ "$APPCAST_BUILD" == "$RELEASE_BUILD" ]] || release_fail "appcast build mismatch: expected $RELEASE_BUILD, actual $APPCAST_BUILD"
  [[ "$APPCAST_TAG" == "$RELEASE_TAG" ]] || release_fail "appcast tag mismatch: expected $RELEASE_TAG, actual $APPCAST_TAG"
  [[ "$APPCAST_DMG_NAME" == "$RELEASE_DMG_NAME" ]] || release_fail "appcast DMG filename mismatch: expected $RELEASE_DMG_NAME, actual $APPCAST_DMG_NAME"
}
```

For provenance use `plutil -extract current.version`, `current.build`, and `current.tag`. In official mode also require `trust` to be `official` or `local-fallback`, and preserve the trust value rather than normalizing it.

For DMG:

1. Verify `basename "$dmg" == "$RELEASE_DMG_NAME"`.
2. Create a temporary mount directory.
3. Attach with `-readonly -nobrowse -quiet -mountpoint`.
4. Verify `CLIProxyManager.app/Contents/Info.plist`.
5. Detach in a trap, with one normal and one `-force` attempt.

The script must print only logical names such as `source Info.plist`, `built app`, `DMG`, `DMG app`, `appcast`, and `provenance`.

- [ ] **Step 4: Integrate parity checks into Makefile verify targets**

At the end of `verify`, after structural checks, call:

```make
	scripts/verify-release-artifacts.sh --source-plist "$(INFO_PLIST)" --app "$(APP_BUNDLE)"
```

At the end of `verify-dmg`, call:

```make
	scripts/verify-release-artifacts.sh --source-plist "$(INFO_PLIST)" --app "$(APP_BUNDLE)" --dmg "$(DMG_PATH)"
```

Do not pass `--official` from generic Make targets; this lets an explicitly marked development artifact validate against its development identity. Official release scripts pass `--official` themselves.

- [ ] **Step 5: Run parity and existing DMG policy tests**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
swift test --filter ReleaseWorkflowTests
```

Expected: PASS. Do not run full DMG construction yet; Task 8 performs development artifact validation after all release consumers are migrated.

- [ ] **Step 6: Commit artifact parity verification**

```bash
git add scripts/verify-release-artifacts.sh Tests/ScriptTests/release-version-tests.sh Makefile
git commit -m "test: verify release artifact identity parity (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Canonical Sparkle Appcast Generation

**Files:**
- Modify: `scripts/generate-sparkle-appcast.sh:1-119`
- Modify: `Tests/ScriptTests/generate-sparkle-appcast-tests.sh:1-123`

**Interfaces:**
- Appcast identity comes only from `scripts/resolve-release-version.sh shell`.
- Allowed configuration remains `REPOSITORY`, `APP_NAME`, `APPCAST_PATH`, `SPARKLE_PRIVATE_KEY`, `SPARKLE_SIGN_UPDATE`, `SPARKLE_VERSION`, and Keychain service/account variables.
- Setting any of `VERSION`, `BUILD_NUMBER`, `RELEASE_TAG`, or `DMG_PATH` is an error.
- The final appcast is moved into place only after XML and canonical identity verification.

- [ ] **Step 1: Rewrite appcast tests for sandbox canonical identity and legacy override rejection**

Update `Tests/ScriptTests/generate-sparkle-appcast-tests.sh` so it creates a sandbox repo and copies:

```bash
mkdir -p "$sandbox/repo/scripts" "$sandbox/repo/release" "$sandbox/repo/build"
cp "$REPO_ROOT/scripts/generate-sparkle-appcast.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/resolve-release-version.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/release-version-lib.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/verify-release-artifacts.sh" "$sandbox/repo/scripts/"
chmod +x "$sandbox/repo/scripts/"*.sh
cat > "$sandbox/repo/release/version.json" <<'JSON'
{"version":"0.2.0","build":7}
JSON
printf 'fake dmg contents' > "$sandbox/repo/build/CLIProxyManager-0.2.0.dmg"
```

Invoke the copied generator without identity variables:

```bash
SPARKLE_PRIVATE_KEY='test-private-key' \
SPARKLE_SIGN_UPDATE="$fake_sign_update" \
REPOSITORY='woosublee/CLIProxyManager' \
APPCAST_PATH="$sandbox/repo/build/appcast.xml" \
"$sandbox/repo/scripts/generate-sparkle-appcast.sh"
```

Use these exact success assertions:

```bash
[[ -f "$sandbox/repo/build/appcast.xml" ]] || fail "appcast.xml should be generated"
grep -q '<sparkle:version>7</sparkle:version>' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical build"
grep -q '<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical version"
grep -q 'releases/download/v0.2.0/CLIProxyManager-0.2.0.dmg' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical release URL"
grep -q 'sparkle:edSignature="fake-ed-signature"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include EdDSA signature"
grep -q 'length="17"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include the exact DMG byte length"
grep -q 'type="application/octet-stream"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include enclosure MIME type"
```

Add rejection cases:

```bash
for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  if env "$legacy_name=unexpected" \
    SPARKLE_PRIVATE_KEY='test-private-key' \
    SPARKLE_SIGN_UPDATE="$fake_sign_update" \
    APPCAST_PATH="$sandbox/repo/build/rejected.xml" \
    "$sandbox/repo/scripts/generate-sparkle-appcast.sh" \
    >"$sandbox/$legacy_name.out" 2>"$sandbox/$legacy_name.err"; then
    fail "$legacy_name override should fail"
  fi
  grep -F "$legacy_name is derived from release/version.json" "$sandbox/$legacy_name.err" >/dev/null || fail "$legacy_name rejection should explain canonical source"
done
```

Add atomic preservation coverage:

```bash
printf '<rss><channel><title>existing</title></channel></rss>\n' > "$sandbox/repo/build/appcast.xml"
existing_checksum="$(shasum -a 256 "$sandbox/repo/build/appcast.xml" | cut -d' ' -f1)"
failing_signer="$sandbox/failing-sign-update"
cat > "$failing_signer" <<'SH'
#!/usr/bin/env bash
exit 42
SH
chmod +x "$failing_signer"

if SPARKLE_PRIVATE_KEY='test-private-key' \
  SPARKLE_SIGN_UPDATE="$failing_signer" \
  APPCAST_PATH="$sandbox/repo/build/appcast.xml" \
  "$sandbox/repo/scripts/generate-sparkle-appcast.sh"; then
  fail "signing failure should abort appcast generation"
fi

preserved_checksum="$(shasum -a 256 "$sandbox/repo/build/appcast.xml" | cut -d' ' -f1)"
[[ "$existing_checksum" == "$preserved_checksum" ]] || fail "failed generation must preserve the previous appcast"
```

- [ ] **Step 2: Run appcast tests and verify they fail against legacy env behavior**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: FAIL because the current generator requires `VERSION`, `BUILD_NUMBER`, `RELEASE_TAG`, and `DMG_PATH`.

- [ ] **Step 3: Replace environment-owned identity with resolver output**

At the top of `scripts/generate-sparkle-appcast.sh`, source the library and reject legacy variables by presence, not only non-empty value:

```bash
for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  if [[ -n "${!legacy_name+x}" ]]; then
    fail "$legacy_name is derived from release/version.json; remove the override"
  fi
done

[[ "${ARTIFACT_CHANNEL:-official}" == 'official' ]] || fail 'Sparkle appcasts can only be generated for official artifacts'
eval "$("$SCRIPT_DIR/resolve-release-version.sh" shell)"
APP_VERSION="$RELEASE_VERSION"
APP_BUILD="$RELEASE_BUILD"
APP_TAG="$RELEASE_TAG"
CANONICAL_DMG_PATH="$REPO_ROOT/$RELEASE_DMG_PATH"
```

Replace every later identity reference with these local names. Keep `APPCAST_PATH` configurable; if relative, resolve it under `REPO_ROOT`.

- [ ] **Step 4: Make appcast output atomic and self-verifying**

Generate XML into a same-directory staged path:

```bash
appcast_dir="$(dirname "$APPCAST_PATH")"
mkdir -p "$appcast_dir"
staged_appcast="$(mktemp "$appcast_dir/.appcast.xml.XXXXXX")"
cleanup() { rm -f "$staged_appcast"; }
trap cleanup EXIT
```

Write to `$staged_appcast`, then run:

```bash
"$SCRIPT_DIR/verify-release-artifacts.sh" --appcast "$staged_appcast" --official
release_atomic_replace "$staged_appcast" "$APPCAST_PATH"
trap - EXIT
```

Keep the private key on stdin to `sign_update`; never write it to provenance or logs.

- [ ] **Step 5: Run appcast tests and canonical parity test**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
bash Tests/ScriptTests/release-version-tests.sh
```

Expected: both pass.

- [ ] **Step 6: Commit appcast migration**

```bash
git add scripts/generate-sparkle-appcast.sh Tests/ScriptTests/generate-sparkle-appcast-tests.sh
git commit -m "build: generate appcast from canonical identity (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Safe Local Release Orchestration

**Files:**
- Modify: `scripts/release-local.sh:1-47`
- Modify: `Tests/ScriptTests/release-local-tests.sh:1-174`

**Interfaces:**
- CLI:

```text
scripts/release-local.sh RELEASE_TAG [--previous-appcast FILE]
```

- `ALLOW_LOCAL_RELEASE_CLOBBER=1` means resume a verified partial publish only.
- Normal mode requires remote tag absence, creates a lightweight tag at current `HEAD`, pushes it, creates the release, and uploads three assets.
- Resume mode requires remote tag to resolve to current `HEAD` and refuses if the release already contains a valid canonical appcast.

- [ ] **Step 1: Rewrite local release tests around copied orchestration scripts**

Change the test harness to copy `scripts/release-local.sh` into `$repo/scripts` and invoke the copy, so relative consumer scripts can be replaced with deterministic fakes:

```bash
mkdir -p "$repo/scripts" "$repo/build"
cp "$REPO_ROOT/scripts/release-local.sh" "$repo/scripts/release-local.sh"
chmod +x "$repo/scripts/release-local.sh"
release_script="$repo/scripts/release-local.sh"
```

Create fake scripts that log calls and return canonical values:

```bash
cat > "$repo/scripts/resolve-release-version.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  validate) ;;
  tag) printf 'v1.2.3\n' ;;
  shell)
    printf '%s\n' \
      "RELEASE_CHANNEL='official'" \
      "RELEASE_VERSION='1.2.3'" \
      "RELEASE_BUILD='42'" \
      "RELEASE_TAG='v1.2.3'" \
      "RELEASE_DMG_NAME='CLIProxyManager-1.2.3.dmg'" \
      "RELEASE_DMG_PATH='build/CLIProxyManager-1.2.3.dmg'" \
      "RELEASE_APPCAST_PATH='build/appcast.xml'"
    ;;
  *) exit 64 ;;
esac
SH

cat > "$repo/scripts/sync-release-version.sh" <<'SH'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
[[ "$*" == '--check' ]]
SH

cat > "$repo/scripts/check-release-monotonic.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'monotonic %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
[[ "${MONOTONIC_SCENARIO:-pass}" == 'pass' ]] || exit 59
mkdir -p build
printf '%s\n' '{"trust":"official","current":{"version":"1.2.3","build":42,"tag":"v1.2.3"},"previous":{"version":"1.2.2","build":41,"tag":"v1.2.2"},"source":"github-release-appcast"}' > build/release-provenance.json
SH

cat > "$repo/scripts/verify-release-artifacts.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify-artifacts %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "${VERIFY_SCENARIO:-pass}" in
  pass) exit 0 ;;
  fail-final)
    case " $* " in
      *' --source-plist '*) exit 60 ;;
      *) exit 0 ;;
    esac
    ;;
  valid-existing)
    case " $* " in
      *' --appcast '* ) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 61 ;;
esac
SH

cat > "$repo/scripts/generate-sparkle-appcast.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'appcast\n' >> "$RELEASE_LOCAL_TEST_LOG"
printf '<rss />\n' > build/appcast.xml
SH

chmod +x "$repo/scripts/"*.sh
```

Keep fake `security`, `make`, and appcast generation, but change fake `make` expectation to:

```bash
[[ "$*" == 'verify-dmg' ]] || exit 20
```

Create fake `git`:

```bash
cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$1" in
  rev-parse)
    [[ "$2" == 'HEAD' ]] || exit 80
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    ;;
  ls-remote)
    case "${RELEASE_LOCAL_GIT_SCENARIO:-absent}" in
      absent) exit 0 ;;
      matching)
        printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.2.3\n'
        ;;
      other)
        printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.2.3\n'
        ;;
      network) exit 81 ;;
    esac
    ;;
  tag)
    [[ "$*" == 'tag v1.2.3 HEAD' ]] || exit 82
    ;;
  push)
    [[ "$*" == 'push origin refs/tags/v1.2.3' ]] || exit 83
    ;;
  *) exit 84 ;;
esac
SH
chmod +x "$fake_bin/git"
```

Create fake `gh` with repository lookup, partial-release asset lookup, appcast download, creation, and upload:

```bash
cat > "$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$1 $2" in
  'repo view')
    printf 'example/CLIProxyManager\n'
    ;;
  'release view')
    case "${RELEASE_LOCAL_RELEASE_SCENARIO:-missing}" in
      missing) exit 1 ;;
      no-appcast) printf 'CLIProxyManager-1.2.3.dmg\n' ;;
      valid-appcast) printf 'appcast.xml\n' ;;
      network) exit 90 ;;
    esac
    ;;
  'release download')
    output_dir=''
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == '--dir' ]]; then output_dir="$2"; shift 2; else shift; fi
    done
    mkdir -p "$output_dir"
    cp "$RELEASE_LOCAL_EXISTING_APPCAST" "$output_dir/appcast.xml"
    ;;
  'release create')
    exit 0
    ;;
  'release upload')
    exit 0
    ;;
  'api repos/example/CLIProxyManager')
    [[ "${RELEASE_LOCAL_RELEASE_SCENARIO:-missing}" != 'network' ]] || exit 91
    printf '{}\n'
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 92
    ;;
esac
SH
chmod +x "$fake_bin/gh"
```

The normal happy-path expected call order must include both read-only tag checks and then the remote writes:

```text
sync --check
gh repo view --json nameWithOwner --jq .nameWithOwner
git ls-remote --tags origin refs/tags/v1.2.3 refs/tags/v1.2.3^{}
monotonic --repository example/CLIProxyManager --provenance build/release-provenance.json
security find-identity -v -p codesigning
make verify-dmg
appcast
verify-artifacts --source-plist Info.plist --app build/CLIProxyManager.app --dmg build/CLIProxyManager-1.2.3.dmg --appcast build/appcast.xml --provenance build/release-provenance.json --official
monotonic --repository example/CLIProxyManager --provenance build/release-provenance.json
git ls-remote --tags origin refs/tags/v1.2.3 refs/tags/v1.2.3^{}
git tag v1.2.3 HEAD
git push origin refs/tags/v1.2.3
gh release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes-file build/release-notes.md
gh release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml build/release-provenance.json
```

Add a reusable assertion and use it after tag mismatch, `MONOTONIC_SCENARIO=fail`, and `VERIFY_SCENARIO=fail-final` runs:

```bash
assert_no_remote_writes() {
  local log_file="$1"
  ! grep -E 'git (tag|push)|gh release (create|upload)' "$log_file" >/dev/null ||
    fail "failure path must not write tags or releases"
}
```

For fallback, create a fixture and invoke:

```bash
previous_fixture="$sandbox/previous-appcast.xml"
printf '<rss />\n' > "$previous_fixture"
"$repo/scripts/release-local.sh" v1.2.3 --previous-appcast "$previous_fixture"
```

Assert both monotonic log lines contain the exact `--previous-appcast $previous_fixture` argument, while `build/release-notes.md` contains `explicit local fallback appcast` and does not contain `$previous_fixture`:

```bash
[[ "$(grep -F -- "--previous-appcast $previous_fixture" "$log" | wc -l | tr -d '[:space:]')" == '2' ]] || fail "fallback source must be checked twice"
grep -F 'explicit local fallback appcast' "$repo/build/release-notes.md" >/dev/null || fail "fallback trust must be documented"
! grep -F "$previous_fixture" "$repo/build/release-notes.md" >/dev/null || fail "release notes must not expose the fallback path"
```

Run these resume scenarios with exact expectations:

```bash
RELEASE_LOCAL_GIT_SCENARIO=matching \
RELEASE_LOCAL_RELEASE_SCENARIO=no-appcast \
ALLOW_LOCAL_RELEASE_CLOBBER=1 \
"$repo/scripts/release-local.sh" v1.2.3
```

The log must omit `git tag` and `git push`, and end with:

```text
gh release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml build/release-provenance.json --clobber
```

Exercise the rejected resume states explicitly:

```bash
other_log="$sandbox/other-tag.log"
if PATH="$fake_bin:$PATH" RELEASE_LOCAL_TEST_LOG="$other_log" \
  RELEASE_LOCAL_GIT_SCENARIO=other ALLOW_LOCAL_RELEASE_CLOBBER=1 \
  "$repo/scripts/release-local.sh" v1.2.3; then
  fail "resume must reject a tag pointing to another commit"
fi
! grep -F 'make verify-dmg' "$other_log" >/dev/null || fail "tag mismatch must fail before build"

existing_appcast="$sandbox/existing-appcast.xml"
printf '<rss />\n' > "$existing_appcast"
valid_log="$sandbox/valid-existing.log"
if PATH="$fake_bin:$PATH" RELEASE_LOCAL_TEST_LOG="$valid_log" \
  RELEASE_LOCAL_GIT_SCENARIO=matching \
  RELEASE_LOCAL_RELEASE_SCENARIO=valid-appcast \
  RELEASE_LOCAL_EXISTING_APPCAST="$existing_appcast" \
  VERIFY_SCENARIO=valid-existing \
  ALLOW_LOCAL_RELEASE_CLOBBER=1 \
  "$repo/scripts/release-local.sh" v1.2.3 \
  >"$sandbox/valid-existing.out" 2>"$sandbox/valid-existing.err"; then
  fail "resume must reject an already valid appcast"
fi
grep -F 'A valid canonical appcast is already published; clobber is not allowed' "$sandbox/valid-existing.err" >/dev/null || fail "valid existing appcast rejection missing"
assert_no_remote_writes "$valid_log"
```

- [ ] **Step 2: Run local release tests and confirm orchestration failure**

Run:

```bash
bash Tests/ScriptTests/release-local-tests.sh
```

Expected: FAIL because the current script reads tag/plist directly and does not call the new preflight scripts.

- [ ] **Step 3: Implement strict argument and legacy override validation**

At script startup:

```bash
[[ $# -eq 1 || $# -eq 3 ]] || fail 'Usage: scripts/release-local.sh RELEASE_TAG [--previous-appcast FILE]'
INPUT_TAG="$1"
PREVIOUS_APPCAST=''
if [[ $# -eq 3 ]]; then
  [[ "$2" == '--previous-appcast' ]] || fail 'Usage: scripts/release-local.sh RELEASE_TAG [--previous-appcast FILE]'
  PREVIOUS_APPCAST="$3"
  [[ -f "$PREVIOUS_APPCAST" ]] || fail 'The explicit previous appcast does not exist'
fi

for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  [[ -z "${!legacy_name+x}" ]] || fail "$legacy_name is derived from release/version.json; remove the override"
done

cd "$REPO_ROOT"
eval "$("$SCRIPT_DIR/resolve-release-version.sh" shell)"
[[ "$RELEASE_CHANNEL" == 'official' ]] || fail 'Local releases require the official artifact channel'
[[ "$INPUT_TAG" == "$RELEASE_TAG" ]] || fail "Release tag mismatch: expected $RELEASE_TAG, actual $INPUT_TAG"

APP_VERSION="$RELEASE_VERSION"
APP_BUILD="$RELEASE_BUILD"
CANONICAL_TAG="$RELEASE_TAG"
PROVENANCE_PATH='build/release-provenance.json'
RELEASE_NOTES_PATH='build/release-notes.md'
"$SCRIPT_DIR/sync-release-version.sh" --check
if [[ -z "${REPOSITORY:-}" ]]; then
  REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || fail 'Unable to determine the GitHub repository'
fi
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Repository must use OWNER/REPO'
```

Use only these local names after evaluation; do not reassign resolver-owned variables.

- [ ] **Step 4: Implement normal and resume remote tag state checks**

Add helpers:

```bash
remote_tag_commit() {
  local tag="$1"
  local output direct peeled
  if ! output="$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"; then
    fail 'Unable to query the remote release tag'
  fi
  direct="$(printf '%s\n' "$output" | grep -F "refs/tags/$tag" | grep -Fv "refs/tags/$tag^{}" | sed -n '1p' | cut -f1 || true)"
  peeled="$(printf '%s\n' "$output" | grep -F "refs/tags/$tag^{}" | sed -n '1p' | cut -f1 || true)"
  printf '%s\n' "${peeled:-$direct}"
}
```

Use the helper before build:

```bash
initial_remote_commit="$(remote_tag_commit "$CANONICAL_TAG")"
resume_mode=0
release_exists=0
if [[ "${ALLOW_LOCAL_RELEASE_CLOBBER:-}" == '1' ]]; then
  resume_mode=1
  head_commit="$(git rev-parse HEAD)"
  [[ -n "$initial_remote_commit" ]] || fail 'Resume requires an existing remote release tag'
  [[ "$initial_remote_commit" == "$head_commit" ]] || fail 'Remote release tag points to a different commit'
else
  [[ -z "$initial_remote_commit" ]] || fail "Release tag $CANONICAL_TAG already exists on origin"
fi
```

In resume mode, inspect release state without treating every `gh release view` failure as absence:

```bash
if [[ "$resume_mode" == '1' ]]; then
  if assets="$(gh release view "$CANONICAL_TAG" --json assets --jq '.assets[].name' 2>/dev/null)"; then
    release_exists=1
  else
    gh api "repos/$REPOSITORY" >/dev/null 2>&1 || fail 'Unable to query the partial GitHub Release'
    release_exists=0
    assets=''
  fi

  if printf '%s\n' "$assets" | grep -Fx 'appcast.xml' >/dev/null; then
    existing_dir="$(mktemp -d /tmp/cliproxymanager-existing-release.XXXXXX)"
    cleanup_existing() { rm -rf "$existing_dir"; }
    trap cleanup_existing EXIT
    gh release download "$CANONICAL_TAG" --pattern appcast.xml --dir "$existing_dir" || fail 'Unable to download the existing release appcast'
    if "$SCRIPT_DIR/verify-release-artifacts.sh" --appcast "$existing_dir/appcast.xml" --official; then
      fail 'A valid canonical appcast is already published; clobber is not allowed'
    fi
    cleanup_existing
    trap - EXIT
  fi
fi
```

Add `--exclude-tag "$CANONICAL_TAG"` to both monotonic checks in resume mode. A missing release or missing/invalid appcast may resume only after the repository connectivity check succeeds; download/API failure remains fail closed.

- [ ] **Step 5: Implement preflight, build, repeated check, tag, and upload order**

Use one Bash array for monotonic arguments:

```bash
monotonic_args=(--repository "$REPOSITORY" --provenance "$PROVENANCE_PATH")
if [[ -n "$PREVIOUS_APPCAST" ]]; then
  monotonic_args+=(--previous-appcast "$PREVIOUS_APPCAST")
fi
if [[ "$resume_mode" == '1' ]]; then
  monotonic_args+=(--exclude-tag "$CANONICAL_TAG")
fi
```

Bash 3.2 indexed arrays are supported.

Execute:

```bash
"$SCRIPT_DIR/check-release-monotonic.sh" "${monotonic_args[@]}"
security find-identity -v -p codesigning | grep -F '"cliproxymanager"' >/dev/null || fail 'cliproxymanager code signing identity is required. Confirm it exists with: security find-identity -v -p codesigning.'
make verify-dmg
"$SCRIPT_DIR/generate-sparkle-appcast.sh"
"$SCRIPT_DIR/verify-release-artifacts.sh" \
  --source-plist Info.plist \
  --app build/CLIProxyManager.app \
  --dmg "$RELEASE_DMG_PATH" \
  --appcast "$RELEASE_APPCAST_PATH" \
  --provenance "$PROVENANCE_PATH" \
  --official
"$SCRIPT_DIR/check-release-monotonic.sh" "${monotonic_args[@]}"
final_remote_commit="$(remote_tag_commit "$CANONICAL_TAG")"
if [[ "$resume_mode" == '1' ]]; then
  [[ "$final_remote_commit" == "$head_commit" ]] || fail 'Remote release tag changed while artifacts were building'
else
  [[ -z "$final_remote_commit" ]] || fail "Release tag $CANONICAL_TAG appeared while artifacts were building"
fi
```

Write `build/release-notes.md` without raw fallback path. In normal mode create and push the canonical lightweight tag, then create the release:

```bash
if [[ "$resume_mode" == '0' ]]; then
  git tag "$CANONICAL_TAG" HEAD
  git push origin "refs/tags/$CANONICAL_TAG"
fi

if [[ "$release_exists" == '0' ]]; then
  gh release create "$CANONICAL_TAG" --verify-tag --title "CLIProxyManager $APP_VERSION" --notes-file "$RELEASE_NOTES_PATH"
fi

if [[ "$resume_mode" == '1' ]]; then
  gh release upload "$CANONICAL_TAG" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH" "$PROVENANCE_PATH" --clobber
else
  gh release upload "$CANONICAL_TAG" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH" "$PROVENANCE_PATH"
fi
```

- [ ] **Step 6: Run local release and shared script tests**

Run:

```bash
bash Tests/ScriptTests/release-local-tests.sh
bash Tests/ScriptTests/release-version-tests.sh
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: all pass. No test may call the real GitHub API, mutate real tags, or access the real signing Keychain.

- [ ] **Step 7: Commit local release migration**

```bash
git add scripts/release-local.sh Tests/ScriptTests/release-local-tests.sh
git commit -m "build: gate local releases on canonical identity (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: GitHub Actions Release Parity

**Files:**
- Modify: `.github/workflows/release.yml:1-175`
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift:94-154`

**Interfaces:**
- Workflow input remains `tag`.
- Resolve step outputs remain `tag`, `version`, `build_number`, `dmg_path`, and `appcast_path`, plus `provenance_path`.
- Official CI calls the same resolver, source mirror check, monotonic checker, appcast generator, and artifact verifier as local release.
- Concurrency group is exactly `cliproxymanager-official-release` with `cancel-in-progress: false`.

- [ ] **Step 1: Replace workflow assertions first**

In `ReleaseWorkflowTests.swift`, remove assertions for inline SemVer parsing and Make overrides. Add:

```swift
XCTAssertTrue(workflow.contains("concurrency:"))
XCTAssertTrue(workflow.contains("group: cliproxymanager-official-release"))
XCTAssertTrue(workflow.contains("cancel-in-progress: false"))
XCTAssertTrue(workflow.contains("scripts/resolve-release-version.sh shell"))
XCTAssertTrue(workflow.contains("scripts/sync-release-version.sh --check"))
XCTAssertTrue(workflow.contains("scripts/check-release-monotonic.sh"))
XCTAssertTrue(workflow.contains("scripts/verify-release-artifacts.sh"))
XCTAssertTrue(workflow.contains("provenance_path=build/release-provenance.json"))
XCTAssertFalse(workflow.contains("APP_VERSION=\"$(make -s print-app-version)\""))
XCTAssertFalse(workflow.contains("BUILD_NUMBER=\"$(make -s print-build-number)\""))
XCTAssertFalse(workflow.contains("VERSION=\"${{ steps.version.outputs.version }}\""))
XCTAssertFalse(workflow.contains("BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\""))
XCTAssertFalse(workflow.contains("RELEASE_TAG: ${{ steps.version.outputs.tag }}"))
XCTAssertFalse(workflow.contains("DMG_PATH: ${{ steps.version.outputs.dmg_path }}"))
XCTAssertTrue(workflow.contains("${{ steps.version.outputs.provenance_path }}"))
```

Add occurrence counting to prove monotonic validation runs twice:

```swift
XCTAssertEqual(
    workflow.components(separatedBy: "scripts/check-release-monotonic.sh").count - 1,
    2
)
```

Keep ordering assertions, updated to:

```swift
assert("- name: Verify release artifacts", appearsBefore: "- name: Recheck published build", in: workflow)
assert("- name: Recheck published build", appearsBefore: "- name: Create tag", in: workflow)
```

- [ ] **Step 2: Run the workflow policy test and verify red state**

Run:

```bash
swift test --filter ReleaseWorkflowTests.testReleaseWorkflowBuildsAndUploadsSelfSignedDMG
```

Expected: FAIL on missing concurrency/shared script assertions.

- [ ] **Step 3: Add release workflow concurrency and canonical resolve preflight**

Under `permissions`, add:

```yaml
concurrency:
  group: cliproxymanager-official-release
  cancel-in-progress: false
```

Replace the current inline resolve script with:

```yaml
      - name: Resolve and validate release identity
        id: version
        env:
          INPUT_TAG: ${{ inputs.tag }}
        run: |
          set -euo pipefail
          scripts/resolve-release-version.sh validate
          scripts/sync-release-version.sh --check
          eval "$(scripts/resolve-release-version.sh shell)"

          if [ "$INPUT_TAG" != "$RELEASE_TAG" ]; then
            echo "Workflow tag mismatch: expected $RELEASE_TAG, actual $INPUT_TAG" >&2
            exit 1
          fi

          if git ls-remote --exit-code --tags origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
            echo "Release tag $RELEASE_TAG already exists on origin." >&2
            exit 1
          else
            status=$?
            if [ "$status" -ne 2 ]; then
              echo "Unable to query release tag $RELEASE_TAG." >&2
              exit "$status"
            fi
          fi

          scripts/check-release-monotonic.sh \
            --repository "$GITHUB_REPOSITORY" \
            --provenance build/release-provenance.json

          echo "tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT"
          echo "version=$RELEASE_VERSION" >> "$GITHUB_OUTPUT"
          echo "build_number=$RELEASE_BUILD" >> "$GITHUB_OUTPUT"
          echo "dmg_path=$RELEASE_DMG_PATH" >> "$GITHUB_OUTPUT"
          echo "appcast_path=$RELEASE_APPCAST_PATH" >> "$GITHUB_OUTPUT"
          echo "provenance_path=build/release-provenance.json" >> "$GITHUB_OUTPUT"
```

The repository check performed while writing this plan confirmed `git ls-remote --exit-code --tags origin refs/tags/<missing>` returns status `2`. Pin that behavior in `ReleaseWorkflowTests` by asserting the workflow accepts only status `2` as missing and propagates every other non-zero status.

- [ ] **Step 4: Run script tests explicitly in the workflow and remove identity overrides**

Replace the Test step with:

```yaml
      - name: Test
        run: |
          bash Tests/ScriptTests/release-version-tests.sh
          bash Tests/ScriptTests/release-local-tests.sh
          bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
          swift test
```

Change build/sign commands to:

```yaml
      - name: Build and verify self-signed DMG
        run: make CODESIGN_IDENTITY="$CODESIGN_IDENTITY" verify-dmg

      - name: Sign DMG
        run: make CODESIGN_IDENTITY="$CODESIGN_IDENTITY" sign-dmg
```

Change appcast env to identity-independent settings only:

```yaml
      - name: Generate Sparkle appcast
        env:
          REPOSITORY: ${{ github.repository }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: scripts/generate-sparkle-appcast.sh
```

- [ ] **Step 5: Add full parity and repeated monotonic checks before tag creation**

Add:

```yaml
      - name: Verify release artifacts
        run: |
          scripts/verify-release-artifacts.sh \
            --source-plist Info.plist \
            --app build/CLIProxyManager.app \
            --dmg "${{ steps.version.outputs.dmg_path }}" \
            --appcast "${{ steps.version.outputs.appcast_path }}" \
            --provenance "${{ steps.version.outputs.provenance_path }}" \
            --official

      - name: Recheck published build
        run: |
          scripts/check-release-monotonic.sh \
            --repository "$GITHUB_REPOSITORY" \
            --provenance "${{ steps.version.outputs.provenance_path }}"
          if git ls-remote --exit-code --tags origin "refs/tags/${{ steps.version.outputs.tag }}" >/dev/null 2>&1; then
            echo "Release tag ${{ steps.version.outputs.tag }} appeared while artifacts were building." >&2
            exit 1
          else
            status=$?
            if [ "$status" -ne 2 ]; then
              echo "Unable to recheck release tag ${{ steps.version.outputs.tag }}." >&2
              exit "$status"
            fi
          fi
```

Keep these steps before `Create tag`.

- [ ] **Step 6: Upload provenance and run workflow policy tests**

Add the provenance output to release files:

```yaml
          files: |
            ${{ steps.version.outputs.dmg_path }}
            ${{ steps.version.outputs.appcast_path }}
            ${{ steps.version.outputs.provenance_path }}
```

Run:

```bash
swift test --filter ReleaseWorkflowTests
bash Tests/ScriptTests/release-version-tests.sh
bash Tests/ScriptTests/release-local-tests.sh
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: all pass.

- [ ] **Step 7: Commit GitHub Actions parity**

```bash
git add .github/workflows/release.yml Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift
git commit -m "ci: share canonical release preflight (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Maintainer Documentation and Full Verification

**Files:**
- Modify: `README.md:118-132`
- Modify: `README.en.md:118-132`
- Verify: all files changed in Tasks 1-7

**Interfaces:**
- Documents one official version bump procedure and one explicit lower-trust local fallback procedure.
- Documents partial-publish resume semantics for `ALLOW_LOCAL_RELEASE_CLOBBER=1`.
- Provides a user-owned manual app UI checklist without claiming it was executed automatically.

- [ ] **Step 1: Add the Korean maintainer release section**

After the existing `cpm update apply all --yes` command block in `README.md` and before `## 로그와 진단`, add a `### Maintainer release 절차` subsection containing these exact commands and rules:

````markdown
### Maintainer release 절차

앱 version과 build number의 유일한 수동 편집 source는 `release/version.json`입니다. `Makefile`이나 `Info.plist`의 값을 직접 수정하지 마세요.

```bash
# 1. release/version.json의 version과 build를 함께 올린 뒤 plist mirror 동기화
scripts/sync-release-version.sh
scripts/sync-release-version.sh --check

# 2. identity 확인
scripts/resolve-release-version.sh json | plutil -p -

# 3. GitHub Actions의 Self-signed Release workflow를 canonical tag로 실행
scripts/resolve-release-version.sh tag
```

Official release는 source plist, GitHub tag, previous appcast build, app bundle, DMG filename, generated appcast를 비교한 뒤에만 tag와 Release를 생성합니다. Published build 이하이거나 GitHub 조회가 실패하면 release는 중단됩니다.

Local fallback은 CI release를 실행할 수 없고 이전 appcast를 별도로 검증할 수 있을 때만 사용합니다.

```bash
scripts/release-local.sh "$(scripts/resolve-release-version.sh tag)" \
  --previous-appcast /path/to/verified-previous-appcast.xml
```

Fallback artifact의 `release-provenance.json`에는 `local-fallback` trust가 기록됩니다. CI release와 local fallback을 동시에 실행하지 마세요. `ALLOW_LOCAL_RELEASE_CLOBBER=1`은 이미 성공한 release를 교체하는 옵션이 아니라, 같은 commit의 tag가 만들어진 뒤 upload만 실패한 partial publish를 재개하는 용도입니다.
````

- [ ] **Step 2: Add the English maintainer release section**

After the existing `cpm update apply all --yes` command block in `README.en.md` and before `## Logs and diagnostics`, add:

````markdown
### Maintainer release procedure

The only manually edited source for the app version and build number is `release/version.json`. Do not edit the values in `Makefile` or `Info.plist` directly; `Info.plist` is a committed generated mirror.

```bash
# 1. Update version and build together in release/version.json, then sync the plist mirror
scripts/sync-release-version.sh
scripts/sync-release-version.sh --check

# 2. Inspect the resolved identity
scripts/resolve-release-version.sh json | plutil -p -

# 3. Run the GitHub Actions Self-signed Release workflow with the canonical tag
scripts/resolve-release-version.sh tag
```

The official release compares the source plist, GitHub tag, previous appcast build, app bundle, DMG filename, and generated appcast before it creates a tag or Release. It fails closed when identity is stale, the published build is not lower, or GitHub cannot be queried.

Use the local fallback only when CI release is unavailable and you have a separately verified previous appcast.

```bash
scripts/release-local.sh "$(scripts/resolve-release-version.sh tag)" \
  --previous-appcast /path/to/verified-previous-appcast.xml
```

The fallback artifact records `local-fallback` trust in `release-provenance.json`. Do not run CI release and local fallback concurrently. `ALLOW_LOCAL_RELEASE_CLOBBER=1` does not replace a completed release; it resumes a verified partial publish where the same commit was tagged but release or asset upload failed.
````

- [ ] **Step 3: Run all focused script and policy tests**

Run:

```bash
bash Tests/ScriptTests/release-version-tests.sh
bash Tests/ScriptTests/release-local-tests.sh
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
swift test --filter ReleaseWorkflowTests
```

Expected: all pass.

- [ ] **Step 4: Run the full Swift test suite and debug build**

Run:

```bash
swift test
swift build -c debug
```

Expected: all tests pass and debug build exits 0 with no new compiler warnings attributable to #99.

- [ ] **Step 5: Build and verify the canonical development app bundle**

Run:

```bash
make CONFIGURATION=debug BUILD_DIR=build-development bundle
scripts/verify-release-artifacts.sh \
  --source-plist Info.plist \
  --app build-development/CLIProxyManager.app
plutil -extract CFBundleShortVersionString raw build-development/CLIProxyManager.app/Contents/Info.plist
plutil -extract CFBundleVersion raw build-development/CLIProxyManager.app/Contents/Info.plist
```

Expected version/build output:

```text
0.1.32
35
```

Do not launch the app automatically.

- [ ] **Step 6: Build and verify an explicitly marked development override**

Run:

```bash
make CONFIGURATION=debug \
  BUILD_DIR=build-development-override \
  ARTIFACT_CHANNEL=development \
  DEVELOPMENT_VERSION=0.1.32 \
  DEVELOPMENT_BUILD_NUMBER=9001 \
  bundle

ARTIFACT_CHANNEL=development \
DEVELOPMENT_VERSION=0.1.32 \
DEVELOPMENT_BUILD_NUMBER=9001 \
scripts/verify-release-artifacts.sh \
  --app build-development-override/CLIProxyManager.app

plutil -extract CLIProxyManagerReleaseChannel raw \
  build-development-override/CLIProxyManager.app/Contents/Info.plist
```

Expected final output: `development`. Also verify official mode rejects the same app:

```bash
if scripts/verify-release-artifacts.sh \
  --app build-development-override/CLIProxyManager.app \
  --official; then
  printf 'FAIL: official verification accepted a development artifact\n' >&2
  exit 1
fi
```

- [ ] **Step 7: Verify the real monotonic gate fails safely at the already-published build**

Run:

```bash
if scripts/check-release-monotonic.sh \
  --repository woosublee/CLIProxyManager \
  --provenance build/release-provenance.json; then
  printf 'FAIL: current build 35 should not pass against published build 35\n' >&2
  exit 1
fi
```

Expected: non-zero with `current build 35 must be greater than previous build 35`. Confirm no tag or release was created. This is a negative safety verification, not a test failure.

- [ ] **Step 8: Run static consistency checks**

Run:

```bash
scripts/sync-release-version.sh --check
! rg -n '^VERSION[[:space:]]*\?=|^BUILD_NUMBER[[:space:]]*\?=' Makefile
! rg -n 'plutil -extract CFBundleVersion raw Info.plist|VERSION="\$\{RELEASE_TAG#v\}"' scripts .github/workflows
! rg -n 'RELEASE_TAG: \$\{\{ steps.version.outputs.tag \}\}|BUILD_NUMBER: \$\{\{ steps.version.outputs.build_number \}\}|DMG_PATH: \$\{\{ steps.version.outputs.dmg_path \}\}' .github/workflows/release.yml
git diff --check
git status --short
```

Expected: all negated searches return success because no duplicate identity parsing remains; only intended modified files are listed.

- [ ] **Step 9: Commit documentation and final verification adjustments**

```bash
git add README.md README.en.md
git commit -m "docs: document canonical release workflow (#99)" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

If verification required implementation corrections, include those exact files in this commit only when the correction is inseparable from documentation; otherwise amend the owning task's commit before final review.

- [ ] **Step 10: Prepare the manual app verification checklist**

Report these user-run checks without claiming they were performed:

```text
1. Open build-development/CLIProxyManager.app.
2. Open Settings → General/About.
3. Confirm version 0.1.32 and build 35 are displayed distinctly.
4. Confirm VoiceOver reads version and build as separate values.
5. Quit the development app without modifying the installed release app.
```

Final completion report must include:

- canonical metadata path and current identity
- exact automated commands run and their exit status
- expected real monotonic negative check result
- development bundle path
- manual UI checklist status as pending user verification
