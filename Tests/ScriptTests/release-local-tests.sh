#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/release-local.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$SCRIPT" ]] || fail "release-local.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/release-local-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

repo="$sandbox/repo"
cp -R "$REPO_ROOT" "$repo"
rm -rf "$repo/.git" "$repo/.build" "$repo/build"

fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"
log="$sandbox/calls.log"

cat > "$fake_bin/plutil" <<'FAKE_PLUTIL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-extract" ]] || exit 10
[[ "${2:-}" == "CFBundleVersion" ]] || exit 11
[[ "${3:-}" == "raw" ]] || exit 12
[[ "${4:-}" == "Info.plist" ]] || exit 13
printf '42\n'
FAKE_PLUTIL
chmod +x "$fake_bin/plutil"

cat > "$fake_bin/make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
[[ "$*" == 'CODESIGN_IDENTITY=- VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' ]] || {
  echo "unexpected make args: $*" >&2
  exit 20
}
mkdir -p build
printf 'fake dmg' > build/CLIProxyManager-1.2.3.dmg
FAKE_MAKE
chmod +x "$fake_bin/make"

mkdir -p "$repo/scripts"
cat > "$repo/scripts/generate-sparkle-appcast.sh" <<'FAKE_APPCAST'
#!/usr/bin/env bash
set -euo pipefail
printf 'appcast RELEASE_TAG=%s VERSION=%s BUILD_NUMBER=%s DMG_PATH=%s APPCAST_PATH=%s SPARKLE_PRIVATE_KEY=%s\n' \
  "${RELEASE_TAG:-}" \
  "${VERSION:-}" \
  "${BUILD_NUMBER:-}" \
  "${DMG_PATH:-}" \
  "${APPCAST_PATH:-}" \
  "${SPARKLE_PRIVATE_KEY:-}" >> "$RELEASE_LOCAL_TEST_LOG"
[[ "${RELEASE_TAG:-}" == "v1.2.3" ]] || exit 30
[[ "${VERSION:-}" == "1.2.3" ]] || exit 31
[[ "${BUILD_NUMBER:-}" == "42" ]] || exit 32
[[ "${DMG_PATH:-}" == "build/CLIProxyManager-1.2.3.dmg" ]] || exit 33
[[ "${APPCAST_PATH:-}" == "build/appcast.xml" ]] || exit 34
[[ -z "${SPARKLE_PRIVATE_KEY:-}" ]] || exit 35
printf '<rss />' > "$APPCAST_PATH"
FAKE_APPCAST
chmod +x "$repo/scripts/generate-sparkle-appcast.sh"

cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$RELEASE_LOCAL_TEST_LOG"
case "$*" in
  'release view v1.2.3')
    exit 1
    ;;
  'release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Ad-hoc signed, non-notarized DMG with Sparkle appcast.')
    exit 0
    ;;
  'release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml --clobber')
    exit 0
    ;;
  *)
    echo "unexpected gh args: $*" >&2
    exit 40
    ;;
esac
FAKE_GH
chmod +x "$fake_bin/gh"

(
  cd "$repo"
  PATH="$fake_bin:$PATH" \
  RELEASE_LOCAL_TEST_LOG="$log" \
  "$SCRIPT" v1.2.3
)

expected="$sandbox/expected.log"
printf '%s\n' \
  'make CODESIGN_IDENTITY=- VERSION=1.2.3 BUILD_NUMBER=42 verify-dmg' \
  'appcast RELEASE_TAG=v1.2.3 VERSION=1.2.3 BUILD_NUMBER=42 DMG_PATH=build/CLIProxyManager-1.2.3.dmg APPCAST_PATH=build/appcast.xml SPARKLE_PRIVATE_KEY=' \
  'gh release view v1.2.3' \
  'gh release create v1.2.3 --verify-tag --title CLIProxyManager 1.2.3 --notes Ad-hoc signed, non-notarized DMG with Sparkle appcast.' \
  'gh release upload v1.2.3 build/CLIProxyManager-1.2.3.dmg build/appcast.xml --clobber' \
  > "$expected"

diff -u "$expected" "$log" || fail "release-local.sh should call make, appcast generation, and gh upload in order"

if (
  cd "$repo"
  PATH="$fake_bin:$PATH" \
  RELEASE_LOCAL_TEST_LOG="$sandbox/invalid.log" \
  "$SCRIPT" 1.2.3
) >/tmp/release-local-invalid.out 2>/tmp/release-local-invalid.err; then
  fail "release-local.sh should reject tags without v prefix"
fi

grep -q 'RELEASE_TAG must start with v' /tmp/release-local-invalid.err || fail "invalid tag should explain v-prefix requirement"
