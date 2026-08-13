#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CLIPROXY_MANAGER_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST="$REPO_ROOT/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json"
UPSTREAM_REPOSITORY="router-for-me/CLIProxyAPI"
# shellcheck source=scripts/cliproxyapi-artifact-lib.sh
source "$SCRIPT_DIR/cliproxyapi-artifact-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/vendor-cliproxyapi.sh <version>

Downloads the macOS arm64 CLIProxyAPI release asset, verifies checksums.txt,
and atomically updates cliproxyapi.manifest.json with the pinned source and
binary metadata. The binary itself is resolved at bundle build time.

Example:
  scripts/vendor-cliproxyapi.sh 7.0.0
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

write_manifest() {
  local destination="$1"
  local version="$2"
  local commit="$3"
  local built_at="$4"
  local source="$5"
  local asset="$6"
  local asset_sha="$7"
  local archive_path="$8"
  local binary_sha="$9"
  local size_bytes="${10}"
  local escaped_source
  escaped_source="$(printf '%s' "$source" | json_escape)"
  cat > "$destination" <<EOF
{
  "name": "cliproxyapi",
  "version": "$version",
  "commit": "$commit",
  "builtAt": "$built_at",
  "source": "$escaped_source",
  "upstreamRepository": "$UPSTREAM_REPOSITORY",
  "upstreamTag": "v$version",
  "upstreamAsset": "$asset",
  "upstreamAssetSha256": "$asset_sha",
  "vendoredBinaryName": "cliproxyapi",
  "vendoredBinarySha256": "$binary_sha",
  "vendoredBinarySizeBytes": $size_bytes,
  "vendoredFromArchivePath": "$archive_path",
  "target": {
    "operatingSystem": "darwin",
    "architecture": "arm64"
  }
}
EOF
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 1
}
[[ "$1" != '--help' && "$1" != '-h' ]] || {
  usage
  exit 0
}

requested_version="$1"
[[ "$requested_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail 'Version must use stable SemVer x.y.z'
tag="v$requested_version"
asset="CLIProxyAPI_${requested_version}_darwin_aarch64.tar.gz"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cliproxyapi-vendor.XXXXXX")"
staged_manifest=''
cleanup() {
  rm -rf "$work_dir"
  [[ -z "$staged_manifest" ]] || rm -f "$staged_manifest"
}
trap cleanup EXIT

"${CLIPROXYAPI_GH:-gh}" release download "$tag" --repo "$UPSTREAM_REPOSITORY" --dir "$work_dir" --pattern "$asset" --pattern checksums.txt ||
  fail 'Unable to download the upstream CLIProxyAPI release assets'
asset_sha="$(cliproxyapi_checksum_for_file "$work_dir/checksums.txt" "$asset")"
cliproxyapi_is_sha256 "$asset_sha" || fail 'Missing or invalid checksum entry for the CLIProxyAPI archive'
[[ "$(cliproxyapi_sha256_file "$work_dir/$asset")" == "$asset_sha" ]] ||
  fail 'Upstream CLIProxyAPI archive checksum verification failed'
"${CLIPROXYAPI_TAR:-/usr/bin/tar}" -xzf "$work_dir/$asset" -C "$work_dir" ||
  fail 'Unable to extract the upstream CLIProxyAPI archive'
binary="$work_dir/cli-proxy-api"
[[ -f "$binary" ]] || fail 'CLIProxyAPI archive did not contain cli-proxy-api'
chmod 755 "$binary"
cliproxyapi_is_arm64_binary "$binary" || fail 'Upstream CLIProxyAPI binary is not arm64'

version_line="$(cliproxyapi_parse_version_line "$binary")"
cliproxyapi_load_version_metadata "$version_line" ||
  fail 'Upstream CLIProxyAPI version metadata did not match the requested version'
version="$CLIPROXYAPI_BINARY_VERSION"
commit="$CLIPROXYAPI_BINARY_COMMIT"
built_at="$CLIPROXYAPI_BINARY_BUILT_AT"
[[ "$version" == "$requested_version" && -n "$commit" && -n "$built_at" ]] ||
  fail 'Upstream CLIProxyAPI version metadata did not match the requested version'
binary_sha="$(cliproxyapi_sha256_file "$binary")"
size_bytes="$(wc -c < "$binary" | tr -d '[:space:]')"

staged_manifest="$(mktemp "${MANIFEST}.tmp.XXXXXX")"
write_manifest "$staged_manifest" "$version" "$commit" "$built_at" \
  "https://github.com/$UPSTREAM_REPOSITORY/releases/download/$tag/$asset" \
  "$asset" "$asset_sha" 'cli-proxy-api' "$binary_sha" "$size_bytes"
cliproxyapi_load_manifest "$staged_manifest" && cliproxyapi_manifest_is_valid ||
  fail 'Generated CLIProxyAPI manifest is invalid'
mv -f "$staged_manifest" "$MANIFEST"
staged_manifest=''
printf 'Pinned CLIProxyAPI %s in %s\n' "$version" "$MANIFEST"
