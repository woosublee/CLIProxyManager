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
