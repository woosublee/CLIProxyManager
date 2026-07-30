#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/generate-sparkle-appcast.sh"

if grep -Eq '(^|[^[:alnum:]_])(python|python3)([^[:alnum:]_]|$)' "$SCRIPT"; then
  echo "FAIL: generate-sparkle-appcast.sh must not require Python" >&2
  exit 1
fi

if grep -q 'stat -f%z' "$SCRIPT"; then
  echo "FAIL: generate-sparkle-appcast.sh must use wc -c instead of BSD-only stat -f%z" >&2
  exit 1
fi

if grep -q -- '-perm +111' "$SCRIPT"; then
  echo "FAIL: generate-sparkle-appcast.sh must not use GNU-only find -perm +111" >&2
  exit 1
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sandbox="$(mktemp -d /tmp/generate-sparkle-appcast-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

mkdir -p "$sandbox/repo/scripts" "$sandbox/repo/release" "$sandbox/repo/build"
cp "$REPO_ROOT/scripts/generate-sparkle-appcast.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/resolve-release-version.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/release-version-lib.sh" "$sandbox/repo/scripts/"
cp "$REPO_ROOT/scripts/verify-release-artifacts.sh" "$sandbox/repo/scripts/"
chmod +x "$sandbox/repo/scripts/"*.sh
cat > "$sandbox/repo/release/version.json" <<'JSON'
{"version":"0.2.0","build":7}
JSON
printf 'fake dmg contents' > "$sandbox/repo/build/CLIProxyManager-0.2.0.dmg"

fake_sign_update="$sandbox/sign_update"
cat > "$fake_sign_update" <<'FAKE'
#!/usr/bin/env bash
private_key="$(cat)"
case "$private_key" in
  test-private-key|keychain-private-key) ;;
  *)
    echo "unexpected private key" >&2
    exit 2
    ;;
esac
[[ "${1:-}" == *"CLIProxyManager-0.2.0.dmg" ]] || {
  echo "unexpected dmg path" >&2
  exit 3
}
[[ "${2:-}" == "--ed-key-file" ]] || {
  echo "missing --ed-key-file" >&2
  exit 4
}
[[ "${3:-}" == "-" ]] || {
  echo "missing stdin key file marker" >&2
  exit 5
}
echo 'sparkle:edSignature="fake-ed-signature" length="123"'
FAKE
chmod +x "$fake_sign_update"

SPARKLE_PRIVATE_KEY='test-private-key' \
SPARKLE_SIGN_UPDATE="$fake_sign_update" \
REPOSITORY='woosublee/CLIProxyManager' \
APPCAST_PATH="$sandbox/repo/build/appcast.xml" \
"$sandbox/repo/scripts/generate-sparkle-appcast.sh"

[[ -f "$sandbox/repo/build/appcast.xml" ]] || fail "appcast.xml should be generated"
grep -q '<sparkle:version>7</sparkle:version>' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical build"
grep -q '<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical version"
grep -q 'releases/download/v0.2.0/CLIProxyManager-0.2.0.dmg' "$sandbox/repo/build/appcast.xml" || fail "appcast should include canonical release URL"
grep -q 'sparkle:edSignature="fake-ed-signature"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include EdDSA signature"
grep -q 'length="17"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include the exact DMG byte length"
grep -q 'type="application/octet-stream"' "$sandbox/repo/build/appcast.xml" || fail "appcast should include enclosure MIME type"

for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  if env "$legacy_name=unexpected" \
    SPARKLE_PRIVATE_KEY='test-private-key' \
    SPARKLE_SIGN_UPDATE="$fake_sign_update" \
    APPCAST_PATH="$sandbox/repo/build/rejected.xml" \
    "$sandbox/repo/scripts/generate-sparkle-appcast.sh" \
    >"$sandbox/$legacy_name.out" 2>"$sandbox/$legacy_name.err"; then
    fail "$legacy_name override should fail"
  fi
  grep -F "$legacy_name is derived from release/version.json" "$sandbox/$legacy_name.err" >/dev/null || fail "$legacy_name rejection should explain canonical source"
