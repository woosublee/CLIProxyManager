#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/verify-app-structure.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "verify-app-structure.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/verify-app-structure-tests.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/codesign" <<'SH'
#!/usr/bin/env bash
exit 99
SH
chmod +x "$fake_bin/codesign"

run_checker() {
  PATH="$fake_bin:$PATH" "$SOURCE_SCRIPT" "$@"
}

write_executable() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 "$path"
}

create_app() {
  local app="$1"
  local version="$2"
  local build="$3"
  local channel="$4"
  local contents="$app/Contents"
  local resources="$contents/Resources"
  local binary
  local manifest
  local binary_sha
  local binary_size

  binary="$resources/cliproxyapi/cliproxyapi"
  manifest="$resources/cliproxyapi/cliproxyapi.manifest.json"

  mkdir -p "$contents/MacOS" "$contents/Helpers" "$resources" \
    "$contents/Frameworks/Sparkle.framework/Updater.app" \
    "$resources/cliproxyapi" "$resources/Licenses" "$resources/ProviderImages"

  cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.woosublee.CLIProxyManager</string>
  <key>CFBundleName</key><string>CLIProxyManager</string>
  <key>CFBundleDisplayName</key><string>CLIProxyManager</string>
  <key>CFBundleExecutable</key><string>CLIProxyManager</string>
  <key>CFBundleIconFile</key><string>CLIProxyManager</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
</dict>
</plist>
EOF
  if [[ "$channel" == 'development' ]]; then
    plutil -insert CLIProxyManagerReleaseChannel -string development "$contents/Info.plist"
  fi

  write_executable "$contents/MacOS/CLIProxyManager"
  write_executable "$contents/Helpers/cpm"
  write_executable "$contents/Helpers/cliproxy-manager"
  write_executable "$contents/Frameworks/Sparkle.framework/Autoupdate"
  : > "$resources/CLIProxyManager.icns"
  printf 'fixture cliproxyapi binary\n' > "$binary"
  chmod 755 "$binary"
  : > "$resources/Licenses/CLIProxyAPI-LICENSE.txt"
  : > "$resources/ProviderImages/claude.png"
  : > "$resources/ProviderImages/codex.png"

  binary_sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
  binary_size="$(wc -c < "$binary" | tr -d '[:space:]')"
  cat > "$manifest" <<EOF
{
  "vendoredBinarySha256": "$binary_sha",
  "vendoredBinarySizeBytes": $binary_size
}
EOF
}

expect_failure() {
  local label="$1"
  local expected_diagnostic="$2"
  shift 2
  local stderr_file="$sandbox/${label}.err"

  if run_checker "$@" >"$sandbox/${label}.out" 2>"$stderr_file"; then
    fail "$label should fail"
  fi
  grep -Fx "$expected_diagnostic" "$stderr_file" >/dev/null ||
    fail "$label should emit the fixed diagnostic: $expected_diagnostic"
}

assert_valid() {
  local app="$1"
  local version="$2"
  local build="$3"
  local channel="$4"
  run_checker --app "$app" --version "$version" --build "$build" --channel "$channel" \
    >"$sandbox/valid-${channel}.out" 2>"$sandbox/valid-${channel}.err" ||
    fail "valid $channel app should pass without codesign"
}

create_app "$sandbox/development.app" 1.2.3 42 development
assert_valid "$sandbox/development.app" 1.2.3 42 development

create_app "$sandbox/official.app" 1.2.3 42 official
assert_valid "$sandbox/official.app" 1.2.3 42 official

create_app "$sandbox/int64-boundary.app" 1.2.3 9223372036854775807 official
assert_valid "$sandbox/int64-boundary.app" 1.2.3 9223372036854775807 official

for metadata_key in \
  CFBundleIdentifier \
  CFBundleName \
  CFBundleDisplayName \
  CFBundleExecutable \
  CFBundleIconFile \
  CFBundleShortVersionString \
  CFBundleVersion; do
  app="$sandbox/metadata-${metadata_key}.app"
  create_app "$app" 1.2.3 42 official
  plutil -replace "$metadata_key" -string $'fixture@example.com\nPROMPT_SENTINEL' "$app/Contents/Info.plist"
  expect_failure "metadata-${metadata_key}" 'App structure validation failed: metadata' \
    --app "$app" --version 1.2.3 --build 42 --channel official
  ! grep -F 'fixture@example.com' "$sandbox/metadata-${metadata_key}.err" >/dev/null ||
    fail "metadata diagnostics must not expose plist values"
  ! grep -F 'PROMPT_SENTINEL' "$sandbox/metadata-${metadata_key}.err" >/dev/null ||
    fail "metadata diagnostics must not expose plist values"
done

