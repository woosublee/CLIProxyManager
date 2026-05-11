APP_NAME ?= CLIProxyManager
BUNDLE_ID ?= com.woosublee.CLIProxyManager
VERSION ?= 0.1.1
BUILD_NUMBER ?= 2
BUILD_DIR ?= build
CONFIGURATION ?= release
LOCAL_CODESIGN_IDENTITY ?= CLIProxyManager Local Release
RELEASE_CODESIGN_IDENTITY ?= -
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
SWIFT_BUILD_DIR = $(shell swift build -c $(CONFIGURATION) --show-bin-path)
APP_EXECUTABLE = $(SWIFT_BUILD_DIR)/$(APP_NAME)
HELPER_EXECUTABLE = $(SWIFT_BUILD_DIR)/cliproxy-manager
BUNDLED_HELPER := $(HELPERS_DIR)/cliproxy-manager
BUNDLED_ICON := $(RESOURCES_DIR)/$(ICON_FILE)
INFO_PLIST := Info.plist
ENTITLEMENTS := CLIProxyManager.entitlements

.PHONY: all swift-build bundle sign release-sign verify install-helper install run install-and-run dmg verify-dmg clean distclean

all: sign

swift-build:
	swift build -c $(CONFIGURATION) --product $(APP_NAME)
	swift build -c $(CONFIGURATION) --product cliproxy-manager

bundle: swift-build $(INFO_PLIST) $(ENTITLEMENTS) $(ICON_FILE)
	test -x "$(APP_EXECUTABLE)" || { echo "Missing executable: $(APP_EXECUTABLE)"; exit 1; }
	test -x "$(HELPER_EXECUTABLE)" || { echo "Missing executable: $(HELPER_EXECUTABLE)"; exit 1; }
	test -f "$(ICON_FILE)" || { echo "Missing icon: $(ICON_FILE)"; exit 1; }
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)" "$(HELPERS_DIR)"
	ditto --norsrc --noextattr "$(APP_EXECUTABLE)" "$(MACOS_DIR)/$(APP_NAME)"
	ditto --norsrc --noextattr "$(HELPER_EXECUTABLE)" "$(BUNDLED_HELPER)"
	ditto --norsrc --noextattr "$(ICON_FILE)" "$(BUNDLED_ICON)"
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

clean:
	rm -rf "$(BUILD_DIR)"

distclean: clean
	rm -rf .build
