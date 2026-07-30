#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

REPOSITORY="${REPOSITORY:-woosublee/CLIProxyManager}"
APP_NAME="${APP_NAME:-CLIProxyManager}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
SPARKLE_KEYCHAIN_SERVICE="${SPARKLE_KEYCHAIN_SERVICE:-https://sparkle-project.org}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-com.woosublee.CLIProxyManager.sparkle.ed25519}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH APPCAST_PATH; do
  if [[ -n "${!legacy_name+x}" ]]; then
    fail "$legacy_name is derived from release/version.json; remove the override"
  fi
done

[[ "${ARTIFACT_CHANNEL:-official}" == 'official' ]] || fail 'Sparkle appcasts can only be generated for official artifacts'
eval "$("$SCRIPT_DIR/resolve-release-version.sh" shell)"
APP_VERSION="$RELEASE_VERSION"
APP_BUILD="$RELEASE_BUILD"
APP_TAG="$RELEASE_TAG"
CANONICAL_DMG_PATH="$REPO_ROOT/$RELEASE_DMG_PATH"
CANONICAL_APPCAST_PATH="$REPO_ROOT/$RELEASE_APPCAST_PATH"

[[ -f "$CANONICAL_DMG_PATH" ]] || fail 'Canonical DMG is missing'

sparkle_private_key() {
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY"
    return
  fi

  security find-generic-password \
    -s "$SPARKLE_KEYCHAIN_SERVICE" \
    -a "$SPARKLE_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null || fail 'SPARKLE_PRIVATE_KEY is required or Keychain credentials are unavailable'
}

find_sign_update() {
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    [[ -x "$SPARKLE_SIGN_UPDATE" ]] || fail 'SPARKLE_SIGN_UPDATE is not executable'
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

  if ! find "$tools_dir" -type f -name sign_update -exec test -x {} \; -print -quit 2>/dev/null | grep -q .; then
    tar -xJf "$archive" -C "$tools_dir"
  fi

  local sign_update
  sign_update="$(find "$tools_dir" -type f -name sign_update -exec test -x {} \; -print -quit)"
  [[ -n "$sign_update" ]] || fail 'sign_update could not be located'
  printf '%s\n' "$sign_update"
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g" \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

SIGN_UPDATE="$(find_sign_update)"
if ! signature_output="$(sparkle_private_key | "$SIGN_UPDATE" "$CANONICAL_DMG_PATH" --ed-key-file - 2>/dev/null)"; then
  fail 'Sparkle signing failed'
fi
ed_signature="$(printf '%s\n' "$signature_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | sed -n '1p')"
[[ -n "$ed_signature" ]] || fail 'Unable to parse sparkle:edSignature from sign_update output'

length="$(wc -c < "$CANONICAL_DMG_PATH" | tr -d '[:space:]')"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
dmg_name="$(basename "$CANONICAL_DMG_PATH")"
dmg_url="https://github.com/${REPOSITORY}/releases/download/${APP_TAG}/${dmg_name}"
appcast_dir="$(dirname "$CANONICAL_APPCAST_PATH")"
mkdir -p "$appcast_dir"
staged_appcast="$(mktemp "$appcast_dir/.appcast.xml.XXXXXX")"
cleanup() { rm -f "$staged_appcast"; }
trap cleanup EXIT

escaped_app_name="$(printf '%s' "$APP_NAME" | xml_escape)"
escaped_version="$(printf '%s' "$APP_VERSION" | xml_escape)"
escaped_build="$(printf '%s' "$APP_BUILD" | xml_escape)"
escaped_dmg_url="$(printf '%s' "$dmg_url" | xml_escape)"
escaped_signature="$(printf '%s' "$ed_signature" | xml_escape)"

cat > "$staged_appcast" <<EOF
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

"$SCRIPT_DIR/verify-release-artifacts.sh" --appcast "$staged_appcast" --official
release_atomic_replace "$staged_appcast" "$CANONICAL_APPCAST_PATH"
trap - EXIT