app="$sandbox/development-marker.app"
create_app "$app" 1.2.3 42 development
plutil -remove CLIProxyManagerReleaseChannel "$app/Contents/Info.plist"
expect_failure development-marker 'App structure validation failed: release channel marker' \
  --app "$app" --version 1.2.3 --build 42 --channel development

app="$sandbox/official-marker.app"
create_app "$app" 1.2.3 42 official
plutil -insert CLIProxyManagerReleaseChannel -string development "$app/Contents/Info.plist"
expect_failure official-marker 'App structure validation failed: release channel marker' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/main-executable.app"
create_app "$app" 1.2.3 42 official
chmod 644 "$app/Contents/MacOS/CLIProxyManager"
expect_failure main-executable 'App structure validation failed: main executable' \
  --app "$app" --version 1.2.3 --build 42 --channel official

for helper in cpm cliproxy-manager; do
  app="$sandbox/helper-${helper}.app"
  create_app "$app" 1.2.3 42 official
  chmod 644 "$app/Contents/Helpers/$helper"
  expect_failure "helper-${helper}" 'App structure validation failed: helper executables' \
    --app "$app" --version 1.2.3 --build 42 --channel official
done

app="$sandbox/icon.app"
create_app "$app" 1.2.3 42 official
rm -f "$app/Contents/Resources/CLIProxyManager.icns"
expect_failure icon 'App structure validation failed: icon' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/autoupdate.app"
create_app "$app" 1.2.3 42 official
chmod 644 "$app/Contents/Frameworks/Sparkle.framework/Autoupdate"
expect_failure autoupdate 'App structure validation failed: Sparkle Autoupdate' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/updater.app"
create_app "$app" 1.2.3 42 official
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Updater.app"
expect_failure updater 'App structure validation failed: Sparkle Updater' \
  --app "$app" --version 1.2.3 --build 42 --channel official

for legacy_resource in cpm cliproxy-manager; do
  app="$sandbox/legacy-${legacy_resource}.app"
  create_app "$app" 1.2.3 42 official
  : > "$app/Contents/Resources/$legacy_resource"
  expect_failure "legacy-${legacy_resource}" 'App structure validation failed: unexpected resource helper' \
    --app "$app" --version 1.2.3 --build 42 --channel official
done

for resource_path in \
  'cliproxyapi/cliproxyapi.manifest.json' \
  'Licenses/CLIProxyAPI-LICENSE.txt' \
  'ProviderImages/claude.png' \
  'ProviderImages/codex.png'; do
  app="$sandbox/resource-$(basename "$resource_path").app"
  create_app "$app" 1.2.3 42 official
  rm -f "$app/Contents/Resources/$resource_path"
  expect_failure "resource-$(basename "$resource_path")" 'App structure validation failed: resource contents' \
    --app "$app" --version 1.2.3 --build 42 --channel official
done

app="$sandbox/bundled-binary-mode.app"
create_app "$app" 1.2.3 42 official
chmod 644 "$app/Contents/Resources/cliproxyapi/cliproxyapi"
expect_failure bundled-binary-mode 'App structure validation failed: bundled proxy binary' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/binary-checksum.app"
create_app "$app" 1.2.3 42 official
plutil -replace vendoredBinarySha256 -string '0000000000000000000000000000000000000000000000000000000000000000' \
  "$app/Contents/Resources/cliproxyapi/cliproxyapi.manifest.json"
expect_failure binary-checksum 'App structure validation failed: bundled proxy binary checksum' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/binary-size.app"
create_app "$app" 1.2.3 42 official
plutil -replace vendoredBinarySizeBytes -integer 1 \
  "$app/Contents/Resources/cliproxyapi/cliproxyapi.manifest.json"
expect_failure binary-size 'App structure validation failed: bundled proxy binary size' \
  --app "$app" --version 1.2.3 --build 42 --channel official

app="$sandbox/argument-validation.app"
create_app "$app" 1.2.3 42 official
expect_failure invalid-version 'Invalid checker arguments' \
  --app "$app" --version 01.2.3 --build 42 --channel official
expect_failure invalid-build 'Invalid checker arguments' \
  --app "$app" --version 1.2.3 --build 0 --channel official
expect_failure overflow-build 'Invalid checker arguments' \
  --app "$app" --version 1.2.3 --build 9223372036854775808 --channel official
expect_failure invalid-channel 'Invalid checker arguments' \
  --app "$app" --version 1.2.3 --build 42 --channel preview
expect_failure missing-option 'Invalid checker arguments' \
  --app "$app" --version 1.2.3 --build 42

untrusted_app="$sandbox/untrusted@example.com"
expect_failure untrusted-path 'App structure validation failed: app bundle' \
  --app "$untrusted_app" --version 1.2.3 --build 42 --channel official
! grep -F 'untrusted@example.com' "$sandbox/untrusted-path.err" >/dev/null ||
  fail "app diagnostics must not expose supplied paths"

printf 'verify-app-structure tests passed\n'
