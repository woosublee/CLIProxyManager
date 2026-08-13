#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/resolve-bundled-cliproxyapi.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

sandbox="$(mktemp -d /tmp/resolve-bundled-cliproxyapi-tests.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/lipo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == '-archs' ]] || exit 64
printf '%s\n' "${FAKE_ARCHITECTURE:-arm64}"
SH
chmod 755 "$fake_bin/lipo"

fake_binary="$sandbox/cli-proxy-api"
cat > "$fake_binary" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == '--version' ]]; then
  printf 'CLIProxyAPI Version: 9.8.7, Commit: fixturecommit, BuiltAt: 2026-05-10T01:02:03Z\n'
  exit 2
fi
exit 0
SH
chmod 755 "$fake_binary"
archive="$sandbox/CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz"
tar -czf "$archive" -C "$sandbox" cli-proxy-api
archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
binary_sha="$(shasum -a 256 "$fake_binary" | awk '{print $1}')"
binary_size="$(wc -c < "$fake_binary" | tr -d '[:space:]')"
manifest="$sandbox/cliproxyapi.manifest.json"

write_manifest() {
  local archive_checksum="$1"
  local binary_checksum="$2"
  local size="$3"
  local commit="${4:-fixturecommit}"
  cat > "$manifest" <<EOF
{
  "name": "cliproxyapi",
  "version": "9.8.7",
  "commit": "$commit",
  "builtAt": "2026-05-10T01:02:03Z",
  "source": "https://github.com/router-for-me/CLIProxyAPI/releases/download/v9.8.7/CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz",
  "upstreamRepository": "router-for-me/CLIProxyAPI",
  "upstreamTag": "v9.8.7",
  "upstreamAsset": "CLIProxyAPI_9.8.7_darwin_aarch64.tar.gz",
  "upstreamAssetSha256": "$archive_checksum",
  "vendoredBinaryName": "cliproxyapi",
  "vendoredBinarySha256": "$binary_checksum",
  "vendoredBinarySizeBytes": $size,
  "vendoredFromArchivePath": "cli-proxy-api",
  "target": {"operatingSystem": "darwin", "architecture": "arm64"}
}
EOF
}
write_manifest "$archive_sha" "$binary_sha" "$binary_size"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
[[ "$1" == '-fsSL' &&
   "$2" == '--connect-timeout' && "$3" == '15' &&
   "$4" == '--max-time' && "$5" == '600' &&
   "$7" == '-o' ]] || exit 64
cp "$FAKE_ARCHIVE" "$8"
SH
chmod 755 "$fake_bin/curl"

run_resolver() {
  local cache_root="$1"
  local output="$2"
  shift 2
  FAKE_ARCHIVE="$archive" \
  FAKE_CURL_LOG="$sandbox/curl.log" \
  CLIPROXYAPI_CURL="$fake_bin/curl" \
  CLIPROXYAPI_LIPO="$fake_bin/lipo" \
  "$SCRIPT" --manifest "$manifest" --cache-root "$cache_root" --output "$output" "$@"
}

help_output="$($SCRIPT --help)"
[[ "$help_output" == *'--offline'* ]] || fail 'help should document offline mode'
[[ "$help_output" == *'--prune-cache'* ]] || fail 'help should document cache pruning'
source_binary_path='Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi'
if git -C "$REPO_ROOT" ls-files --error-unmatch "$source_binary_path" >/dev/null 2>&1; then
  fail 'the source CLIProxyAPI binary must not remain Git-tracked'
fi
git -C "$REPO_ROOT" check-ignore -q "$source_binary_path" ||
  fail 'the source CLIProxyAPI binary path must be ignored'
git -C "$REPO_ROOT" ls-files --error-unmatch \
  'Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json' >/dev/null ||
  fail 'the pinned CLIProxyAPI manifest must remain Git-tracked'

cache="$sandbox/cache"
output="$sandbox/output/cliproxyapi"
: > "$sandbox/curl.log"
run_resolver "$cache" "$output" > "$sandbox/first.out"
[[ -x "$output" ]] || fail 'cold resolve should materialize an executable output'
[[ "$(shasum -a 256 "$output" | awk '{print $1}')" == "$binary_sha" ]] || fail 'cold resolve output checksum mismatch'
[[ -x "$cache/$binary_sha/cliproxyapi" ]] || fail 'cold resolve should publish a cache entry'
[[ "$(wc -l < "$sandbox/curl.log" | tr -d '[:space:]')" == '1' ]] || fail 'cold resolve should download once'

