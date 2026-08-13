#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/release-local.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_no_remote_writes() {
  local log_file="$1"
  if [[ -e "$log_file" ]]; then
    ! grep -E 'git (tag|push)|gh release (create|upload)' "$log_file" >/dev/null ||
      fail "failure path must not write tags or releases"
  fi
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "release-local.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/release-local-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

repo="$sandbox/repo"
fake_bin="$sandbox/bin"
mkdir -p "$repo/scripts" "$repo/build" "$fake_bin"
cp "$REPO_ROOT/scripts/release-local.sh" "$repo/scripts/release-local.sh"
chmod +x "$repo/scripts/release-local.sh"
release_script="$repo/scripts/release-local.sh"

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
      *' --appcast '*) exit 0 ;;
      *) exit 0 ;;
    esac
  ;;
  *) exit 61 ;;
esac
SH

cat > "$repo/scripts/generate-sparkle-appcast.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'appcast repository=%s\n' "${REPOSITORY:-missing}" >> "$RELEASE_LOCAL_TEST_LOG"
printf '<rss />\n' > build/appcast.xml
SH

chmod +x "$repo/scripts/"*.sh

cat > "$fake_bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$*" in
  'find-identity -v -p codesigning')
    printf '  1) A39E5510B609DE50287781AFDBAE19C4F91783C7 "cliproxymanager"\n'
    printf '     1 valid identities found\n'
  ;;
  *) exit 50 ;;
esac
SH
chmod +x "$fake_bin/security"

cat > "$fake_bin/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$*" in
  resolve-bundled-proxy)
    [[ "${RESOLVE_PROXY_SCENARIO:-pass}" == 'pass' ]] || exit 62
  ;;
  verify-dmg)
    mkdir -p build
    printf 'fake dmg' > build/CLIProxyManager-1.2.3.dmg
  ;;
  *) exit 20 ;;
esac
SH
chmod +x "$fake_bin/make"

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

run_release() {
  local log_file="$1"
  shift
  (
    cd "$repo"
    PATH="$fake_bin:$PATH" RELEASE_LOCAL_TEST_LOG="$log_file" "$@"
  )
}

normal_log="$sandbox/normal.log"
run_release "$normal_log" "$release_script" v1.2.3
expected="$sandbox/expected.log"
printf '%s\n' \
  'sync --check' \
  'gh repo view --json nameWithOwner --jq .nameWithOwner' \
  'git ls-remote --tags origin refs/tags/v1.2.3 refs/tags/v1.2.3^{}' \
  'monotonic --repository example/CLIProxyManager --provenance build/release-provenance.json' \
  'make resolve-bundled-proxy' \
  'security find-identity -v -p codesigning' \
  'make verify-dmg' \
  'appcast repository=example/CLIProxyManager' \
  'verify-artifacts --source-plist Info.plist --app build/CLIProxyManager.app --dmg build/CLIProxyManager-1.2.3.dmg --appcast build/appcast.xml --provenance build/release-provenance.json --official' \
  'monotonic --repository example/CLIProxyManager --provenance build/release-provenance.json' \
  'git ls-remote --tags origin refs/tags/v1.2.3 refs/tags/v1.2.3^{}' \
  'git tag v1.2.3 HEAD' \
  'git push origin refs/tags/v1.2.3' \
  'gh release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes-file build/release-notes.md' \
  'gh release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml build/release-provenance.json' \
  > "$expected"
diff -u "$expected" "$normal_log" || fail "normal release orchestration call order changed"

build_dir_log="$sandbox/build-dir-override.log"
build_dir_stderr="$sandbox/build-dir-override.err"
if BUILD_DIR=release-output run_release "$build_dir_log" "$release_script" v1.2.3 \
  >"$sandbox/build-dir-override.out" 2>"$build_dir_stderr"; then
  fail "release-local.sh must reject BUILD_DIR overrides"
fi
grep -F 'BUILD_DIR is fixed to build for local releases; remove the override' "$build_dir_stderr" >/dev/null ||
  fail "BUILD_DIR rejection should explain the canonical output directory"
if [[ -e "$build_dir_log" ]]; then
  ! grep -F 'make verify-dmg' "$build_dir_log" >/dev/null || fail "BUILD_DIR override must fail before build"
fi
assert_no_remote_writes "$build_dir_log"

