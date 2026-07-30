#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLICY="$REPO_ROOT/Sources/CLIProxyManagerCore/Compatibility/RuntimeCompatibility.swift"
KOREAN_README="$REPO_ROOT/README.md"
ENGLISH_README="$REPO_ROOT/README.en.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for file in "$POLICY" "$KOREAN_README" "$ENGLISH_README"; do
  [[ -f "$file" ]] || fail "required support-matrix source is missing"
done

grep -F 'minimumMacOSMajor: 15' "$POLICY" >/dev/null || fail "policy must declare macOS 15"
grep -F 'supportedArtifactTarget: .darwinArm64' "$POLICY" >/dev/null || fail "policy must declare darwin/arm64"
grep -F 'requiredLoginShellPath: "/bin/zsh"' "$POLICY" >/dev/null || fail "policy must declare zsh"
grep -F 'lastVerifiedClaudeCodeVersion: "2.1.220"' "$POLICY" >/dev/null || fail "policy must declare the verified Claude Code version"

matrix_rows() {
  grep -E '^\| (macOS|Architecture|Shell|Artifact|Claude Code|Compatibility) \|' "$1" | cut -d '|' -f 2 || true
}

expected_rows=$' macOS \n Architecture \n Shell \n Artifact \n Claude Code \n Compatibility '
korean_rows="$(matrix_rows "$KOREAN_README")"
english_rows="$(matrix_rows "$ENGLISH_README")"
[[ "$korean_rows" == "$expected_rows" ]] || fail "README.md support matrix rows are missing or out of order"
[[ "$english_rows" == "$expected_rows" ]] || fail "README.en.md support matrix rows are missing or out of order"
[[ "$korean_rows" == "$english_rows" ]] || fail "README support matrix row order must match"

for token in 'macOS 15' 'arm64' 'zsh' 'darwin/arm64' '2.1.220' '2026-07-31'; do
  grep -F "$token" "$KOREAN_README" >/dev/null || fail "README.md must document $token"
  grep -F "$token" "$ENGLISH_README" >/dev/null || fail "README.en.md must document $token"
done

grep -F '경고' "$KOREAN_README" >/dev/null || fail "README.md must document warnings"
grep -F '차단' "$KOREAN_README" >/dev/null || fail "README.md must document blocks"
grep -F '복구' "$KOREAN_README" >/dev/null || fail "README.md must document recovery"
grep -F 'Warning' "$ENGLISH_README" >/dev/null || fail "README.en.md must document warnings"
grep -F 'Block' "$ENGLISH_README" >/dev/null || fail "README.en.md must document blocks"
grep -F 'Recovery' "$ENGLISH_README" >/dev/null || fail "README.en.md must document recovery"

printf 'support matrix tests passed\n'
