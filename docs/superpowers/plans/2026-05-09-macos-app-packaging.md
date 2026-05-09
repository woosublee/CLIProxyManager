# macOS App Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a SwiftPM-based macOS `.app` packaging flow that signs CLIProxyManager with a local Apple Development identity and installs the app plus CLI helper locally.

**Architecture:** Keep SwiftPM as the only compiler/build graph. Add repository-level packaging metadata (`Info.plist`, `CLIProxyManager.entitlements`) and a `Makefile` that wraps `swift build -c release`, creates `build/CLIProxyManager.app`, copies SwiftPM resource bundles, signs the app, installs it to `/Applications`, and installs `cliproxy-manager` to `/usr/local/bin`.

**Tech Stack:** SwiftPM, Swift 5.10, macOS app bundles, Make, `codesign`, `plutil`, `ditto`, `xattr`, `open`, zsh-compatible shell commands.

---

## File Structure

- Create `Info.plist`: app bundle metadata template copied into `CLIProxyManager.app/Contents/Info.plist`.
- Create `CLIProxyManager.entitlements`: minimal empty entitlements plist used by `codesign --options runtime`.
- Create `Makefile`: local build, bundle, sign, install, run, clean, and verification targets.
- Keep `Package.swift` unchanged: SwiftPM remains the source of truth for targets, products, and resources.
- Keep `docs/superpowers/specs/2026-05-09-macos-app-packaging-design.md` unchanged unless the implementation reveals a design mismatch.

---

### Task 1: Add app bundle metadata

**Files:**
- Create: `Info.plist`

- [ ] **Step 1: Create `Info.plist`**

Write this exact file at repository root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CLIProxyManager</string>
    <key>CFBundleDisplayName</key>
    <string>CLIProxyManager</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIdentifier</key>
    <string>com.woosublee.CLIProxyManager</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>CLIProxyManager</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
```

- [ ] **Step 2: Verify the plist is syntactically valid**

Run:

```bash
plutil -lint Info.plist
```

Expected:

```text
Info.plist: OK
```

- [ ] **Step 3: Commit if explicitly requested by the user**

If the user has asked for commits, run:

```bash
git add Info.plist
git commit -m "Add macOS app bundle metadata"
```

Expected: a new commit is created. If the user has not asked for commits, skip this step.

---

### Task 2: Add local signing entitlements

**Files:**
- Create: `CLIProxyManager.entitlements`

- [ ] **Step 1: Create `CLIProxyManager.entitlements`**

Write this exact file at repository root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

- [ ] **Step 2: Verify the entitlements plist is syntactically valid**

Run:

```bash
plutil -lint CLIProxyManager.entitlements
```

Expected:

```text
CLIProxyManager.entitlements: OK
```

- [ ] **Step 3: Commit if explicitly requested by the user**

If the user has asked for commits, run:

```bash
git add CLIProxyManager.entitlements
git commit -m "Add local signing entitlements"
```

Expected: a new commit is created. If the user has not asked for commits, skip this step.

---

### Task 3: Add SwiftPM-based app packaging Makefile

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Create `Makefile`**

Write this exact file at repository root:

```make
APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
BUILD_DIR ?= build
CONFIGURATION ?= release
CODESIGN_IDENTITY ?= Apple Development

APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
HELPERS_DIR := $(CONTENTS_DIR)/Helpers
SWIFT_BUILD_DIR = $(shell swift build -c $(CONFIGURATION) --show-bin-path)
APP_EXECUTABLE = $(SWIFT_BUILD_DIR)/$(APP_NAME)
HELPER_EXECUTABLE = $(SWIFT_BUILD_DIR)/cliproxy-manager
BUNDLED_HELPER := $(HELPERS_DIR)/cliproxy-manager
INFO_PLIST := Info.plist
ENTITLEMENTS := CLIProxyManager.entitlements

.PHONY: all swift-build bundle sign verify install-helper install run install-and-run clean distclean

all: sign

swift-build:
	swift build -c $(CONFIGURATION) --product $(APP_NAME)
	swift build -c $(CONFIGURATION) --product cliproxy-manager