repository_mismatch_log="$sandbox/repository-mismatch.log"
repository_mismatch_stderr="$sandbox/repository-mismatch.err"
if REPOSITORY=other/CLIProxyManager run_release "$repository_mismatch_log" "$release_script" v1.2.3 \
  >"$sandbox/repository-mismatch.out" 2>"$repository_mismatch_stderr"; then
  fail "release-local.sh must reject a repository override for another checkout"
fi
grep -F 'REPOSITORY must match the current GitHub checkout' "$repository_mismatch_stderr" >/dev/null ||
  fail "repository mismatch should explain the current-checkout policy"
grep -F 'gh repo view --json nameWithOwner --jq .nameWithOwner' "$repository_mismatch_log" >/dev/null ||
  fail "repository override must still resolve the current checkout"
! grep -F 'git ls-remote' "$repository_mismatch_log" >/dev/null || fail "repository mismatch must fail before remote tag lookup"
assert_no_remote_writes "$repository_mismatch_log"

tag_mismatch_log="$sandbox/tag-mismatch.log"
if RELEASE_LOCAL_GIT_SCENARIO=matching run_release "$tag_mismatch_log" "$release_script" v1.2.3; then
  fail "normal release must reject an existing tag"
fi
assert_no_remote_writes "$tag_mismatch_log"

monotonic_log="$sandbox/monotonic.log"
if MONOTONIC_SCENARIO=fail run_release "$monotonic_log" "$release_script" v1.2.3; then
  fail "release must reject a non-monotonic version"
fi
assert_no_remote_writes "$monotonic_log"

proxy_resolution_log="$sandbox/proxy-resolution.log"
if RESOLVE_PROXY_SCENARIO=fail run_release "$proxy_resolution_log" "$release_script" v1.2.3; then
  fail "release must fail when the pinned proxy artifact cannot be resolved"
fi
grep -Fx 'make resolve-bundled-proxy' "$proxy_resolution_log" >/dev/null || fail "release should resolve the proxy before signing"
! grep -F 'security find-identity' "$proxy_resolution_log" >/dev/null || fail "proxy resolution failure must stop before signing identity lookup"
! grep -F 'make verify-dmg' "$proxy_resolution_log" >/dev/null || fail "proxy resolution failure must stop before build"
assert_no_remote_writes "$proxy_resolution_log"

parity_log="$sandbox/parity.log"
if VERIFY_SCENARIO=fail-final run_release "$parity_log" "$release_script" v1.2.3; then
  fail "release must reject artifacts that fail final parity verification"
fi
assert_no_remote_writes "$parity_log"

previous_fixture="$sandbox/previous-appcast.xml"
printf '<rss />\n' > "$previous_fixture"
fallback_log="$sandbox/fallback.log"
run_release "$fallback_log" "$release_script" v1.2.3 --previous-appcast "$previous_fixture"
[[ "$(grep -F -- "--previous-appcast $previous_fixture" "$fallback_log" | wc -l | tr -d '[:space:]')" == '2' ]] || fail "fallback source must be checked twice"
grep -F 'explicit local fallback appcast' "$repo/build/release-notes.md" >/dev/null || fail "fallback trust must be documented"
! grep -F "$previous_fixture" "$repo/build/release-notes.md" >/dev/null || fail "release notes must not expose the fallback path"

resume_log="$sandbox/resume.log"
RELEASE_LOCAL_GIT_SCENARIO=matching \
RELEASE_LOCAL_RELEASE_SCENARIO=no-appcast \
ALLOW_LOCAL_RELEASE_CLOBBER=1 \
run_release "$resume_log" "$release_script" v1.2.3
! grep -E 'git (tag|push)' "$resume_log" >/dev/null || fail "resume must not write a tag"
tail -n 1 "$resume_log" | grep -Fx 'gh release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml build/release-provenance.json --clobber' >/dev/null || fail "resume must finish by clobbering assets"

other_log="$sandbox/other-tag.log"
if RELEASE_LOCAL_GIT_SCENARIO=other ALLOW_LOCAL_RELEASE_CLOBBER=1 \
  run_release "$other_log" "$release_script" v1.2.3; then
  fail "resume must reject a tag pointing to another commit"
fi
! grep -F 'make verify-dmg' "$other_log" >/dev/null || fail "tag mismatch must fail before build"

