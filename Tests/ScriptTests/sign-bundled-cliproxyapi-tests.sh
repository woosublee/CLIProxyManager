#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/sign-bundled-cliproxyapi.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "sign-bundled-cliproxyapi.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/sign-bundled-cliproxyapi-tests.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"

# The fake codesign records its arguments and appends a signature blob, so the
# signed binary's checksum and size differ from the upstream binary.
cat > "$fake_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SIGN_TEST_LOG"
[[ "${SIGN_TEST_CODESIGN:-pass}" == 'pass' ]] || exit 7
for target; do :; done
printf 'fake-signature' >> "$target"
SH
chmod +x "$fake_bin/codesign"

create_resources() {
  local dir="$1"
  local binary="$dir/cliproxyapi"
  local binary_sha binary_size

  mkdir -p "$dir"
  printf '#!/bin/sh\nexit 0\n' > "$binary"
  chmod 755 "$binary"
  binary_sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
  binary_size="$(wc -c < "$binary" | tr -d '[:space:]')"
  cat > "$dir/cliproxyapi.manifest.json" <<EOF
{
  "name": "cliproxyapi",
  "version": "7.2.130",
  "commit": "fixturecommit",
  "builtAt": "2026-08-12T10:31:20Z",
  "source": "https://github.com/router-for-me/CLIProxyAPI/releases/download/v7.2.130/CLIProxyAPI_7.2.130_darwin_aarch64.tar.gz",
  "upstreamRepository": "router-for-me/CLIProxyAPI",
  "upstreamTag": "v7.2.130",
  "upstreamAsset": "CLIProxyAPI_7.2.130_darwin_aarch64.tar.gz",
  "upstreamAssetSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "vendoredBinaryName": "cliproxyapi",
  "vendoredBinarySha256": "$binary_sha",
  "vendoredBinarySizeBytes": $binary_size,
  "vendoredFromArchivePath": "cli-proxy-api",
  "target": {
    "operatingSystem": "darwin",
    "architecture": "arm64"
  }
}
EOF
}

run_signer() {
  local log="$1"
  shift
  SIGN_TEST_LOG="$log" CODESIGN="$fake_bin/codesign" "$SOURCE_SCRIPT" "$@"
}

manifest_value() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# Signing rewrites the bundled manifest to describe the signed binary.
resources="$sandbox/normal"
create_resources "$resources"
log="$sandbox/normal.log"
run_signer "$log" --identity 'Developer ID Application: Example (TEAMID)' --timestamp --timestamp --resource-dir "$resources" >/dev/null
grep -Fx -- "--force --options runtime --timestamp --sign Developer ID Application: Example (TEAMID) $resources/cliproxyapi" "$log" >/dev/null ||
  fail "codesign should sign with hardened runtime, the timestamp flag, and the identity"
expected_sha="$(shasum -a 256 "$resources/cliproxyapi" | awk '{print $1}')"
expected_size="$(wc -c < "$resources/cliproxyapi" | tr -d '[:space:]')"
[[ "$(manifest_value "$resources/cliproxyapi.manifest.json" vendoredBinarySha256)" == "$expected_sha" ]] ||
  fail "manifest checksum should match the signed binary"
[[ "$(manifest_value "$resources/cliproxyapi.manifest.json" vendoredBinarySizeBytes)" == "$expected_size" ]] ||
  fail "manifest size should match the signed binary"
[[ "$(manifest_value "$resources/cliproxyapi.manifest.json" upstreamAssetSha256)" == "$(printf 'a%.0s' {1..64})" ]] ||
  fail "upstream archive checksum should be preserved"
[[ ! -e "$resources/cliproxyapi.manifest.json.tmp" ]] || fail "temporary manifest should not remain"

# Local builds pass --timestamp=none through to codesign.
resources="$sandbox/local"
create_resources "$resources"
log="$sandbox/local.log"
run_signer "$log" --identity '-' --timestamp --timestamp=none --resource-dir "$resources" >/dev/null
grep -F -- '--timestamp=none' "$log" >/dev/null || fail "local signing should skip the timestamp server"

# A binary that no longer matches the manifest is rejected before signing.
resources="$sandbox/mismatch"
create_resources "$resources"
printf 'tampered' >> "$resources/cliproxyapi"
log="$sandbox/mismatch.log"
if run_signer "$log" --identity '-' --timestamp --timestamp --resource-dir "$resources" 2>/dev/null; then
  fail "a binary that does not match the manifest must be rejected"
fi
[[ ! -e "$log" ]] || fail "mismatched binaries must not be signed"

# A codesign failure leaves the manifest untouched.
resources="$sandbox/codesign-failure"
create_resources "$resources"
cp "$resources/cliproxyapi.manifest.json" "$sandbox/original-manifest.json"
if SIGN_TEST_CODESIGN=fail run_signer "$sandbox/failure.log" --identity '-' --timestamp --timestamp --resource-dir "$resources" 2>/dev/null; then
  fail "codesign failures must fail the script"
fi
cmp -s "$resources/cliproxyapi.manifest.json" "$sandbox/original-manifest.json" ||
  fail "codesign failures must not rewrite the manifest"

# Unknown timestamp flags are rejected.
resources="$sandbox/bad-flag"
create_resources "$resources"
if run_signer "$sandbox/bad-flag.log" --identity '-' --timestamp --deep --resource-dir "$resources" 2>/dev/null; then
  fail "unexpected timestamp flags must be rejected"
fi

printf 'sign-bundled-cliproxyapi tests passed\n'
