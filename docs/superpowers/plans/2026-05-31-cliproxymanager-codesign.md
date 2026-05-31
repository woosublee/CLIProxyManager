# cliproxymanager Code Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cliproxymanager` the default code signing identity for development and canonical local release builds, and remove ad-hoc signing from the default local release path.

**Architecture:** Keep signing policy centralized in `Makefile` defaults, while `scripts/release-local.sh` owns release-specific preflight checks and release upload behavior. Tests pin the new policy at the script level and the repository policy level, and README documents the canonical local release flow separately from the CI fallback.

**Tech Stack:** Bash, GNU/Unix `make`, macOS `security` and `codesign`, Swift XCTest, GitHub Actions YAML, Sparkle appcast tooling.

---

## File Structure

- Modify: `Makefile`
  - Responsibility: define project-wide default code signing identity and build/sign/DMG targets.
- Modify: `scripts/release-local.sh`
  - Responsibility: validate release tag, require the local `cliproxymanager` code signing identity, build the signed DMG, generate appcast, upload release assets.
- Modify: `Tests/ScriptTests/release-local-tests.sh`
  - Responsibility: executable script regression test for `release-local.sh` using fake `security`, `make`, appcast, and `gh` commands.
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`
  - Responsibility: policy-level tests for release workflow, `Makefile`, and local release script text.
- Modify: `README.md`
  - Responsibility: user-facing release, signing, Sparkle, and fallback workflow documentation.

---

### Task 1: Pin Makefile Signing Defaults

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Makefile`

- [ ] **Step 1: Add failing XCTest assertions for the new Makefile defaults**

In `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`, inside `testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags()`, after the `makefile` string is loaded and before existing `XCTAssertTrue(makefile.contains("scripts/verify-dmg.sh \"$(DMG_PATH)\""))`, insert these assertions:

```swift
        XCTAssertTrue(
            makefile.contains("LOCAL_CODESIGN_IDENTITY ?= cliproxymanager"),
            "Development and local release builds should default to the shared cliproxymanager signing identity."
        )
        XCTAssertTrue(
            makefile.contains("RELEASE_CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)"),
            "Release signing should use the same default identity unless explicitly overridden."
        )
        XCTAssertTrue(
            makefile.contains("CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)"),
            "Generic signing should inherit the local default identity."
        )
```

- [ ] **Step 2: Run the focused XCTest and verify it fails**

Run:

```bash
swift test --filter ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags
```

Expected: FAIL. The failure should mention the missing `LOCAL_CODESIGN_IDENTITY ?= cliproxymanager` assertion, because `Makefile` still defaults to `CLIProxyManager Local Release` and `RELEASE_CODESIGN_IDENTITY ?= -`.

- [ ] **Step 3: Update Makefile signing defaults**

In `Makefile`, replace the current signing defaults:

```make
LOCAL_CODESIGN_IDENTITY ?= CLIProxyManager Local Release
RELEASE_CODESIGN_IDENTITY ?= -
CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)
```

with:

```make
LOCAL_CODESIGN_IDENTITY ?= cliproxymanager
RELEASE_CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)
CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)
```

- [ ] **Step 4: Run the focused XCTest and verify it passes**

Run:

```bash
swift test --filter ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags
```

Expected: PASS for `ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags`.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Makefile Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift
git commit -m "Use cliproxymanager as default signing identity" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Require cliproxymanager in the Local Release Script

**Files:**
- Modify: `Tests/ScriptTests/release-local-tests.sh`
- Modify: `scripts/release-local.sh`

- [ ] **Step 1: Add a fake security command to the script test**

In `Tests/ScriptTests/release-local-tests.sh`, after the fake `plutil` block and before the fake `make` block, insert:

```bash
cat > "$fake_bin/security" <<'FAKE_SECURITY'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$*" in
  'find-identity -v -p codesigning')
    printf '  1) A39E5510B609DE50287781AFDBAE19C4F91783C7 "cliproxymanager"\n'
    printf '     1 valid identities found\n'
    ;;
  *)
    echo "unexpected security args: $*" >&2
    exit 50
    ;;
esac
FAKE_SECURITY
chmod +x "$fake_bin/security"
```

- [ ] **Step 2: Update the fake make expectation to reject ad-hoc signing**

