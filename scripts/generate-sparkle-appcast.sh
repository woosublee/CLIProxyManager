#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPOSITORY="${REPOSITORY:-woosublee/CLIProxyManager}"
APP_NAME="${APP_NAME:-CLIProxyManager}"
APPCAST_PATH="${APPCAST_PATH:-build/appcast.xml}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
SPARKLE_KEYCHAIN_SERVICE="${SPARKLE_KEYCHAIN_SERVICE:-https://sparkle-project.org}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-com.woosublee.CLIProxyManager.sparkle.ed25519}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

sparkle_private_key() {
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY"
    return
  fi

  security find-generic-password \
    -s "$SPARKLE_KEYCHAIN_SERVICE" \
    -a "$SPARKLE_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null || fail "SPARKLE_PRIVATE_KEY is required or Keychain item is missing: service=$SPARKLE_KEYCHAIN_SERVICE account=$SPARKLE_KEYCHAIN_ACCOUNT"
}

require_env RELEASE_TAG
require_env VERSION
require_env BUILD_NUMBER
require_env DMG_PATH

[[ -f "$DMG_PATH" ]] || fail "DMG_PATH does not exist: $DMG_PATH"

find_sign_update() {
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    [[ -x "$SPARKLE_SIGN_UPDATE" ]] || fail "SPARKLE_SIGN_UPDATE is not executable: $SPARKLE_SIGN_UPDATE"
    printf '%s\n' "$SPARKLE_SIGN_UPDATE"
    return
  fi

  local tools_dir="$REPO_ROOT/build/sparkle-tools"
  local archive="$tools_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
  mkdir -p "$tools_dir"

  if [[ ! -f "$archive" ]]; then
    curl -fsSL \
      "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
      -o "$archive"
  fi

  if ! find "$tools_dir" -type f -name sign_update -perm +111 -print -quit 2>/dev/null | grep -q .; then
    tar -xJf "$archive" -C "$tools_dir"
  fi

  local sign_update
  sign_update="$(find "$tools_dir" -type f -name sign_update -perm +111 -print -quit)"
  [[ -n "$sign_update" ]] || fail "sign_update not found under $tools_dir"
  printf '%s\n' "$sign_update"
}

xml_escape() {
  python3 -c 'import html, sys; print(html.escape(sys.stdin.read(), quote=True), end="")'
}

SIGN_UPDATE="$(find_sign_update)"
signature_output="$(sparkle_private_key | "$SIGN_UPDATE" "$DMG_PATH" --ed-key-file -)"
ed_signature="$(python3 -c 'import re, sys; m = re.search(r"sparkle:edSignature=\"([^\"]+)\"", sys.stdin.read()); print(m.group(1) if m else "")' <<<"$signature_output")"
[[ -n "$ed_signature" ]] || fail "Unable to parse sparkle:edSignature from sign_update output"

length="$(stat -f%z "$DMG_PATH")"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
dmg_name="$(basename "$DMG_PATH")"
dmg_url="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${dmg_name}"
appcast_dir="$(dirname "$APPCAST_PATH")"
mkdir -p "$appcast_dir"

escaped_app_name="$(printf '%s' "$APP_NAME" | xml_escape)"
escaped_version="$(printf '%s' "$VERSION" | xml_escape)"
escaped_build="$(printf '%s' "$BUILD_NUMBER" | xml_escape)"
escaped_dmg_url="$(printf '%s' "$dmg_url" | xml_escape)"
escaped_signature="$(printf '%s' "$ed_signature" | xml_escape)"

cat > "$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${escaped_app_name} Appcast</title>
    <link>https://github.com/${REPOSITORY}</link>
    <description>${escaped_app_name} updates</description>
    <language>en</language>
    <item>
      <title>${escaped_app_name} ${escaped_version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${escaped_build}</sparkle:version>
      <sparkle:shortVersionString>${escaped_version}</sparkle:shortVersionString>
      <enclosure url="${escaped_dmg_url}"
                 sparkle:version="${escaped_build}"
                 sparkle:shortVersionString="${escaped_version}"
                 sparkle:edSignature="${escaped_signature}"
                 length="${length}"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
