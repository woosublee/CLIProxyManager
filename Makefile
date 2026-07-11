APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
VERSION ?= 0.1.14
BUILD_NUMBER ?= 17
BUILD_DIR ?= build
CONFIGURATION ?= release
LOCAL_CODESIGN_IDENTITY ?= cliproxymanager
RELEASE_CODESIGN_IDENTITY ?= $(CODESIGN_IDENTITY)
CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)
ICON_NAME ?= CLIProxyManager
ICON_FILE ?= $(ICON_NAME).icns

APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME := $(APP_NAME)-$(VERSION).dmg
DMG_PATH := $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGING_TEMPLATE := /tmp/$(APP_NAME).dmg-src.XXXXXX
CONTENTS_DIR := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
HELPERS_DIR := $(CONTENTS_DIR)/Helpers
FRAMEWORKS_DIR := $(CONTENTS_DIR)/Frameworks
SWIFT_BUILD_DIR = $(shell swift build -c $(CONFIGURATION) --show-bin-path)
APP_EXECUTABLE = $(SWIFT_BUILD_DIR)/$(APP_NAME)
CPM_EXECUTABLE = $(SWIFT_BUILD_DIR)/cpm
HELPER_EXECUTABLE = $(SWIFT_BUILD_DIR)/cliproxy-manager
BUNDLED_CPM := $(HELPERS_DIR)/cpm
BUNDLED_HELPER := $(HELPERS_DIR)/cliproxy-manager
BUNDLED_ICON := $(RESOURCES_DIR)/$(ICON_FILE)
BUNDLED_SPARKLE_FRAMEWORK := $(FRAMEWORKS_DIR)/Sparkle.framework
SPARKLE_FRAMEWORK = $(shell find .build/artifacts -path '*/Sparkle.framework' -type d -print -quit)
INFO_PLIST := Info.plist
ENTITLEMENTS := CLIProxyManager.entitlements

.PHONY: all print-app-version print-build-number print-build-tag swift-build bundle sign release-sign verify install-helper install run install-and-run dmg verify-dmg sign-dmg clean distclean

all: sign

print-app-version:
	@printf '%s\n' "$(VERSION)"

print-build-number:
	@printf '%s\n' "$(BUILD_NUMBER)"

print-build-tag:
	@printf 'v%s\n' "$(VERSION)"

swift-build:
	swift build -c $(CONFIGURATION) --product $(APP_NAME)
	swift build -c $(CONFIGURATION) --product cpm
	swift build -c $(CONFIGURATION) --product cliproxy-manager

