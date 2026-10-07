#!/usr/bin/env bash
# Signs the vendored CLIProxyAPI binary inside an app bundle and records the
# signed binary's checksum and size in the bundled manifest.
#
# Notarization requires every Mach-O in the bundle to carry a Developer ID
# signature, so the upstream binary cannot ship as-is. Signing changes its
# bytes; the bundled manifest is the app's source of truth for validating the
# bundled binary, so it must describe the signed copy. The repository manifest
# keeps the upstream checksum used to verify the downloaded artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cliproxyapi-artifact-lib.sh
source "$SCRIPT_DIR/cliproxyapi-artifact-lib.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage='Usage: scripts/sign-bundled-cliproxyapi.sh --identity IDENTITY --timestamp FLAG --resource-dir DIR'
identity=''
timestamp_flag=''
resource_dir=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity|--timestamp|--resource-dir)
      [[ $# -ge 2 && -n "$2" ]] || fail "$usage"
      case "$1" in
        --identity) identity="$2" ;;
        --timestamp) timestamp_flag="$2" ;;
        --resource-dir) resource_dir="$2" ;;
      esac
      shift 2
      ;;
    *)
      fail "$usage"
      ;;
  esac
done

[[ -n "$identity" && -n "$timestamp_flag" && -n "$resource_dir" ]] || fail "$usage"
[[ "$timestamp_flag" == '--timestamp' || "$timestamp_flag" == '--timestamp=none' ]] ||
  fail 'The timestamp flag must be --timestamp or --timestamp=none'

binary="$resource_dir/cliproxyapi"
manifest="$resource_dir/cliproxyapi.manifest.json"
[[ -f "$binary" && -x "$binary" ]] || fail "Missing bundled CLIProxyAPI binary: $binary"
[[ -f "$manifest" ]] || fail "Missing bundled CLIProxyAPI manifest: $manifest"

cliproxyapi_load_manifest "$manifest" && cliproxyapi_manifest_is_valid ||
  fail 'Bundled CLIProxyAPI manifest is invalid'
[[ "$(cliproxyapi_sha256_file "$binary")" == "$CLIPROXYAPI_MANIFEST_BINARY_SHA256" ]] ||
  fail 'Bundled CLIProxyAPI binary does not match the manifest before signing'

"${CODESIGN:-/usr/bin/codesign}" --force --options runtime "$timestamp_flag" --sign "$identity" "$binary" ||
  fail 'Bundled CLIProxyAPI codesign failed'

signed_sha256="$(cliproxyapi_sha256_file "$binary")"
signed_size="$(wc -c < "$binary" | tr -d '[:space:]')"

"${CLIPROXYAPI_PYTHON:-python3}" -I - "$manifest" "$signed_sha256" "$signed_size" <<'PY'
import json
import os
import sys

path, sha256, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["vendoredBinarySha256"] = sha256
manifest["vendoredBinarySizeBytes"] = size
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY

printf 'Signed bundled CLIProxyAPI binary (%s bytes)\n' "$signed_size"
