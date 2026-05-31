#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail "Usage: scripts/release-local.sh v1.2.3"
fi

RELEASE_TAG="$1"
[[ "$RELEASE_TAG" == v* ]] || fail "RELEASE_TAG must start with v: $RELEASE_TAG"

VERSION="${RELEASE_TAG#v}"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw Info.plist)"
APPCAST_PATH="build/appcast.xml"
DMG_PATH="build/CLIProxyManager-${VERSION}.dmg"

export RELEASE_TAG
export VERSION
export BUILD_NUMBER
export APPCAST_PATH
export DMG_PATH

make CODESIGN_IDENTITY=- VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" verify-dmg
scripts/generate-sparkle-appcast.sh

gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
  gh release create "$RELEASE_TAG" --verify-tag --title "CLIProxyManager $VERSION" --notes "Ad-hoc signed, non-notarized DMG with Sparkle appcast."
gh release upload "$RELEASE_TAG" "$DMG_PATH" "$APPCAST_PATH" --clobber
