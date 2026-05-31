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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sandbox="$(mktemp -d /tmp/generate-sparkle-appcast-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

fake_sign_update="$sandbox/sign_update"
cat > "$fake_sign_update" <<'FAKE'
#!/usr/bin/env bash
private_key="$(cat)"
case "$private_key" in
  test-private-key|keychain-private-key) ;;
  *)
    echo "unexpected private key: $private_key" >&2
    exit 2
    ;;
esac
[[ "${1:-}" == *"CLIProxyManager-0.2.0.dmg" ]] || {
  echo "unexpected dmg path: ${1:-}" >&2
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

dmg_path="$sandbox/CLIProxyManager-0.2.0.dmg"
printf 'fake dmg contents' > "$dmg_path"
appcast_path="$sandbox/appcast.xml"

SPARKLE_PRIVATE_KEY="test-private-key" \
SPARKLE_SIGN_UPDATE="$fake_sign_update" \
REPOSITORY="woosublee/CLIProxyManager" \
RELEASE_TAG="v0.2.0" \
VERSION="0.2.0" \
BUILD_NUMBER="7" \
DMG_PATH="$dmg_path" \
APPCAST_PATH="$appcast_path" \
"$SCRIPT"

[[ -f "$appcast_path" ]] || fail "appcast.xml should be generated"
grep -q '<sparkle:version>7</sparkle:version>' "$appcast_path" || fail "appcast should include build number"
grep -q '<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>' "$appcast_path" || fail "appcast should include short version"
grep -q 'https://github.com/woosublee/CLIProxyManager/releases/download/v0.2.0/CLIProxyManager-0.2.0.dmg' "$appcast_path" || fail "appcast should include GitHub release DMG URL"
grep -q 'sparkle:edSignature="fake-ed-signature"' "$appcast_path" || fail "appcast should include ed signature"
grep -q 'type="application/octet-stream"' "$appcast_path" || fail "appcast should include octet-stream enclosure type"

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

keychain_appcast_path="$sandbox/keychain-appcast.xml"
PATH="$fake_bin:$PATH" \
SPARKLE_SIGN_UPDATE="$fake_sign_update" \
REPOSITORY="woosublee/CLIProxyManager" \
RELEASE_TAG="v0.2.0" \
VERSION="0.2.0" \
BUILD_NUMBER="7" \
DMG_PATH="$dmg_path" \
APPCAST_PATH="$keychain_appcast_path" \
"$SCRIPT"

[[ -f "$keychain_appcast_path" ]] || fail "keychain fallback should generate appcast.xml"
grep -q 'sparkle:edSignature="fake-ed-signature"' "$keychain_appcast_path" || fail "keychain fallback appcast should include ed signature"
