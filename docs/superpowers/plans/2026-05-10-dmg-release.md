# DMG Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local self-signed signing defaults, public ad-hoc DMG packaging, and GitHub Release documentation for CLIProxyManager.

**Architecture:** Keep the existing Makefile-based app bundling flow. Split signing identity defaults into local and release identities, reuse one signing implementation through `CODESIGN_IDENTITY`, add a plain `hdiutil` DMG target, and document release commands plus Gatekeeper limitations.

**Tech Stack:** SwiftPM, Makefile, macOS `codesign`, `hdiutil`, `ditto`, `plutil`, GitHub CLI.

---

## File Structure

- Modify `Makefile`
  - Add `LOCAL_CODESIGN_IDENTITY ?= CLIProxyManager Local Release`.
  - Add `RELEASE_CODESIGN_IDENTITY ?= -`.
  - Keep `CODESIGN_IDENTITY` as the effective identity used by `sign`.
  - Add `DMG_NAME`, `DMG_PATH`, and `DMG_STAGING_TEMPLATE` variables.
  - Add `release-sign`, `dmg`, and `verify-dmg` targets.
- Create `docs/release.md`
  - Document local signing, ad-hoc DMG release builds, GitHub Release upload, Gatekeeper warning, and future Developer ID notarization path.
- Modify `README.md`
  - Add a short release/download section linking to `docs/release.md`.
- Keep `docs/superpowers/specs/2026-05-10-dmg-release-design.md`
  - Commit together with implementation if the user requests a commit.

---

### Task 1: Split Local and Release Signing Defaults

**Files:**
- Modify: `Makefile:1-26`

- [ ] **Step 1: Write the failing check**

Run:

```bash
make -pn | grep -E '^(LOCAL_CODESIGN_IDENTITY|RELEASE_CODESIGN_IDENTITY|CODESIGN_IDENTITY) ?[:?]='
```

Expected before implementation: output only includes `CODESIGN_IDENTITY ?= Apple Development`; `LOCAL_CODESIGN_IDENTITY` and `RELEASE_CODESIGN_IDENTITY` are missing.

- [ ] **Step 2: Update signing variables**

Change the top variable block in `Makefile` from:

```make
APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
BUILD_DIR ?= build
CONFIGURATION ?= release
CODESIGN_IDENTITY ?= Apple Development
ICON_NAME ?= CLIProxyManager
ICON_FILE ?= $(ICON_NAME).icns
```

to:

```make
APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
BUILD_DIR ?= build
CONFIGURATION ?= release
LOCAL_CODESIGN_IDENTITY ?= CLIProxyManager Local Release
RELEASE_CODESIGN_IDENTITY ?= -
CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)
ICON_NAME ?= CLIProxyManager
ICON_FILE ?= $(ICON_NAME).icns
```

- [ ] **Step 3: Verify variables exist**

Run:

```bash
make -pn | grep -E '^(LOCAL_CODESIGN_IDENTITY|RELEASE_CODESIGN_IDENTITY|CODESIGN_IDENTITY) ?[:?]='
```

Expected after implementation: output includes `LOCAL_CODESIGN_IDENTITY ?= CLIProxyManager Local Release`, `RELEASE_CODESIGN_IDENTITY ?= -`, and `CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)` or expanded equivalent.

---

### Task 2: Add Release Signing Target

**Files:**
- Modify: `Makefile:24-84`

- [ ] **Step 1: Write the failing check**

Run:

```bash
make -n release-sign | grep 'CODESIGN_IDENTITY="$(RELEASE_CODESIGN_IDENTITY)"'
```

Expected before implementation: `make: *** No rule to make target 'release-sign'. Stop.`

- [ ] **Step 2: Update `.PHONY`**

Change:

```make
.PHONY: all swift-build bundle sign verify install-helper install run install-and-run clean distclean
```

to:

```make
.PHONY: all swift-build bundle sign release-sign verify install-helper install run install-and-run dmg verify-dmg clean distclean
```

- [ ] **Step 3: Add `release-sign` target**

Add this target immediately after `sign`:

```make
release-sign:
	$(MAKE) sign CODESIGN_IDENTITY="$(RELEASE_CODESIGN_IDENTITY)"
```

- [ ] **Step 4: Verify release-sign delegates to ad-hoc identity**

Run:

```bash
make -n release-sign | grep 'CODESIGN_IDENTITY="-"'
```

Expected after implementation: dry-run output contains a nested `make sign CODESIGN_IDENTITY="-"` command.

---

### Task 3: Add DMG Variables and Packaging Target

