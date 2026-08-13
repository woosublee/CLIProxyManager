#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vendor-cliproxyapi.sh"
LIBRARY="$REPO_ROOT/scripts/cliproxyapi-artifact-lib.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

help_output="$($SCRIPT --help)"
[[ "$help_output" == *'Usage: scripts/vendor-cliproxyapi.sh <version>'* ]] || fail 'help should document version usage'
[[ "$help_output" == *'checksums.txt'* ]] || fail 'help should document checksum verification'
[[ "$help_output" == *'binary itself is resolved at bundle build time'* ]] || fail 'help should document manifest-only resolution'

sandbox="$(mktemp -d /tmp/vendor-cliproxyapi-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
repo="$sandbox/repo"
mkdir -p "$repo/scripts" "$repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi" "$sandbox/bin"
cp "$SCRIPT" "$repo/scripts/"
cp "$LIBRARY" "$repo/scripts/"
chmod 755 "$repo/scripts/"*.sh

source_binary="$sandbox/cli-proxy-api"
cat > "$source_binary" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then
  printf 'CLIProxyAPI Version: %s, Commit: fixturecommit, BuiltAt: 2026-05-10T01:02:03Z\n' "${FAKE_VENDOR_VERSION:-9.8.7}"
  exit 2
fi
exit 0
SH
chmod 755 "$source_binary"
archive="$sandbox/CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz"
tar -czf "$archive" -C "$sandbox" cli-proxy-api
archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
printf '%s  *%s\n' "$archive_sha" 'CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz' > "$sandbox/checksums.txt"

cat > "$sandbox/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == 'release' && "$2" == 'download' && "$3" == 'v9.8.7' ]] || exit 64
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$destination"
cp "$FAKE_ARCHIVE" "$destination/CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz"
cp "$FAKE_CHECKSUMS" "$destination/checksums.txt"
SH
cat > "$sandbox/bin/lipo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == '-archs' ]] || exit 64
printf '%s\n' "${FAKE_VENDOR_ARCHITECTURE:-arm64}"
SH
chmod 755 "$sandbox/bin/gh" "$sandbox/bin/lipo"

manifest="$repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json"
printf 'previous-manifest\n' > "$manifest"
run_vendor() {
  CLIPROXY_MANAGER_REPO_ROOT="$repo" \
  CLIPROXYAPI_GH="$sandbox/bin/gh" \
  CLIPROXYAPI_LIPO="$sandbox/bin/lipo" \
  FAKE_ARCHIVE="$archive" \
  FAKE_CHECKSUMS="$sandbox/checksums.txt" \
  "$repo/scripts/vendor-cliproxyapi.sh" "$@"
}

run_vendor 9.8.7 > "$sandbox/vendor.out"
[[ -f "$manifest" ]] || fail 'vendor should write a manifest'
[[ ! -e "$repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi" ]] ||
  fail 'manifest-only vendor must not write a source binary'
grep -F '"version": "9.8.7"' "$manifest" >/dev/null || fail 'manifest should pin parsed version'
grep -F '"commit": "fixturecommit"' "$manifest" >/dev/null || fail 'manifest should pin parsed commit'
grep -F '"upstreamAssetSha256": "'"$archive_sha"'"' "$manifest" >/dev/null || fail 'manifest should pin archive checksum'
grep -F '"target": {' "$manifest" >/dev/null || fail 'manifest should declare target'

manifest_before="$(shasum -a 256 "$manifest" | awk '{print $1}')"
if FAKE_VENDOR_VERSION=9.8.8 run_vendor 9.8.7 > "$sandbox/mismatch.out" 2> "$sandbox/mismatch.err"; then
  fail 'version mismatch should fail'
fi
grep -Fx 'ERROR: Upstream CLIProxyAPI version metadata did not match the requested version' "$sandbox/mismatch.err" >/dev/null ||
  fail 'version mismatch should use a fixed diagnostic'
[[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" == "$manifest_before" ]] ||
  fail 'failed vendor should preserve prior manifest'

if FAKE_VENDOR_ARCHITECTURE=x86_64 run_vendor 9.8.7 > "$sandbox/architecture.out" 2> "$sandbox/architecture.err"; then
  fail 'wrong architecture should fail'
fi
grep -Fx 'ERROR: Upstream CLIProxyAPI binary is not arm64' "$sandbox/architecture.err" >/dev/null ||
  fail 'wrong architecture should use a fixed diagnostic'
[[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" == "$manifest_before" ]] ||
  fail 'architecture failure should preserve prior manifest'

if run_vendor --local "$source_binary" > "$sandbox/local.out" 2> "$sandbox/local.err"; then
  fail '--local should be rejected'
fi
grep -F 'Usage: scripts/vendor-cliproxyapi.sh <version>' "$sandbox/local.err" >/dev/null ||
  fail '--local rejection should show usage'

printf 'vendor-cliproxyapi tests passed\n'
