#!/usr/bin/env bash

cliproxyapi_sha256_file() {
  "${CLIPROXYAPI_SHASUM:-/usr/bin/shasum}" -a 256 "$1" | awk '{print $1}'
}

cliproxyapi_is_sha256() {
  [[ ${#1} -eq 64 && "$1" =~ ^[0-9A-Fa-f]+$ ]]
}

cliproxyapi_parse_version_line() {
  local binary="$1"
  local output
  output="$({ "$binary" --version || true; } 2>&1)"
  awk '/CLIProxyAPI Version:/ { print; exit }' <<<"$output"
}

cliproxyapi_load_version_metadata() {
  local line="$1"
  local values=()
  local value

  while IFS= read -r -d '' value; do
    values+=("$value")
  done < <("${CLIPROXYAPI_PYTHON:-python3}" - "$line" <<'PY'
import re
import sys

match = re.search(
    r"CLIProxyAPI Version: ([^,]+),\s*Commit: ([^,]+),\s*BuiltAt: (\S+)",
    sys.argv[1],
)
if match:
    for value in match.groups():
        sys.stdout.write(value)
        sys.stdout.write("\0")
PY
)

  [[ ${#values[@]} -eq 3 ]] || return 1
  CLIPROXYAPI_BINARY_VERSION="${values[0]}"
  CLIPROXYAPI_BINARY_COMMIT="${values[1]}"
  CLIPROXYAPI_BINARY_BUILT_AT="${values[2]}"
}

cliproxyapi_is_arm64_binary() {
  local binary="$1"
  local architectures
  architectures="$("${CLIPROXYAPI_LIPO:-/usr/bin/lipo}" -archs "$binary" 2>/dev/null)" || return 1
  [[ "$architectures" == 'arm64' ]]
}

cliproxyapi_checksum_for_file() {
  local checksums_file="$1"
  local filename="$2"

  awk -v filename="$filename" '
    $1 ~ /^[0-9A-Fa-f]{64}$/ && ($2 == filename || $2 == "*" filename) {
      print $1
      exit
    }
  ' "$checksums_file"
}

cliproxyapi_load_manifest() {
  local manifest="$1"
  local values=()
  local value

  [[ -f "$manifest" ]] || return 1
  while IFS= read -r -d '' value; do
    values+=("$value")
  done < <("${CLIPROXYAPI_PYTHON:-python3}" - "$manifest" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as manifest_file:
        manifest = json.load(manifest_file)
    target = manifest["target"]
    values = [
        manifest["name"],
        manifest["version"],
        manifest["commit"],
        manifest["builtAt"],
        manifest["source"],
        manifest["upstreamRepository"],
        manifest["upstreamTag"],
        manifest["upstreamAsset"],
        manifest["upstreamAssetSha256"],
        manifest["vendoredBinaryName"],
        manifest["vendoredBinarySha256"],
        manifest["vendoredBinarySizeBytes"],
        manifest["vendoredFromArchivePath"],
        target["operatingSystem"],
        target["architecture"],
    ]
    if any(not isinstance(value, str) for value in values[:11] + values[12:]):
        raise ValueError("manifest strings")
    if not isinstance(values[11], int):
        raise ValueError("manifest size")
except (KeyError, TypeError, ValueError, json.JSONDecodeError, OSError):
    sys.exit(1)

for value in values:
    sys.stdout.write(str(value))
    sys.stdout.write("\0")
PY
)

  [[ ${#values[@]} -eq 15 ]] || return 1
  CLIPROXYAPI_MANIFEST_NAME="${values[0]}"
  CLIPROXYAPI_MANIFEST_VERSION="${values[1]}"
  CLIPROXYAPI_MANIFEST_COMMIT="${values[2]}"
  CLIPROXYAPI_MANIFEST_BUILT_AT="${values[3]}"
  CLIPROXYAPI_MANIFEST_SOURCE="${values[4]}"
  CLIPROXYAPI_MANIFEST_REPOSITORY="${values[5]}"
  CLIPROXYAPI_MANIFEST_TAG="${values[6]}"
  CLIPROXYAPI_MANIFEST_ASSET="${values[7]}"
  CLIPROXYAPI_MANIFEST_ARCHIVE_SHA256="${values[8]}"
  CLIPROXYAPI_MANIFEST_BINARY_NAME="${values[9]}"
  CLIPROXYAPI_MANIFEST_BINARY_SHA256="${values[10]}"
  CLIPROXYAPI_MANIFEST_BINARY_SIZE="${values[11]}"
  CLIPROXYAPI_MANIFEST_ARCHIVE_PATH="${values[12]}"
  CLIPROXYAPI_MANIFEST_OPERATING_SYSTEM="${values[13]}"
  CLIPROXYAPI_MANIFEST_ARCHITECTURE="${values[14]}"
}

cliproxyapi_manifest_is_valid() {
  [[ "$CLIPROXYAPI_MANIFEST_NAME" == 'cliproxyapi' &&
     "$CLIPROXYAPI_MANIFEST_BINARY_NAME" == 'cliproxyapi' &&
     "$CLIPROXYAPI_MANIFEST_REPOSITORY" == 'router-for-me/CLIProxyAPI' &&
     "$CLIPROXYAPI_MANIFEST_OPERATING_SYSTEM" == 'darwin' &&
     "$CLIPROXYAPI_MANIFEST_ARCHITECTURE" == 'arm64' ]] || return 1

  [[ "$CLIPROXYAPI_MANIFEST_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ &&
     -n "$CLIPROXYAPI_MANIFEST_COMMIT" &&
     -n "$CLIPROXYAPI_MANIFEST_BUILT_AT" &&
     "$CLIPROXYAPI_MANIFEST_TAG" == "v$CLIPROXYAPI_MANIFEST_VERSION" &&
     "$CLIPROXYAPI_MANIFEST_ASSET" == "CLIProxyAPI_${CLIPROXYAPI_MANIFEST_VERSION}_darwin_aarch64.tar.gz" &&
     "$CLIPROXYAPI_MANIFEST_SOURCE" == "https://github.com/$CLIPROXYAPI_MANIFEST_REPOSITORY/releases/download/$CLIPROXYAPI_MANIFEST_TAG/$CLIPROXYAPI_MANIFEST_ASSET" &&
     "$CLIPROXYAPI_MANIFEST_ARCHIVE_PATH" == 'cli-proxy-api' ]] || return 1

  cliproxyapi_is_sha256 "$CLIPROXYAPI_MANIFEST_ARCHIVE_SHA256" &&
    cliproxyapi_is_sha256 "$CLIPROXYAPI_MANIFEST_BINARY_SHA256" &&
    [[ "$CLIPROXYAPI_MANIFEST_BINARY_SIZE" =~ ^[1-9][0-9]*$ ]]
}

cliproxyapi_binary_matches_manifest() {
  local binary="$1"
  local version_line size

  [[ -f "$binary" && -x "$binary" ]] || return 1
  [[ "$(cliproxyapi_sha256_file "$binary")" == "$CLIPROXYAPI_MANIFEST_BINARY_SHA256" ]] || return 1
  size="$(wc -c < "$binary" | tr -d '[:space:]')"
  [[ "$size" == "$CLIPROXYAPI_MANIFEST_BINARY_SIZE" ]] || return 1
  cliproxyapi_is_arm64_binary "$binary" || return 1

  version_line="$(cliproxyapi_parse_version_line "$binary")"
  cliproxyapi_load_version_metadata "$version_line" || return 1
  [[ "$CLIPROXYAPI_BINARY_VERSION" == "$CLIPROXYAPI_MANIFEST_VERSION" &&
     "$CLIPROXYAPI_BINARY_COMMIT" == "$CLIPROXYAPI_MANIFEST_COMMIT" &&
     "$CLIPROXYAPI_BINARY_BUILT_AT" == "$CLIPROXYAPI_MANIFEST_BUILT_AT" ]]
}