bundle: swift-build $(INFO_PLIST) $(ENTITLEMENTS) $(ICON_FILE)
	test -x "$(APP_EXECUTABLE)" || { echo "Missing executable: $(APP_EXECUTABLE)"; exit 1; }
	test -x "$(CPM_EXECUTABLE)" || { echo "Missing executable: $(CPM_EXECUTABLE)"; exit 1; }
	test -x "$(HELPER_EXECUTABLE)" || { echo "Missing executable: $(HELPER_EXECUTABLE)"; exit 1; }
	test -f "$(ICON_FILE)" || { echo "Missing icon: $(ICON_FILE)"; exit 1; }
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(HELPERS_DIR)" "$(FRAMEWORKS_DIR)"
	test -d "$(SPARKLE_FRAMEWORK)" || { echo "Missing Sparkle.framework artifact. Run swift package resolve first."; exit 1; }
	ditto --norsrc --noextattr "$(APP_EXECUTABLE)" "$(MACOS_DIR)/$(APP_NAME)"
	if ! otool -l "$(MACOS_DIR)/$(APP_NAME)" | grep -F "@executable_path/../Frameworks" >/dev/null; then \
		install_name_tool -add_rpath "@executable_path/../Frameworks" "$(MACOS_DIR)/$(APP_NAME)"; \
	fi
	ditto --norsrc --noextattr "$(CPM_EXECUTABLE)" "$(BUNDLED_CPM)"
	ditto --norsrc --noextattr "$(HELPER_EXECUTABLE)" "$(BUNDLED_HELPER)"
	ditto --norsrc --noextattr "$(ICON_FILE)" "$(BUNDLED_ICON)"
	ditto --norsrc --noextattr "$(SPARKLE_FRAMEWORK)" "$(BUNDLED_SPARKLE_FRAMEWORK)"
	cp "$(INFO_PLIST)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleIconFile -string "$(ICON_NAME)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(CONTENTS_DIR)/Info.plist"
	@for bundle in $(SWIFT_BUILD_DIR)/*CLIProxyManagerApp*.bundle; do \
		if [ -d "$$bundle" ]; then \
			ditto --norsrc --noextattr "$$bundle" "$(RESOURCES_DIR)"; \
		fi; \
	done
	chmod -R u+w "$(APP_BUNDLE)"
	chmod +x "$(MACOS_DIR)/$(APP_NAME)" "$(BUNDLED_CPM)" "$(BUNDLED_HELPER)" "$(BUNDLED_SPARKLE_FRAMEWORK)/Autoupdate"
	xattr -r -c "$(APP_BUNDLE)"
	xattr -d com.apple.FinderInfo "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Bundled $(APP_BUNDLE)"

sign: bundle
	@set -e; \
	STAGING_DIR=$$(mktemp -d "/tmp/$(APP_NAME).sign.XXXXXX"); \
	cleanup() { rm -rf "$$STAGING_DIR"; }; \
	trap cleanup EXIT; \
	STAGED_APP="$$STAGING_DIR/$(APP_NAME).app"; \
	ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$STAGED_APP"; \
	if [ -d "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices" ]; then \
		find -L "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices" -maxdepth 1 -name '*.xpc' -type d -exec codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" {} \; ; \
	fi; \
	if [ -d "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app" ]; then \
		codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app"; \
	fi; \
	if [ -x "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" ]; then \
		codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate"; \
	fi; \
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Frameworks/Sparkle.framework"; \
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Helpers/cpm" || { \
		status=$$?; \
		echo "cpm helper codesign failed. Override the signing identity with: make CODESIGN_IDENTITY=\"Your Signing Identity\""; \
		exit $$status; \
	}; \
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$STAGED_APP/Contents/Helpers/cliproxy-manager" || { \
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

release-sign:
	$(MAKE) sign CODESIGN_IDENTITY="$(RELEASE_CODESIGN_IDENTITY)"

verify: sign
	@set -e; \
	VERIFY_DIR=$$(mktemp -d "/tmp/$(APP_NAME).verify.XXXXXX"); \
	cleanup() { rm -rf "$$VERIFY_DIR"; }; \
	trap cleanup EXIT; \
	VERIFY_APP="$$VERIFY_DIR/$(APP_NAME).app"; \
	ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$VERIFY_APP"; \
	xattr -cr "$$VERIFY_APP"; \
	codesign --verify --deep --strict --verbose=2 "$$VERIFY_APP"; \
	test -f "$$VERIFY_APP/Contents/Resources/$(ICON_FILE)" || { echo "Missing bundled icon: $$VERIFY_APP/Contents/Resources/$(ICON_FILE)"; exit 1; }; \
	plutil -extract CFBundleIconFile raw "$$VERIFY_APP/Contents/Info.plist" | grep -Fx "$(ICON_NAME)" >/dev/null || { echo "Missing CFBundleIconFile: $(ICON_NAME)"; exit 1; }; \
	test -x "$$VERIFY_APP/Contents/Helpers/cpm" || { echo "Missing bundled helper: $$VERIFY_APP/Contents/Helpers/cpm"; exit 1; }; \
	test -x "$$VERIFY_APP/Contents/Helpers/cliproxy-manager" || { echo "Missing bundled helper: $$VERIFY_APP/Contents/Helpers/cliproxy-manager"; exit 1; }; \
	test -d "$$VERIFY_APP/Contents/Frameworks/Sparkle.framework" || { echo "Missing Sparkle.framework"; exit 1; }; \
	test -x "$$VERIFY_APP/Contents/Frameworks/Sparkle.framework/Autoupdate" || { echo "Missing Sparkle Autoupdate"; exit 1; }; \
	test -d "$$VERIFY_APP/Contents/Frameworks/Sparkle.framework/Updater.app" || { echo "Missing Sparkle Updater.app"; exit 1; }; \
	test ! -e "$$VERIFY_APP/Contents/Resources/cliproxy-manager" || { echo "Helper must not be bundled in Contents/Resources"; exit 1; }; \
	echo "codesign verification passed"

install-helper: sign
	mkdir -p /usr/local/bin
	ditto --norsrc --noextattr "$(BUNDLED_CPM)" "/usr/local/bin/cpm"
	chmod +x "/usr/local/bin/cpm"
	ditto --norsrc --noextattr "$(BUNDLED_HELPER)" "/usr/local/bin/cliproxy-manager"
	chmod +x "/usr/local/bin/cliproxy-manager"
	@echo "Installed helpers to /usr/local/bin/cpm and /usr/local/bin/cliproxy-manager"

install: sign
	@set -e; \
	INSTALL_PATH="/Applications/$(APP_NAME).app"; \
	CPM_PATH="/usr/local/bin/cpm"; \
	LEGACY_HELPER_PATH="/usr/local/bin/cliproxy-manager"; \
	HELPER_DIR=$$(dirname "$$CPM_PATH"); \
	APP_STAGING="/Applications/.$(APP_NAME).app.staging"; \
	APP_PREVIOUS="/Applications/.$(APP_NAME).app.previous"; \
	CPM_STAGING="$$HELPER_DIR/.cpm.staging"; \
	CPM_PREVIOUS="$$HELPER_DIR/.cpm.previous"; \
	LEGACY_STAGING="$$HELPER_DIR/.cliproxy-manager.staging"; \
	LEGACY_PREVIOUS="$$HELPER_DIR/.cliproxy-manager.previous"; \
	cleanup_staging() { rm -rf "$$APP_STAGING" "$$CPM_STAGING" "$$LEGACY_STAGING"; }; \
	rollback() { \
		status=$$?; \
		echo "Install failed; rolling back app and helpers." >&2; \
		rm -rf "$$INSTALL_PATH"; \
		if [ -d "$$APP_PREVIOUS" ]; then mv "$$APP_PREVIOUS" "$$INSTALL_PATH" || true; fi; \
		rm -f "$$CPM_PATH"; \
		if [ -e "$$CPM_PREVIOUS" ]; then mv "$$CPM_PREVIOUS" "$$CPM_PATH" || true; fi; \
		rm -f "$$LEGACY_HELPER_PATH"; \
		if [ -e "$$LEGACY_PREVIOUS" ]; then mv "$$LEGACY_PREVIOUS" "$$LEGACY_HELPER_PATH" || true; fi; \
		cleanup_staging; \
		exit $$status; \
	}; \
	rm -rf "$$APP_STAGING" "$$APP_PREVIOUS" "$$CPM_STAGING" "$$CPM_PREVIOUS" "$$LEGACY_STAGING" "$$LEGACY_PREVIOUS"; \
	if ! mkdir -p "$$HELPER_DIR" || \
	   ! ditto --norsrc --noextattr "$(APP_BUNDLE)" "$$APP_STAGING" || \
	   ! ditto --norsrc --noextattr "$(BUNDLED_CPM)" "$$CPM_STAGING" || \
	   ! chmod +x "$$CPM_STAGING" || \
	   ! ditto --norsrc --noextattr "$(BUNDLED_HELPER)" "$$LEGACY_STAGING" || \
	   ! chmod +x "$$LEGACY_STAGING"; then \
		echo "Install failed during staging; existing app and helpers were left unchanged." >&2; \
		cleanup_staging; \
		exit 1; \
	fi; \
	trap rollback ERR; \
	if [ -d "$$INSTALL_PATH" ]; then mv "$$INSTALL_PATH" "$$APP_PREVIOUS"; fi; \
	if [ -e "$$CPM_PATH" ]; then mv "$$CPM_PATH" "$$CPM_PREVIOUS"; fi; \
	if [ -e "$$LEGACY_HELPER_PATH" ]; then mv "$$LEGACY_HELPER_PATH" "$$LEGACY_PREVIOUS"; fi; \
	mv "$$APP_STAGING" "$$INSTALL_PATH"; \
	mv "$$CPM_STAGING" "$$CPM_PATH"; \
	mv "$$LEGACY_STAGING" "$$LEGACY_HELPER_PATH"; \
	trap - ERR; \
	rm -rf "$$APP_PREVIOUS" "$$CPM_PREVIOUS" "$$LEGACY_PREVIOUS"; \
	echo "Installed $$INSTALL_PATH"; \
	echo "Installed helpers to $$CPM_PATH and $$LEGACY_HELPER_PATH"

run: sign
	open "$(APP_BUNDLE)"

install-and-run: install
	-pkill -x "$(APP_NAME)"
	open "/Applications/$(APP_NAME).app"

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

verify-dmg: dmg
	@set -e; \
	test -f "$(DMG_PATH)" || { echo "Missing DMG: $(DMG_PATH)"; exit 1; }; \
	scripts/verify-dmg.sh "$(DMG_PATH)"; \
	MOUNT_DIR=$$(mktemp -d "/tmp/$(APP_NAME).dmg.XXXXXX"); \
	cleanup() { hdiutil detach "$$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach -force "$$MOUNT_DIR" >/dev/null 2>&1 || true; rm -rf "$$MOUNT_DIR"; }; \
	trap cleanup EXIT; \
	hdiutil attach "$(DMG_PATH)" -mountpoint "$$MOUNT_DIR" -nobrowse -quiet; \
	test -d "$$MOUNT_DIR/$(APP_NAME).app" || { echo "Missing app in DMG"; exit 1; }; \
	test -L "$$MOUNT_DIR/Applications" || { echo "Missing Applications symlink in DMG"; exit 1; }; \
	test "$$(readlink "$$MOUNT_DIR/Applications")" = "/Applications" || { echo "Applications symlink points to wrong target"; exit 1; }; \
	codesign --verify --deep --strict --verbose=2 "$$MOUNT_DIR/$(APP_NAME).app"; \
	echo "DMG verification passed"

sign-dmg:
	@set -e; \
		test -f "$(DMG_PATH)" || { echo "Missing DMG: $(DMG_PATH)"; exit 1; }; \
		codesign --force --sign "$(CODESIGN_IDENTITY)" "$(DMG_PATH)"; \
		echo "Signed $(DMG_PATH)"

clean:
	rm -rf "$(BUILD_DIR)"

distclean: clean
	rm -rf .build
