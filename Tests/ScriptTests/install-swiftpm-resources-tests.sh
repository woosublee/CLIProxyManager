#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/install-swiftpm-resources.sh"
BUNDLE_NAME='CLIProxyManager_CLIProxyManagerApp.bundle'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "install-swiftpm-resources.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/install-swiftpm-resources-tests.XXXXXX)"
trap 'chmod -R u+w "$sandbox" 2>/dev/null; rm -rf "$sandbox"' EXIT

write_resources() {
  local root="$1"
  mkdir -p "$root/Licenses" "$root/ProviderImages" "$root/cliproxyapi"
  printf 'license' > "$root/Licenses/CLIProxyAPI-LICENSE.txt"
  printf 'png' > "$root/ProviderImages/claude.png"
  printf 'png' > "$root/ProviderImages/codex.png"
  printf '{}' > "$root/cliproxyapi/cliproxyapi.manifest.json"
}

assert_flattened() {
  local name="$1"
  local resources="$2"
  [[ -f "$resources/Licenses/CLIProxyAPI-LICENSE.txt" &&
     -f "$resources/ProviderImages/claude.png" &&
     -f "$resources/ProviderImages/codex.png" &&
     -f "$resources/cliproxyapi/cliproxyapi.manifest.json" ]] ||
    fail "$name: resources must be copied directly into the app Resources directory"
  [[ ! -e "$resources/Contents" && ! -e "$resources/Info.plist" && ! -e "$resources/_CodeSignature" ]] ||
    fail "$name: resource bundle metadata must not reach the app Resources directory"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("$SOURCE_SCRIPT" "$@" 2>&1)"; then
    fail "$name: expected failure"
  fi
  [[ "$output" == *"$expected"* ]] || fail "$name: expected '$expected', got '$output'"
}

# Native engine: the resource bundle is a flat directory.
bin="$sandbox/native/bin"
resources="$sandbox/native/Resources"
mkdir -p "$bin/$BUNDLE_NAME" "$resources"
write_resources "$bin/$BUNDLE_NAME"
"$SOURCE_SCRIPT" "$bin" "$resources" || fail "native layout should install"
assert_flattened native "$resources"

# swiftbuild engine: resources live under Contents/Resources beside bundle metadata.
bin="$sandbox/swiftbuild/bin"
resources="$sandbox/swiftbuild/Resources"
mkdir -p "$bin/$BUNDLE_NAME/Contents/_CodeSignature" "$resources"
printf 'plist' > "$bin/$BUNDLE_NAME/Contents/Info.plist"
printf 'sig' > "$bin/$BUNDLE_NAME/Contents/_CodeSignature/CodeResources"
write_resources "$bin/$BUNDLE_NAME/Contents/Resources"
"$SOURCE_SCRIPT" "$bin" "$resources" || fail "swiftbuild layout should install"
assert_flattened swiftbuild "$resources"

bin="$sandbox/missing/bin"
mkdir -p "$bin" "$sandbox/missing/Resources"
expect_failure missing-bundle 'Missing SwiftPM resource bundle' "$bin" "$sandbox/missing/Resources"

bin="$sandbox/duplicate/bin"
mkdir -p "$bin/$BUNDLE_NAME" "$bin/Other_CLIProxyManagerApp.bundle" "$sandbox/duplicate/Resources"
expect_failure duplicate-bundle 'Expected one CLIProxyManagerApp resource bundle' "$bin" "$sandbox/duplicate/Resources"

bin="$sandbox/contents-only/bin"
mkdir -p "$bin/$BUNDLE_NAME/Contents" "$sandbox/contents-only/Resources"
printf 'plist' > "$bin/$BUNDLE_NAME/Contents/Info.plist"
expect_failure contents-without-resources 'Contents/Info.plist without Contents/Resources' \
  "$bin" "$sandbox/contents-only/Resources"

bin="$sandbox/missing-resources/bin"
mkdir -p "$bin/$BUNDLE_NAME"
expect_failure missing-resources-dir 'Missing app resources directory' "$bin" "$sandbox/missing-resources/Resources"

# Root ignores directory permissions, so the copy failure cannot be simulated there.
if [[ "$EUID" -ne 0 ]]; then
  bin="$sandbox/copy-failure/bin"
  resources="$sandbox/copy-failure/Resources"
  mkdir -p "$bin/$BUNDLE_NAME" "$resources"
  write_resources "$bin/$BUNDLE_NAME"
  chmod 500 "$resources"
  expect_failure copy-failure 'Unable to copy SwiftPM resources' "$bin" "$resources"
  chmod 700 "$resources"
fi

expect_failure usage 'Usage: scripts/install-swiftpm-resources.sh' "$sandbox"

printf 'install-swiftpm-resources tests passed\n'