: > "$sandbox/curl.log"
run_resolver "$cache" "$output" > "$sandbox/cache-hit.out"
[[ ! -s "$sandbox/curl.log" ]] || fail 'verified cache hit must not download'

printf 'preserved-output\n' > "$output"
missing_cache="$sandbox/missing-cache"
if run_resolver "$missing_cache" "$output" --offline >"$sandbox/offline.out" 2>"$sandbox/offline.err"; then
  fail 'offline cache miss should fail'
fi
grep -Fx 'ERROR: Bundled CLIProxyAPI cache is unavailable in offline mode' "$sandbox/offline.err" >/dev/null ||
  fail 'offline miss should explain the cache-only policy'
grep -Fx 'preserved-output' "$output" >/dev/null || fail 'offline miss must preserve prior output'

cp "$fake_binary" "$cache/$binary_sha/cliproxyapi"
printf 'corruption\n' >> "$cache/$binary_sha/cliproxyapi"
: > "$sandbox/curl.log"
run_resolver "$cache" "$output" > "$sandbox/corrupt-cache.out"
[[ "$(wc -l < "$sandbox/curl.log" | tr -d '[:space:]')" == '1' ]] || fail 'corrupt cache should download a replacement'
[[ "$(shasum -a 256 "$cache/$binary_sha/cliproxyapi" | awk '{print $1}')" == "$binary_sha" ]] || fail 'replacement cache checksum mismatch'

printf 'prior-output\n' > "$output"
write_manifest 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$binary_sha" "$binary_size"
if run_resolver "$sandbox/checksum-cache" "$output" >"$sandbox/checksum.out" 2>"$sandbox/checksum.err"; then
  fail 'archive checksum mismatch should fail'
fi
grep -Fx 'ERROR: Pinned CLIProxyAPI archive checksum mismatch' "$sandbox/checksum.err" >/dev/null ||
  fail 'archive checksum mismatch should use a fixed diagnostic'
grep -Fx 'prior-output' "$output" >/dev/null || fail 'checksum mismatch must preserve prior output'

write_manifest "$archive_sha" "$binary_sha" "$binary_size" othercommit
if run_resolver "$sandbox/metadata-cache" "$output" >"$sandbox/metadata.out" 2>"$sandbox/metadata.err"; then
  fail 'metadata mismatch should fail'
fi
grep -Fx 'ERROR: Pinned CLIProxyAPI binary does not match the manifest' "$sandbox/metadata.err" >/dev/null ||
  fail 'metadata mismatch should use a fixed diagnostic'

write_manifest "$archive_sha" "$binary_sha" "$binary_size"
if FAKE_ARCHITECTURE=x86_64 run_resolver "$sandbox/architecture-cache" "$output" >"$sandbox/architecture.out" 2>"$sandbox/architecture.err"; then
  fail 'wrong architecture should fail'
fi
grep -Fx 'ERROR: Pinned CLIProxyAPI binary does not match the manifest' "$sandbox/architecture.err" >/dev/null ||
  fail 'wrong architecture should use a fixed diagnostic'

plutil -replace upstreamTag -string v9.8.6 "$manifest"
if run_resolver "$sandbox/malformed-cache" "$output" >"$sandbox/malformed.out" 2>"$sandbox/malformed.err"; then
  fail 'inconsistent manifest should fail'
fi
grep -Fx 'ERROR: Bundled CLIProxyAPI manifest is invalid' "$sandbox/malformed.err" >/dev/null ||
  fail 'inconsistent manifest should use a fixed diagnostic'

write_manifest "$archive_sha" "$binary_sha" "$binary_size"
prune_cache="$sandbox/prune-cache"
mkdir -p "$prune_cache/$binary_sha" \
  "$prune_cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "$prune_cache/unrelated-entry"
cp "$fake_binary" "$prune_cache/$binary_sha/cliproxyapi"
cp "$fake_binary" "$prune_cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/cliproxyapi"
: > "$prune_cache/unrelated-entry/keep"
"$SCRIPT" --manifest "$manifest" --cache-root "$prune_cache" --prune-cache > "$sandbox/prune.out"
[[ -x "$prune_cache/$binary_sha/cliproxyapi" ]] || fail 'cache pruning must keep the currently pinned binary'
[[ ! -e "$prune_cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] ||
  fail 'cache pruning should remove stale hash-addressed binaries'
[[ -e "$prune_cache/unrelated-entry/keep" ]] || fail 'cache pruning must preserve unrelated cache entries'

printf 'resolve-bundled-cliproxyapi tests passed\n'
