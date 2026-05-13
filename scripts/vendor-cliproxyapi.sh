#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CLIPROXY_MANAGER_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DEST_DIR="$REPO_ROOT/Sources/CLIProxyManagerApp/Resources/cliproxyapi"
DEST="$DEST_DIR/cliproxyapi"
MANIFEST="$DEST_DIR/cliproxyapi.manifest.json"
UPSTREAM_REPOSITORY="router-for-me/CLIProxyAPI"

usage() {
  cat <<'EOF'
Usage: scripts/vendor-cliproxyapi.sh <version>
       scripts/vendor-cliproxyapi.sh --local <binary-path> [--source-label <label>]

Downloads router-for-me/CLIProxyAPI release assets, verifies checksums.txt,
vendors the macOS arm64 CLIProxyAPI binary into the app resources, and writes
cliproxyapi.manifest.json with version, source, and checksum metadata.

Examples:
  scripts/vendor-cliproxyapi.sh 7.0.0
  scripts/vendor-cliproxyapi.sh --local /path/to/cliproxyapi --source-label local-test
EOF
}

json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

parse_version_line() {
  local binary="$1"
  local output
  output="$({ "$binary" --version || true; } 2>&1)"
  awk '/CLIProxyAPI Version:/ { print; exit }' <<<"$output"
}

metadata_field() {
  local line="$1"
  local field="$2"
  python3 - "$line" "$field" <<'PY'
import re
import sys
line = sys.argv[1]
field = sys.argv[2]
patterns = {
    "version": r"CLIProxyAPI Version: ([^,]+)",
    "commit": r"Commit: ([^,]+)",
    "builtAt": r"BuiltAt: (\S+)",
}
match = re.search(patterns[field], line)
print(match.group(1) if match else "")
PY
}

write_manifest() {
  local version="$1"
  local commit="$2"
  local built_at="$3"
  local source="$4"
  local asset="$5"
  local asset_sha="$6"
  local archive_path="$7"
  local binary_sha="$8"
  local size_bytes="$9"
  local escaped_source
  escaped_source="$(printf '%s' "$source" | json_escape)"
  cat > "$MANIFEST" <<EOF
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
  "vendoredFromArchivePath": "$archive_path"
}
EOF
}

vendor_binary() {
  local source_binary="$1"
  local source_label="$2"
  local asset_name="$3"
  local asset_sha="$4"
  local archive_path="$5"

  mkdir -p "$DEST_DIR"
  cp "$source_binary" "$DEST"
  chmod +x "$DEST"

  local version_line version commit built_at binary_sha size_bytes
  version_line="$(parse_version_line "$DEST")"
  version="$(metadata_field "$version_line" version)"
  commit="$(metadata_field "$version_line" commit)"
  built_at="$(metadata_field "$version_line" builtAt)"
  binary_sha="$(sha256_file "$DEST")"
  size_bytes="$(wc -c < "$DEST" | tr -d ' ' )"

  if [[ -z "$version" || -z "$commit" || -z "$built_at" ]]; then
    echo "Unable to parse CLIProxyAPI version metadata from: $version_line" >&2
    exit 1
  fi

  write_manifest "$version" "$commit" "$built_at" "$source_label" "$asset_name" "$asset_sha" "$archive_path" "$binary_sha" "$size_bytes"
  echo "Vendored CLIProxyAPI $version to $DEST"
  echo "Wrote manifest to $MANIFEST"
}

vendor_release() {
  local version="$1"
  local tag="v$version"
  local asset="CLIProxyAPI_${version}_darwin_aarch64.tar.gz"
  local tmpdir
  tmpdir="$(mktemp -d "/tmp/cliproxyapi-${version}.XXXXXX")"
  trap "rm -rf $(printf '%q' \"$tmpdir\")" EXIT

  gh release download "$tag" --repo "$UPSTREAM_REPOSITORY" --dir "$tmpdir" --pattern "$asset" --pattern checksums.txt
  (cd "$tmpdir" && shasum -a 256 -c --ignore-missing checksums.txt && tar -xzf "$asset")

  local asset_sha
  asset_sha="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$tmpdir/checksums.txt")"
  if [[ -z "$asset_sha" ]]; then
    echo "Missing checksum entry for $asset" >&2
    exit 1
  fi

  vendor_binary "$tmpdir/cli-proxy-api" "https://github.com/$UPSTREAM_REPOSITORY/releases/download/$tag/$asset" "$asset" "$asset_sha" "cli-proxy-api"
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--local" ]]; then
  source_binary="${2:-}"
  if [[ -z "$source_binary" ]]; then
    echo "Error: --local requires a binary path argument." >&2
    usage >&2
    exit 1
  fi
  source_label="$source_binary"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-label)
        source_label="${2:-}"
        shift 2
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
  if [[ ! -f "$source_binary" ]]; then
    echo "cliproxyapi binary not found at: $source_binary" >&2
    exit 1
  fi
  vendor_binary "$source_binary" "$source_label" "" "" ""
  exit 0
fi

vendor_release "$1"
