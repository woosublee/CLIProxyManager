#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

remote_tag_commit() {
  local tag="$1"
  local output direct peeled
  if ! output="$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"; then
    fail 'Unable to query the remote release tag'
  fi
  direct="$(printf '%s\n' "$output" | grep -F "refs/tags/$tag" | grep -Fv "refs/tags/$tag^{}" | sed -n '1p' | cut -f1 || true)"
  peeled="$(printf '%s\n' "$output" | grep -F "refs/tags/$tag^{}" | sed -n '1p' | cut -f1 || true)"
  printf '%s\n' "${peeled:-$direct}"
}

[[ $# -eq 1 || $# -eq 3 ]] || fail 'Usage: scripts/release-local.sh RELEASE_TAG [--previous-appcast FILE]'
INPUT_TAG="$1"
PREVIOUS_APPCAST=''
if [[ $# -eq 3 ]]; then
  [[ "$2" == '--previous-appcast' ]] || fail 'Usage: scripts/release-local.sh RELEASE_TAG [--previous-appcast FILE]'
  PREVIOUS_APPCAST="$3"
  [[ -f "$PREVIOUS_APPCAST" ]] || fail 'The explicit previous appcast does not exist'
fi

for legacy_name in VERSION BUILD_NUMBER RELEASE_TAG DMG_PATH; do
  [[ -z "${!legacy_name+x}" ]] || fail "$legacy_name is derived from release/version.json; remove the override"
done

cd "$REPO_ROOT"
eval "$("$SCRIPT_DIR/resolve-release-version.sh" shell)"
[[ "$RELEASE_CHANNEL" == 'official' ]] || fail 'Local releases require the official artifact channel'
SAFE_INPUT_TAG='invalid'
if [[ "$INPUT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAFE_INPUT_TAG="$INPUT_TAG"
fi
[[ "$INPUT_TAG" == "$RELEASE_TAG" ]] || fail "Release tag mismatch: expected $RELEASE_TAG, actual $SAFE_INPUT_TAG"

APP_VERSION="$RELEASE_VERSION"
APP_BUILD="$RELEASE_BUILD"
CANONICAL_TAG="$RELEASE_TAG"
PROVENANCE_PATH='build/release-provenance.json'
RELEASE_NOTES_PATH='build/release-notes.md'
"$SCRIPT_DIR/sync-release-version.sh" --check
if [[ -z "${REPOSITORY:-}" ]]; then
  REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || fail 'Unable to determine the GitHub repository'
fi
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Repository must use OWNER/REPO'
export REPOSITORY

initial_remote_commit="$(remote_tag_commit "$CANONICAL_TAG")"
resume_mode=0
release_exists=0
if [[ "${ALLOW_LOCAL_RELEASE_CLOBBER:-}" == '1' ]]; then
  resume_mode=1
  head_commit="$(git rev-parse HEAD)"
  [[ -n "$initial_remote_commit" ]] || fail 'Resume requires an existing remote release tag'
  [[ "$initial_remote_commit" == "$head_commit" ]] || fail 'Remote release tag points to a different commit'
else
  [[ -z "$initial_remote_commit" ]] || fail "Release tag $CANONICAL_TAG already exists on origin"
fi

if [[ "$resume_mode" == '1' ]]; then
  if assets="$(gh release view "$CANONICAL_TAG" --json assets --jq '.assets[].name' 2>/dev/null)"; then
    release_exists=1
  else
    gh api "repos/$REPOSITORY" >/dev/null 2>&1 || fail 'Unable to query the partial GitHub Release'
    release_exists=0
    assets=''
  fi

  if printf '%s\n' "$assets" | grep -Fx 'appcast.xml' >/dev/null; then
    existing_dir="$(mktemp -d /tmp/cliproxymanager-existing-release.XXXXXX)"
    cleanup_existing() { rm -rf "$existing_dir"; }
    trap cleanup_existing EXIT
    gh release download "$CANONICAL_TAG" --pattern appcast.xml --dir "$existing_dir" || fail 'Unable to download the existing release appcast'
    if "$SCRIPT_DIR/verify-release-artifacts.sh" --appcast "$existing_dir/appcast.xml" --official; then
      fail 'A valid canonical appcast is already published; clobber is not allowed'
    fi
    cleanup_existing
    trap - EXIT
  fi
fi

monotonic_args=(--repository "$REPOSITORY" --provenance "$PROVENANCE_PATH")
if [[ -n "$PREVIOUS_APPCAST" ]]; then
  monotonic_args+=(--previous-appcast "$PREVIOUS_APPCAST")
fi
if [[ "$resume_mode" == '1' ]]; then
  monotonic_args+=(--exclude-tag "$CANONICAL_TAG")
fi

"$SCRIPT_DIR/check-release-monotonic.sh" "${monotonic_args[@]}"
security find-identity -v -p codesigning | grep -F '"cliproxymanager"' >/dev/null || fail 'cliproxymanager code signing identity is required. Confirm it exists with: security find-identity -v -p codesigning.'
make verify-dmg
"$SCRIPT_DIR/generate-sparkle-appcast.sh"
"$SCRIPT_DIR/verify-release-artifacts.sh" \
  --source-plist Info.plist \
  --app build/CLIProxyManager.app \
  --dmg "$RELEASE_DMG_PATH" \
  --appcast "$RELEASE_APPCAST_PATH" \
  --provenance "$PROVENANCE_PATH" \
  --official
"$SCRIPT_DIR/check-release-monotonic.sh" "${monotonic_args[@]}"
final_remote_commit="$(remote_tag_commit "$CANONICAL_TAG")"
if [[ "$resume_mode" == '1' ]]; then
  [[ "$final_remote_commit" == "$head_commit" ]] || fail 'Remote release tag changed while artifacts were building'
else
  [[ -z "$final_remote_commit" ]] || fail "Release tag $CANONICAL_TAG appeared while artifacts were building"
fi

{
  printf '%s\n' "Local release for CLIProxyManager $APP_VERSION (build $APP_BUILD)."
  printf '%s\n' 'Artifacts passed canonical identity, monotonicity, and parity verification before publication.'
  if [[ -n "$PREVIOUS_APPCAST" ]]; then
    printf '%s\n' 'Monotonicity used an explicit local fallback appcast.'
  fi
} > "$RELEASE_NOTES_PATH"

if [[ "$resume_mode" == '0' ]]; then
  git tag "$CANONICAL_TAG" HEAD
  git push origin "refs/tags/$CANONICAL_TAG"
fi

if [[ "$release_exists" == '0' ]]; then
  gh release create "$CANONICAL_TAG" --verify-tag --title "CLIProxyManager $APP_VERSION" --notes-file "$RELEASE_NOTES_PATH"
fi

if [[ "$resume_mode" == '1' ]]; then
  gh release upload "$CANONICAL_TAG" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH" "$PROVENANCE_PATH" --clobber
else
  gh release upload "$CANONICAL_TAG" "$RELEASE_DMG_PATH" "$RELEASE_APPCAST_PATH" "$PROVENANCE_PATH"
fi