done

for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  if env "$legacy_name=" \
    SPARKLE_PRIVATE_KEY='test-private-key' \
    SPARKLE_SIGN_UPDATE="$fake_sign_update" \
    APPCAST_PATH="$sandbox/repo/build/rejected-empty.xml" \
    "$sandbox/repo/scripts/generate-sparkle-appcast.sh" \
    >"$sandbox/$legacy_name-empty.out" 2>"$sandbox/$legacy_name-empty.err"; then
    fail "empty $legacy_name override should fail"
  fi
  grep -F "$legacy_name is derived from release/version.json" "$sandbox/$legacy_name-empty.err" >/dev/null || fail "empty $legacy_name rejection should explain canonical source"
done

if ARTIFACT_CHANNEL=development \
  DEVELOPMENT_VERSION='0.2.0' \
  DEVELOPMENT_BUILD_NUMBER=7 \
  SPARKLE_PRIVATE_KEY='test-private-key' \
  SPARKLE_SIGN_UPDATE="$fake_sign_update" \
  APPCAST_PATH="$sandbox/repo/build/development.xml" \
  "$sandbox/repo/scripts/generate-sparkle-appcast.sh" \
  >"$sandbox/development.out" 2>"$sandbox/development.err"; then
  fail "development appcast generation should fail"
fi
grep -F 'Sparkle appcasts can only be generated for official artifacts' "$sandbox/development.err" >/dev/null || fail "development rejection should explain official-only policy"

printf '<rss><channel><title>existing</title></channel></rss>\n' > "$sandbox/repo/build/appcast.xml"
existing_checksum="$(shasum -a 256 "$sandbox/repo/build/appcast.xml" | cut -d' ' -f1)"
failing_signer="$sandbox/failing-sign-update"
cat > "$failing_signer" <<'SH'
#!/usr/bin/env bash
exit 42
SH
chmod +x "$failing_signer"

if SPARKLE_PRIVATE_KEY='test-private-key' \
  SPARKLE_SIGN_UPDATE="$failing_signer" \
  APPCAST_PATH="$sandbox/repo/build/appcast.xml" \
  "$sandbox/repo/scripts/generate-sparkle-appcast.sh"; then
  fail "signing failure should abort appcast generation"
fi

preserved_checksum="$(shasum -a 256 "$sandbox/repo/build/appcast.xml" | cut -d' ' -f1)"
[[ "$existing_checksum" == "$preserved_checksum" ]] || fail "failed generation must preserve the previous appcast"

fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/security" <<'FAKE_SECURITY'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "find-generic-password" ]] || exit 10
service=""
account=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s)
      service="$2"
      shift 2
      ;;
    -a)
      account="$2"
      shift 2
      ;;
    -w)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ "$service" == "https://sparkle-project.org" ]] || exit 11
[[ "$account" == "com.woosublee.CLIProxyManager.sparkle.ed25519" ]] || exit 12
printf 'keychain-private-key'
FAKE_SECURITY
chmod +x "$fake_bin/security"

PATH="$fake_bin:$PATH" \
SPARKLE_SIGN_UPDATE="$fake_sign_update" \
REPOSITORY='woosublee/CLIProxyManager' \
APPCAST_PATH="$sandbox/repo/build/keychain-appcast.xml" \
"$sandbox/repo/scripts/generate-sparkle-appcast.sh"

[[ -f "$sandbox/repo/build/keychain-appcast.xml" ]] || fail "keychain fallback should generate appcast.xml"
grep -q 'sparkle:edSignature="fake-ed-signature"' "$sandbox/repo/build/keychain-appcast.xml" || fail "keychain fallback appcast should include ed signature"

printf 'PASS: generate-sparkle-appcast tests\n'