bundle: swift-build $(INFO_PLIST) $(ENTITLEMENTS)
	test -x "$(APP_EXECUTABLE)" || { echo "Missing executable: $(APP_EXECUTABLE)"; exit 1; }
	test -x "$(HELPER_EXECUTABLE)" || { echo "Missing executable: $(HELPER_EXECUTABLE)"; exit 1; }
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(HELPERS_DIR)"
	ditto --norsrc --noextattr "$(APP_EXECUTABLE)" "$(MACOS_DIR)/$(APP_NAME)"
	ditto --norsrc --noextattr "$(HELPER_EXECUTABLE)" "$(BUNDLED_HELPER)"
	cp "$(INFO_PLIST)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(CONTENTS_DIR)/Info.plist"
	@for bundle in $(SWIFT_BUILD_DIR)/*CLIProxyManagerApp*.bundle; do \
		if [ -d "$$bundle" ]; then \
			ditto --norsrc --noextattr "$$bundle" "$(RESOURCES_DIR)"; \
		fi; \
	done
	chmod -R u+w "$(APP_BUNDLE)"
	chmod +x "$(MACOS_DIR)/$(APP_NAME)" "$(BUNDLED_HELPER)"
	xattr -r -c "$(APP_BUNDLE)"
	@echo "Bundled $(APP_BUNDLE)"

sign: bundle
	@set -e; \
	STAGING_DIR=$$(mktemp -d "/tmp/$(APP_NAME).sign.XXXXXX"); \
	cleanup() { rm -rf "$$STAGING_DIR"; }; \
	trap cleanup EXIT; \
	STAGED_APP="$$STAGING_DIR/$(APP_NAME).app"; \
	ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$STAGED_APP"; \
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Helpers/cliproxy-manager" || { \
		status=$$?; \
		echo "helper codesign failed. Override the signing identity with: make CODESIGN_IDENTITY=\"Your Signing Identity\""; \
		exit $$status; \
	}; \
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements "$(ENTITLEMENTS)" "$$STAGED_APP" || { \
		status=$$?; \
		echo "codesign failed. Override the signing identity with: make CODESIGN_IDENTITY=\"Your Signing Identity\""; \
		exit $$status; \
	}; \
	rm -rf "$(APP_BUNDLE)"; \
	ditto --norsrc --noextattr "$$STAGED_APP" "$(APP_BUNDLE)"; \
	chmod -R u+w "$(APP_BUNDLE)"; \
	xattr -r -c "$(APP_BUNDLE)"; \
	xattr -c "$(APP_BUNDLE)"; \
	xattr -d com.apple.FinderInfo "$(APP_BUNDLE)" 2>/dev/null || true

verify: sign
	@set -e; \
	VERIFY_DIR=$$(mktemp -d "/tmp/$(APP_NAME).verify.XXXXXX"); \
	cleanup() { rm -rf "$$VERIFY_DIR"; }; \
	trap cleanup EXIT; \
	VERIFY_APP="$$VERIFY_DIR/$(APP_NAME).app"; \
	ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$VERIFY_APP"; \
	xattr -cr "$$VERIFY_APP"; \
	codesign --verify --deep --strict --verbose=2 "$$VERIFY_APP"; \
	test -x "$$VERIFY_APP/Contents/Helpers/cliproxy-manager" || { echo "Missing bundled helper: $$VERIFY_APP/Contents/Helpers/cliproxy-manager"; exit 1; }; \
	test ! -e "$$VERIFY_APP/Contents/Resources/cliproxy-manager" || { echo "Helper must not be bundled in Contents/Resources"; exit 1; }; \
	echo "codesign verification passed"

install-helper: sign
	mkdir -p /usr/local/bin
	ditto --norsrc --noextattr "$(BUNDLED_HELPER)" "/usr/local/bin/cliproxy-manager"
	chmod +x "/usr/local/bin/cliproxy-manager"
	@echo "Installed helper to /usr/local/bin/cliproxy-manager"

install: sign
	@set -e; \
	INSTALL_PATH="/Applications/$(APP_NAME).app"; \
	HELPER_PATH="/usr/local/bin/cliproxy-manager"; \
	HELPER_DIR=$$(dirname "$$HELPER_PATH"); \
	APP_STAGING="/Applications/.$(APP_NAME).app.staging"; \
	APP_PREVIOUS="/Applications/.$(APP_NAME).app.previous"; \
	HELPER_STAGING="$$HELPER_DIR/.cliproxy-manager.staging"; \
	HELPER_PREVIOUS="$$HELPER_DIR/.cliproxy-manager.previous"; \
	cleanup_staging() { rm -rf "$$APP_STAGING" "$$HELPER_STAGING"; }; \
	rollback() { \
		status=$$?; \
		echo "Install failed; rolling back app and helper." >&2; \
		rm -rf "$$INSTALL_PATH"; \
		if [ -d "$$APP_PREVIOUS" ]; then mv "$$APP_PREVIOUS" "$$INSTALL_PATH" || true; fi; \
		rm -f "$$HELPER_PATH"; \
		if [ -e "$$HELPER_PREVIOUS" ]; then mv "$$HELPER_PREVIOUS" "$$HELPER_PATH" || true; fi; \
		cleanup_staging; \
		exit $$status; \
	}; \
	rm -rf "$$APP_STAGING" "$$APP_PREVIOUS" "$$HELPER_STAGING" "$$HELPER_PREVIOUS"; \
	if ! mkdir -p "$$HELPER_DIR" || \
	   ! ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$APP_STAGING" || \
	   ! ditto --norsrc --noextattr "$(BUNDLED_HELPER)" "$$HELPER_STAGING" || \
	   ! chmod +x "$$HELPER_STAGING"; then \
		echo "Install failed during staging; existing app and helper were left unchanged." >&2; \
		cleanup_staging; \
		exit 1; \
	fi; \
	trap rollback ERR; \
	if [ -d "$$INSTALL_PATH" ]; then mv "$$INSTALL_PATH" "$$APP_PREVIOUS"; fi; \
	if [ -e "$$HELPER_PATH" ]; then mv "$$HELPER_PATH" "$$HELPER_PREVIOUS"; fi; \
	mv "$$APP_STAGING" "$$INSTALL_PATH"; \
	mv "$$HELPER_STAGING" "$$HELPER_PATH"; \
	trap - ERR; \
	rm -rf "$$APP_PREVIOUS" "$$HELPER_PREVIOUS"; \
	echo "Installed $$INSTALL_PATH"; \
	echo "Installed helper to $$HELPER_PATH"

run: sign
	open "$(APP_BUNDLE)"

install-and-run: install
	-pkill -x "$(APP_NAME)"
	open "/Applications/$(APP_NAME).app"

clean:
	rm -rf "$(BUILD_DIR)"

distclean: clean
	rm -rf .build

```

- [ ] **Step 2: Verify Make can parse the file**

Run:

```bash
make -n all
```

Expected: Make prints the `swift build`, bundle, and `codesign` commands without syntax errors.

- [ ] **Step 3: Build the signed app bundle**

Run:

```bash
make all
```

Expected:

```text
Bundled build/CLIProxyManager.app
Signing build/CLIProxyManager.app with identity: Apple Development
Signed build/CLIProxyManager.app
```

If signing fails with an identity error, run:

```bash
security find-identity -v -p codesigning
```

Then rerun with the exact Apple Development identity:

```bash
make all CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

- [ ] **Step 4: Commit if explicitly requested by the user**

If the user has asked for commits, run:

```bash
git add Makefile
git commit -m "Add SwiftPM macOS app packaging"
```

Expected: a new commit is created. If the user has not asked for commits, skip this step.

---

### Task 4: Verify app bundle contents and signing

**Files:**
- No file changes.

- [ ] **Step 1: Check the app bundle layout**

Run:

```bash
find build/CLIProxyManager.app -maxdepth 4 -type f | LC_ALL=C sort
```

Expected output includes at least:

```text
build/CLIProxyManager.app/Contents/Info.plist
build/CLIProxyManager.app/Contents/MacOS/CLIProxyManager
build/CLIProxyManager.app/Contents/Helpers/cliproxy-manager
```

Expected output also includes the SwiftPM resource bundle contents when SwiftPM emits them:

```text
build/CLIProxyManager.app/Contents/Resources/cliproxyapi/cliproxyapi
build/CLIProxyManager.app/Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt
```

The Makefile copies the helper into `Contents/Helpers/cliproxy-manager`. It copies the contents of bundles matching `$(SWIFT_BUILD_DIR)/*CLIProxyManagerApp*.bundle` into `Contents/Resources`, so the app includes `cliproxyapi/` and `Licenses/` directly without embedding `CLIProxyManager_CLIProxyManagerApp.bundle` in the app.

- [ ] **Step 2: Verify bundle metadata**

Run:

```bash
plutil -p build/CLIProxyManager.app/Contents/Info.plist
```

Expected fields:

```text
"CFBundleIdentifier" => "com.woosublee.CLIProxyManager"
"CFBundleExecutable" => "CLIProxyManager"
"CFBundlePackageType" => "APPL"
"LSMinimumSystemVersion" => "13.0"
```

- [ ] **Step 3: Verify code signature**

Run:

```bash
make verify
```

Expected: command exits with status `0` and prints `codesign verification passed`. Verification uses a no-resource-fork temporary copy under `/tmp` (`ditto --norsrc --noextattr`, then `xattr -cr`) before running `codesign --verify --deep --strict --verbose=2`, because the worktree file-provider can reattach `com.apple.FinderInfo` to package directories and make direct verification of `build/CLIProxyManager.app` fail spuriously. It also verifies the helper exists at `Contents/Helpers/cliproxy-manager` and does not exist at `Contents/Resources/cliproxy-manager`.

- [ ] **Step 4: Assess local launch policy**

Run:

```bash
spctl --assess --type execute --verbose build/CLIProxyManager.app
```

Expected: this may pass or report local-development trust limitations depending on the certificate. Do not treat a failing `spctl` assessment as implementation failure if `codesign --verify` passes and the app launches locally.

---

### Task 5: Install and launch locally

**Files:**
- No repository file changes.
- Installs local system files:
  - `/Applications/CLIProxyManager.app`
  - `/usr/local/bin/cliproxy-manager`

- [ ] **Step 1: Install the app and helper**

Run:

```bash
make install
```

Expected:

```text
Installed /Applications/CLIProxyManager.app
Installed helper to /usr/local/bin/cliproxy-manager
```

If staging either artifact fails, existing installed files are left unchanged. If swapping the staged app or helper fails after backups are made, the install rolls both paths back to their previous state and prints a clear failure message.

- [ ] **Step 2: Verify installed files exist**

Run:

```bash
ls -ld /Applications/CLIProxyManager.app
ls -l /usr/local/bin/cliproxy-manager
```

Expected:

```text
/Applications/CLIProxyManager.app
/usr/local/bin/cliproxy-manager
```

The helper should be executable and match the signed helper from `/Applications/CLIProxyManager.app/Contents/Helpers/cliproxy-manager`.

- [ ] **Step 3: Launch the installed app**

Run:

```bash
open /Applications/CLIProxyManager.app
```

Expected: CLIProxyManager launches as a macOS app.

- [ ] **Step 4: Run the helper usage path**

Run:

```bash
/usr/local/bin/cliproxy-manager
```

Expected:

```text
Usage: cliproxy-manager secret <get|set|delete> claude-api-key
```

The command exits non-zero because no subcommand was supplied; the usage output confirms the installed binary runs.

---

### Task 6: Run regression verification

**Files:**
- No file changes.

- [ ] **Step 1: Run Swift tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Run packaging verification target**

Run:

```bash
make verify
```

Expected:

```text
codesign verification passed
```

- [ ] **Step 3: Review working tree**

Run:

```bash
git status --short
```

Expected changed files:

```text
 M .gitignore
?? CLIProxyManager.entitlements
?? Info.plist
?? Makefile
?? docs/superpowers/plans/2026-05-09-macos-app-packaging.md
?? docs/superpowers/specs/2026-05-09-macos-app-packaging-design.md
```

If the files are tracked after staging or committing, their status may differ. Generated local packaging output under `build/` is ignored by git, so `git status --short` should not list `?? build/`.

- [ ] **Step 4: Commit if explicitly requested by the user**

If the user has asked for commits, run:

```bash
git add CLIProxyManager.entitlements Info.plist Makefile docs/superpowers/plans/2026-05-09-macos-app-packaging.md docs/superpowers/specs/2026-05-09-macos-app-packaging-design.md
git commit -m "Add local macOS app packaging"
```

Expected: a new commit is created. If the user has not asked for commits, skip this step.

---

## Self-Review

### Spec coverage

- SwiftPM compile step is covered by Task 3 `swift-build`.
- `.app` bundle creation is covered by Task 3 `bundle` and Task 4 layout verification.
- `Info.plist` is covered by Task 1 and Task 4 metadata verification.
- Minimal entitlements are covered by Task 2.
- Apple Development signing is covered by Task 3 `sign` and Task 4 signature verification.
- `/Applications` installation is covered by Task 5.
- `/usr/local/bin/cliproxy-manager` installation from the signed bundled helper is covered by Task 3 `install-helper`/`install` and Task 5 helper verification.
- Notarization, DMG packaging, Developer ID signing, Xcode generation, and sandboxing are intentionally excluded.

### Placeholder scan

The plan contains no `TBD`, no incomplete implementation steps, and no undefined file paths. Commit steps are conditional because this environment must not create commits unless the user explicitly requests one.

### Type and command consistency

The app product is consistently `CLIProxyManager`, the helper product is consistently `cliproxy-manager`, the bundled helper path is consistently `Contents/Helpers/cliproxy-manager`, the bundle identifier is consistently `com.woosublee.CLIProxyManager`, and the install paths are consistently `/Applications/CLIProxyManager.app` and `/usr/local/bin/cliproxy-manager`.