In the fake `make` script in `Tests/ScriptTests/release-local-tests.sh`, replace:

```bash
[[ "$*" == 'CODESIGN_IDENTITY=- VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' ]] || {
```

with:

```bash
[[ "$*" == 'VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' ]] || {
```

- [ ] **Step 3: Update expected successful call order**

In the expected log block near the end of `Tests/ScriptTests/release-local-tests.sh`, replace:

```bash
  'make CODESIGN_IDENTITY=- VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' \
```

with these two lines:

```bash
  'security find-identity -v -p codesigning' \
  'make VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' \
```

- [ ] **Step 4: Update GitHub Release notes in fake gh and expected log**

In the fake `gh` case statement, replace:

```bash
  'release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Ad-hoc signed, non-notarized DMG with Sparkle appcast.')
```

with:

```bash
  'release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Non-notarized DMG signed with the local cliproxymanager code signing identity and Sparkle appcast.')
```

In the expected log block, replace:

```bash
  'gh release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Ad-hoc signed, non-notarized DMG with Sparkle appcast.' \
```

with:

```bash
  'gh release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Non-notarized DMG signed with the local cliproxymanager code signing identity and Sparkle appcast.' \
```

- [ ] **Step 5: Add a missing-identity regression case**

After the invalid tag assertion block at the end of `Tests/ScriptTests/release-local-tests.sh`, append:

```bash
cat > "$fake_bin/security" <<'FAKE_SECURITY_MISSING'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$*" in
  'find-identity -v -p codesigning')
    printf '     0 valid identities found\n'
    ;;
  *)
    echo "unexpected security args: $*" >&2
    exit 50
    ;;
esac
FAKE_SECURITY_MISSING
chmod +x "$fake_bin/security"

if (
  cd "$repo"
  PATH="$fake_bin:$PATH" \
  RELEASE_LOCAL_TEST_LOG="$sandbox/missing-identity.log" \
  "$SCRIPT" v1.2.3
) >/tmp/release-local-missing-identity.out 2>/tmp/release-local-missing-identity.err; then
  fail "release-local.sh should reject releases without the cliproxymanager signing identity"
fi

grep -q 'cliproxymanager code signing identity is required' /tmp/release-local-missing-identity.err || \
  fail "missing identity should explain the cliproxymanager requirement"
grep -q 'security find-identity -v -p codesigning' /tmp/release-local-missing-identity.err || \
  fail "missing identity should show the verification command"
```

- [ ] **Step 6: Run the script test and verify it fails**

Run:

```bash
bash Tests/ScriptTests/release-local-tests.sh
```

Expected: FAIL. The fake `make` should report unexpected args because `scripts/release-local.sh` still passes `CODESIGN_IDENTITY=-`, or the expected log should fail because the script does not call `security find-identity` yet.

- [ ] **Step 7: Add release script constants and identity preflight**

In `scripts/release-local.sh`, after the DMG path variables:

```bash
APPCAST_PATH="build/appcast.xml"
DMG_PATH="build/CLIProxyManager-${VERSION}.dmg"
```

insert:

```bash
CODESIGN_IDENTITY="cliproxymanager"
RELEASE_NOTES="Non-notarized DMG signed with the local cliproxymanager code signing identity and Sparkle appcast."
```

Then after the existing exports:

```bash
export RELEASE_TAG
export VERSION
export BUILD_NUMBER
export APPCAST_PATH
export DMG_PATH
```

insert:

```bash
if ! security find-identity -v -p codesigning | grep -F "\"${CODESIGN_IDENTITY}\"" >/dev/null; then
  fail "${CODESIGN_IDENTITY} code signing identity is required. Confirm it exists with: security find-identity -v -p codesigning. This script does not create Keychain certificates automatically."
fi
```

- [ ] **Step 8: Remove ad-hoc signing from the local release make call and update notes**

In `scripts/release-local.sh`, replace:

```bash
make CODESIGN_IDENTITY=- VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" verify-dmg
```

with:

```bash
make VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" verify-dmg
```

Then replace:

```bash
gh release create "$RELEASE_TAG" --verify-tag --title "CLIProxyManager $VERSION" --notes "Ad-hoc signed, non-notarized DMG with Sparkle appcast."
```

with:

```bash
gh release create "$RELEASE_TAG" --verify-tag --title "CLIProxyManager $VERSION" --notes "$RELEASE_NOTES"
```

- [ ] **Step 9: Run the script test and verify it passes**

Run:

```bash
bash Tests/ScriptTests/release-local-tests.sh
```

Expected: PASS with no output.

- [ ] **Step 10: Commit Task 2**

Run:

```bash
git add scripts/release-local.sh Tests/ScriptTests/release-local-tests.sh
git commit -m "Require cliproxymanager for local releases" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Update Release Policy XCTest Coverage

**Files:**
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`

- [ ] **Step 1: Load the local release script in the XCTest**

In `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`, inside `testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags()`, after the existing `workflow` and `makefile` loads:

```swift
        let releaseLocal = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/release-local.sh"), encoding: .utf8)
```

- [ ] **Step 2: Add assertions for local release identity preflight and non-ad-hoc make call**

In the same test, after the Makefile default assertions from Task 1, insert:

```swift
        XCTAssertTrue(
            releaseLocal.contains("CODESIGN_IDENTITY=\"cliproxymanager\""),
            "Local releases should name the required signing identity explicitly."
        )
        XCTAssertTrue(
            releaseLocal.contains("security find-identity -v -p codesigning"),
            "Local releases should fail before building if the cliproxymanager identity is missing."
        )
        XCTAssertTrue(
            releaseLocal.contains("make VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "Local releases should use Makefile signing defaults instead of forcing ad-hoc signing."
        )
        XCTAssertFalse(
            releaseLocal.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "The canonical local release path must not force ad-hoc signing."
        )
        XCTAssertTrue(
            releaseLocal.contains("Non-notarized DMG signed with the local cliproxymanager code signing identity and Sparkle appcast."),
            "Local release notes should describe the cliproxymanager-signed artifact."
        )
        XCTAssertFalse(
            releaseLocal.contains("Ad-hoc signed, non-notarized DMG with Sparkle appcast."),
            "Local release notes should no longer describe canonical releases as ad-hoc signed."
        )
```

- [ ] **Step 3: Keep CI fallback assertion explicit**

In the same test, replace the assertion:

```swift
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"))
```

with:

```swift
        XCTAssertTrue(
            workflow.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "The manual CI fallback may continue to use explicit ad-hoc signing until certificate import is designed."
        )
```

Keep the workflow secret, appcast, release creation, and release upload assertions unchanged for now.

- [ ] **Step 4: Run the focused XCTest and verify it passes**

Run:

```bash
swift test --filter ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags
```

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift
git commit -m "Cover local release signing policy" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Update README Signing Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the release overview text**

In `README.md`, replace lines 26-39 under `## Releases and automatic updates`:

```markdown
Release artifacts are distributed as ad-hoc signed, non-notarized DMGs on GitHub Releases. CLIProxyManager uses Sparkle 2 for automatic updates with this feed URL:
```

through:

```markdown
The app currently keeps the hardened-runtime `disable-library-validation` entitlement enabled for this ad-hoc signed Sparkle distribution path. Local release builds re-sign the bundled Sparkle framework and helper executables with an ad-hoc identity, and without this entitlement macOS can reject the app at launch because the re-signed Sparkle code is not loaded under a matching Developer ID Team ID. Revisit this when Developer ID signing and notarization are introduced.
```

with:

```markdown
Canonical local release artifacts are signed with the local `cliproxymanager` code signing identity and distributed as non-notarized DMGs on GitHub Releases. CLIProxyManager uses Sparkle 2 for automatic updates with this feed URL:

```text
https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml
```

Each GitHub Release that should be available through automatic updates must include both:

- `CLIProxyManager-<version>.dmg`
- `appcast.xml`

Sparkle's EdDSA signature is separate from Apple Developer ID signing. The current automatic-update path can work without Apple Developer ID signing or notarization, but users may still see macOS Gatekeeper or quarantine warnings because the DMG is non-notarized and not signed with an Apple Developer ID certificate.

The app currently keeps the hardened-runtime `disable-library-validation` entitlement enabled for this non-Developer-ID Sparkle distribution path. Local release builds re-sign the bundled Sparkle framework and helper executables with the local `cliproxymanager` identity, and without this entitlement macOS can reject the app at launch because the re-signed Sparkle code is not loaded under a matching Developer ID Team ID. Revisit this when Developer ID signing and notarization are introduced.
```