**Files:**
- Modify: `Makefile:11-24`
- Modify: `Makefile:143-155`

- [ ] **Step 1: Write the failing check**

Run:

```bash
make -n dmg
```

Expected before implementation: `make: *** No rule to make target 'dmg'. Stop.`

- [ ] **Step 2: Add DMG variables**

After:

```make
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
```

add:

```make
DMG_NAME := $(APP_NAME)-$(VERSION).dmg
DMG_PATH := $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGING_TEMPLATE := /tmp/$(APP_NAME).dmg-src.XXXXXX
```

- [ ] **Step 3: Add `dmg` target**

Add this target before `clean`:

```make
dmg: release-sign
	@set -e; \
	rm -f "$(DMG_PATH)"; \
	DMG_STAGING_DIR=$$(mktemp -d "$(DMG_STAGING_TEMPLATE)"); \
	cleanup() { rm -rf "$$DMG_STAGING_DIR"; }; \
	trap cleanup EXIT; \
	ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$DMG_STAGING_DIR/$(APP_NAME).app"; \
	xattr -r -c "$$DMG_STAGING_DIR/$(APP_NAME).app"; \
	xattr -d com.apple.FinderInfo "$$DMG_STAGING_DIR/$(APP_NAME).app" 2>/dev/null || true; \
	ln -s /Applications "$$DMG_STAGING_DIR/Applications"; \
	hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$$DMG_STAGING_DIR" \
		-ov \
		-format UDZO \
		"$(DMG_PATH)"; \
	echo "Created $(DMG_PATH)"
```

- [ ] **Step 4: Verify dry-run includes hdiutil**

Run:

```bash
make -n dmg | grep 'hdiutil create'
```

Expected after implementation: output contains `hdiutil create`.

---

### Task 4: Add DMG Verification Target

**Files:**
- Modify: `Makefile:143-155`

- [ ] **Step 1: Write the failing check**

Run:

```bash
make -n verify-dmg
```

Expected before implementation: `make: *** No rule to make target 'verify-dmg'. Stop.`

- [ ] **Step 2: Add `verify-dmg` target**

Add this target immediately after `dmg`:

```make
verify-dmg: dmg
	@set -e; \
	test -f "$(DMG_PATH)" || { echo "Missing DMG: $(DMG_PATH)"; exit 1; }; \
	hdiutil verify "$(DMG_PATH)"; \
	MOUNT_DIR=$$(mktemp -d "/tmp/$(APP_NAME).dmg.XXXXXX"); \
	cleanup() { hdiutil detach "$$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach -force "$$MOUNT_DIR" >/dev/null 2>&1 || true; rm -rf "$$MOUNT_DIR"; }; \
	trap cleanup EXIT; \
	hdiutil attach "$(DMG_PATH)" -mountpoint "$$MOUNT_DIR" -nobrowse -quiet; \
	test -d "$$MOUNT_DIR/$(APP_NAME).app" || { echo "Missing app in DMG"; exit 1; }; \
	test -L "$$MOUNT_DIR/Applications" || { echo "Missing Applications symlink in DMG"; exit 1; }; \
	test "$$(readlink "$$MOUNT_DIR/Applications")" = "/Applications" || { echo "Applications symlink points to wrong target"; exit 1; }; \
	codesign --verify --deep --strict --verbose=2 "$$MOUNT_DIR/$(APP_NAME).app"; \
	echo "DMG verification passed"
```

- [ ] **Step 3: Verify dry-run includes attach and codesign**

Run:

```bash
make -n verify-dmg | grep -E 'hdiutil attach|codesign --verify'
```

Expected after implementation: output contains both `hdiutil attach` and `codesign --verify`.

---

### Task 5: Document Release Workflow

**Files:**
- Create: `docs/release.md`
- Modify: `README.md:13-20`

- [ ] **Step 1: Create release documentation**

Create `docs/release.md` with this content:

```markdown
# Release

CLIProxyManager can be distributed as a macOS DMG through GitHub Releases.

## Signing modes

Local install and run targets default to a local signing identity:

```sh
make install LOCAL_CODESIGN_IDENTITY="CLIProxyManager Local Release"
make run LOCAL_CODESIGN_IDENTITY="CLIProxyManager Local Release"
```

Public DMG builds default to ad-hoc signing:

```sh
make dmg VERSION=0.1.0 BUILD_NUMBER=1
```

The public default avoids embedding self-signed certificate metadata in GitHub Release artifacts.

## Build a DMG

```sh
make clean
make verify-dmg VERSION=0.1.0 BUILD_NUMBER=1
```

The DMG is created at:

```text
build/CLIProxyManager-0.1.0.dmg
```

The image contains `CLIProxyManager.app` and an `Applications` symlink.

## Publish to GitHub Releases

Create or update the tag first, then upload the DMG as a release asset:

```sh
gh release create v0.1.0 build/CLIProxyManager-0.1.0.dmg \
  --title "CLIProxyManager 0.1.0" \
  --notes "Ad-hoc signed macOS DMG. Not notarized."