existing_appcast="$sandbox/existing-appcast.xml"
printf '<rss />\n' > "$existing_appcast"
valid_log="$sandbox/valid-existing.log"
if RELEASE_LOCAL_GIT_SCENARIO=matching \
  RELEASE_LOCAL_RELEASE_SCENARIO=valid-appcast \
  RELEASE_LOCAL_EXISTING_APPCAST="$existing_appcast" \
  VERIFY_SCENARIO=valid-existing \
  ALLOW_LOCAL_RELEASE_CLOBBER=1 \
  run_release "$valid_log" "$release_script" v1.2.3 \
  >"$sandbox/valid-existing.out" 2>"$sandbox/valid-existing.err"; then
  fail "resume must reject an already valid appcast"
fi
grep -F 'A valid canonical appcast is already published; clobber is not allowed' "$sandbox/valid-existing.err" >/dev/null || fail "valid existing appcast rejection missing"
assert_no_remote_writes "$valid_log"

if run_release "$sandbox/bad-arguments.log" "$release_script" 1.2.3; then
  fail "release-local.sh should reject a non-canonical tag"
fi

leading_zero_tag_stderr="$sandbox/leading-zero-tag.err"
if run_release "$sandbox/leading-zero-tag.log" "$release_script" v01.2.3 \
  >"$sandbox/leading-zero-tag.out" 2>"$leading_zero_tag_stderr"; then
  fail "release-local.sh should reject a leading-zero SemVer tag"
fi
grep -F 'Release tag mismatch: expected v1.2.3, actual invalid' "$leading_zero_tag_stderr" >/dev/null ||
  fail "leading-zero tags must use the safe invalid diagnostic"
assert_no_remote_writes "$sandbox/leading-zero-tag.log"

grep -F "RELEASE_APP_BUNDLE='build/CLIProxyManager.app'" "$SOURCE_SCRIPT" >/dev/null ||
  fail "release-local.sh must bind verification to the canonical build app path"

untrusted_tag=$'v9.9.9 fixture@example.com\nPROMPT_SENTINEL /fixture-path-sentinel'
untrusted_tag_log="$sandbox/untrusted-tag.log"
untrusted_tag_stderr="$sandbox/untrusted-tag.err"
: > "$untrusted_tag_log"
if run_release "$untrusted_tag_log" "$release_script" "$untrusted_tag" >"$sandbox/untrusted-tag.out" 2>"$untrusted_tag_stderr"; then
  fail "release-local.sh should reject an untrusted mismatched tag"
fi
grep -F 'Release tag mismatch: expected v1.2.3, actual invalid' "$untrusted_tag_stderr" >/dev/null ||
  fail "untrusted tag mismatch should redact the actual tag"
! grep -F 'fixture@example.com' "$untrusted_tag_stderr" >/dev/null || fail "tag mismatch must not expose email fixtures"
! grep -F 'PROMPT_SENTINEL' "$untrusted_tag_stderr" >/dev/null || fail "tag mismatch must not expose prompt fixtures"
! grep -F '/fixture-path-sentinel' "$untrusted_tag_stderr" >/dev/null || fail "tag mismatch must not expose path fixtures"
assert_no_remote_writes "$untrusted_tag_log"

if VERSION=1.2.3 run_release "$sandbox/legacy-override.log" "$release_script" v1.2.3; then
  fail "release-local.sh should reject legacy overrides"
fi

network_log="$sandbox/network.log"
if RELEASE_LOCAL_GIT_SCENARIO=network run_release "$network_log" "$release_script" v1.2.3; then
  fail "release must fail closed when the remote tag cannot be queried"
fi
assert_no_remote_writes "$network_log"

partial_network_log="$sandbox/partial-network.log"
if RELEASE_LOCAL_GIT_SCENARIO=matching \
  RELEASE_LOCAL_RELEASE_SCENARIO=network \
  ALLOW_LOCAL_RELEASE_CLOBBER=1 \
  run_release "$partial_network_log" "$release_script" v1.2.3; then
  fail "resume must fail closed when the partial release cannot be queried"
fi
assert_no_remote_writes "$partial_network_log"

cat > "$fake_bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
printf '     0 valid identities found\n'
SH
chmod +x "$fake_bin/security"
missing_identity_log="$sandbox/missing-identity.log"
if run_release "$missing_identity_log" "$release_script" v1.2.3; then
  fail "release must require the cliproxymanager signing identity"
fi
assert_no_remote_writes "$missing_identity_log"