- [ ] **Step 2: Add the local code signing identity requirement to the release instructions**

In `README.md`, after the paragraph ending with:

```markdown
Local release tooling reads that canonical Keychain item automatically when `SPARKLE_PRIVATE_KEY` is unset. This local Keychain path is the default release path. Do not commit `build/sparkle_private_key.txt`.
```

insert:

```markdown
Local releases also require a code signing identity named `cliproxymanager` in the local Keychain. Confirm it before cutting a release:

```zsh
security find-identity -v -p codesigning | grep '"cliproxymanager"'
```

The release script does not create code signing certificates automatically. Development and canonical local release builds both use this same `cliproxymanager` identity by default.
```

- [ ] **Step 3: Update the local release script summary**

In `README.md`, replace:

```markdown
The local release script validates the `v*` tag, reads `CFBundleVersion` from `Info.plist`, builds and verifies the ad-hoc signed DMG, generates `build/appcast.xml` using the Keychain private key, and uploads both release assets with the authenticated `gh` CLI:
```

with:

```markdown
The local release script validates the `v*` tag, requires the local `cliproxymanager` code signing identity, reads `CFBundleVersion` from `Info.plist`, builds and verifies the signed DMG, generates `build/appcast.xml` using the Keychain Sparkle private key, and uploads both release assets with the authenticated `gh` CLI:
```

- [ ] **Step 4: Update the GitHub Actions fallback paragraph**

In `README.md`, replace:

```markdown
The GitHub Actions release workflow is a manual fallback for cases where a local release is not practical. Run it with `workflow_dispatch` and an existing tag. Because CI cannot access the local Keychain, save the same private key value in the GitHub secret `SPARKLE_PRIVATE_KEY` before using that fallback. Tag pushes do not automatically run the release workflow.
```

with:

```markdown
The GitHub Actions release workflow is a manual fallback for cases where a local release is not practical. Run it with `workflow_dispatch` and an existing tag. Because CI cannot access the local Keychain, save the same Sparkle private key value in the GitHub secret `SPARKLE_PRIVATE_KEY` before using that fallback. The fallback workflow may continue to use explicit ad-hoc macOS code signing until a future certificate-import flow is added. Tag pushes do not automatically run the release workflow.
```

- [ ] **Step 5: Run grep checks for stale canonical ad-hoc wording**

Run:

```bash
grep -n "ad-hoc signed" README.md || true
grep -n "cliproxymanager" README.md
```

Expected: `ad-hoc signed` should not appear in README. `cliproxymanager` should appear in the release overview and release-cutting instructions.

- [ ] **Step 6: Commit Task 4**

Run:

```bash
git add README.md
git commit -m "Document cliproxymanager release signing" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Full Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Verify script regression tests**

Run:

```bash
bash Tests/ScriptTests/release-local-tests.sh
```

Expected: exit 0 with no failure output.

- [ ] **Step 2: Verify Swift tests**

Run:

```bash
swift test
```

Expected: exit 0 and all tests pass.

- [ ] **Step 3: Verify the local signing identity is available**

Run:

```bash
security find-identity -v -p codesigning | grep '"cliproxymanager"'
```

Expected: output contains one valid `cliproxymanager` code signing identity, for example:

```text
A39E5510B609DE50287781AFDBAE19C4F91783C7 "cliproxymanager"
```

- [ ] **Step 4: Verify app bundle signing path**

Run:

```bash
make CODESIGN_IDENTITY=cliproxymanager verify
```

Expected: exit 0 and output includes:

```text
codesign verification passed
```

- [ ] **Step 5: Optionally verify DMG signing path**

If time and local environment permit, run:

```bash
make CODESIGN_IDENTITY=cliproxymanager verify-dmg
```

Expected: exit 0 and output includes:

```text
DMG verification passed
```

If skipped, record the skip reason in the final report.

- [ ] **Step 6: Check final git status**

Run:

```bash
git status --short
```

Expected: no uncommitted files after the task commits, unless verification generated ignored build artifacts only.

- [ ] **Step 7: Report verification evidence**

In the final response, list each command run and whether it passed. If any command failed or was skipped, include the exact reason and relevant output.