```

If the release already exists:

```sh
gh release upload v0.1.0 build/CLIProxyManager-0.1.0.dmg --clobber
```

## Gatekeeper warning

The public DMG is ad-hoc signed and is not notarized. macOS may block the first launch because the app is not signed with an Apple Developer ID certificate.

If you trust the GitHub Release artifact, open the app with right-click > Open.

## Future Developer ID path

With an Apple Developer Program account, release builds can switch to a Developer ID identity:

```sh
make verify-dmg RELEASE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
```

Notarization and stapling are not part of the current release flow. Add them after Developer ID signing is available.
```

- [ ] **Step 2: Add README release link**

After the requirements list in `README.md`, insert:

```markdown
## Releases

DMG release builds and publishing steps are documented in [docs/release.md](docs/release.md). Public DMGs are ad-hoc signed and not notarized unless a Developer ID release identity is provided.
```

- [ ] **Step 3: Verify docs mention Gatekeeper and GitHub Release**

Run:

```bash
grep -R "Gatekeeper\|GitHub Releases\|ad-hoc" README.md docs/release.md
```

Expected: output includes matches from both files.

---

### Task 6: Run Release Verification Locally

**Files:**
- No source edits expected.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test --quiet
```

Expected: all tests pass with `0 failures`.

- [ ] **Step 2: Build and verify DMG**

Run:

```bash
make clean && make verify-dmg VERSION=0.1.0 BUILD_NUMBER=1
```

Expected:

```text
Created build/CLIProxyManager-0.1.0.dmg
DMG verification passed
```

- [ ] **Step 3: Inspect public signing mode**

Run:

```bash
codesign -dv --verbose=4 build/dmg/CLIProxyManager.app 2>&1 || true
```

Expected: this path should not exist because staging is cleaned after DMG creation. Instead attach the DMG and inspect the mounted app:

```bash
MOUNT_DIR=$(mktemp -d /tmp/CLIProxyManager.inspect.XXXXXX); hdiutil attach build/CLIProxyManager-0.1.0.dmg -mountpoint "$MOUNT_DIR" -nobrowse -quiet; codesign -dv --verbose=4 "$MOUNT_DIR/CLIProxyManager.app" 2>&1 | grep -E 'Signature|Authority|TeamIdentifier'; hdiutil detach "$MOUNT_DIR" -quiet; rmdir "$MOUNT_DIR"
```

Expected: output indicates ad-hoc signing, with no personal certificate authority.

---

### Task 7: Prepare GitHub Release Command

**Files:**
- No source edits expected.

- [ ] **Step 1: Confirm artifact exists**

Run:

```bash
test -f build/CLIProxyManager-0.1.0.dmg && ls -lh build/CLIProxyManager-0.1.0.dmg
```

Expected: output shows the DMG file and size.

- [ ] **Step 2: Ask before remote release action**

Before running any `gh release create` or `gh release upload` command, ask the user to confirm the tag and release notes because this changes public remote state.

Use this exact proposed command unless the user chooses different versioning:

```bash
gh release create v0.1.0 build/CLIProxyManager-0.1.0.dmg \
  --title "CLIProxyManager 0.1.0" \
  --notes "Ad-hoc signed macOS DMG. Not notarized."
```

- [ ] **Step 3: Verify release after upload**

After the user confirms and the release command runs, run:

```bash
gh release view v0.1.0 --json tagName,name,assets
```

Expected: JSON includes `CLIProxyManager-0.1.0.dmg` in `assets`.

---

## Self-Review

- Spec coverage: signing split, DMG layout, GitHub Release asset, Gatekeeper documentation, and verification are covered by Tasks 1-7.
- Placeholder scan: no `TBD`, `TODO`, or unspecified implementation steps remain.
- Type consistency: Makefile variables are consistently named `LOCAL_CODESIGN_IDENTITY`, `RELEASE_CODESIGN_IDENTITY`, `CODESIGN_IDENTITY`, `DMG_NAME`, `DMG_PATH`, and `DMG_STAGING_TEMPLATE`.
