#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

command_name="${1:-}"
[[ $# -eq 1 ]] || release_fail 'Usage: scripts/resolve-release-version.sh {validate|version|build|tag|dmg-name|dmg-path|appcast-path|channel|shell|json}'
release_load_identity "$REPO_ROOT"

case "$command_name" in
  validate) ;;
  version) printf '%s\n' "$RELEASE_VERSION" ;;
  build) printf '%s\n' "$RELEASE_BUILD" ;;
  tag)
    [[ "$RELEASE_CHANNEL" == 'official' ]] || release_fail 'development artifacts do not have a release tag'
    printf '%s\n' "$RELEASE_TAG"
    ;;
  dmg-name) printf '%s\n' "$RELEASE_DMG_NAME" ;;
  dmg-path) printf '%s\n' "$RELEASE_DMG_PATH" ;;
  appcast-path) printf '%s\n' "$RELEASE_APPCAST_PATH" ;;
  channel) printf '%s\n' "$RELEASE_CHANNEL" ;;
  shell)
    printf "RELEASE_CHANNEL='%s'\n" "$RELEASE_CHANNEL"
    printf "RELEASE_VERSION='%s'\n" "$RELEASE_VERSION"
    printf "RELEASE_BUILD='%s'\n" "$RELEASE_BUILD"
    printf "RELEASE_TAG='%s'\n" "$RELEASE_TAG"
    printf "RELEASE_DMG_NAME='%s'\n" "$RELEASE_DMG_NAME"
    printf "RELEASE_DMG_PATH='%s'\n" "$RELEASE_DMG_PATH"
    printf "RELEASE_APPCAST_PATH='%s'\n" "$RELEASE_APPCAST_PATH"
    ;;
  json)
    if [[ "$RELEASE_CHANNEL" == 'official' ]]; then
      printf '{"channel":"official","version":"%s","build":%s,"tag":"%s","dmgName":"%s","dmgPath":"%s","appcastPath":"%s"}\n' \
        "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_TAG" "$RELEASE_DMG_NAME" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH"
    else
      printf '{"channel":"development","version":"%s","build":%s,"tag":null,"dmgName":"%s","dmgPath":"%s","appcastPath":"%s"}\n' \
        "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_DMG_NAME" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH"
    fi
    ;;
  *) release_fail 'Usage: scripts/resolve-release-version.sh {validate|version|build|tag|dmg-name|dmg-path|appcast-path|channel|shell|json}' ;;
esac
