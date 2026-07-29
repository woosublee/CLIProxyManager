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
printf '%s' "$json_output" | plutil -convert xml1 -o /dev/null - >/dev/null || fail "JSON output should parse"
[[ "$(printf '%s' "$json_output" | plutil -extract version raw -)" == "0.2.0" ]] || fail "JSON version mismatch"
[[ "$(printf '%s' "$json_output" | plutil -extract build raw -)" == "7" ]] || fail "JSON build mismatch"
[[ "$(printf '%s' "$json_output" | plutil -extract channel raw -)" == "official" ]] || fail "JSON channel mismatch"

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

printf 'release version resolver tests passed\n'
