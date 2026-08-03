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

matrix_rows() {
  grep -E '^\| (macOS|Architecture|Shell|Artifact|Claude Code|Compatibility) \|' "$1" | cut -d '|' -f 2 || true
}

expected_rows=$' macOS \n Architecture \n Shell \n Artifact \n Claude Code \n Compatibility '
korean_rows="$(matrix_rows "$KOREAN_README")"
english_rows="$(matrix_rows "$ENGLISH_README")"
[[ "$korean_rows" == "$expected_rows" ]] || fail "README.md support matrix rows are missing or out of order"
[[ "$english_rows" == "$expected_rows" ]] || fail "README.en.md support matrix rows are missing or out of order"
[[ "$korean_rows" == "$english_rows" ]] || fail "README support matrix row order must match"

matrix_cell() {
  local row="$1"
  local file="$2"
  grep -E "^\\| $row \\|" "$file" | cut -d '|' -f 3
}

korean_semantics() {
  local compatibility
  compatibility="$(matrix_cell Compatibility "$KOREAN_README")"
  [[ "$(matrix_cell macOS "$KOREAN_README")" == *'macOS 15+'* ]] || return 1
  [[ "$(matrix_cell Architecture "$KOREAN_README")" == *'arm64'* ]] || return 1
  [[ "$(matrix_cell Shell "$KOREAN_README")" == *'zsh'* ]] || return 1
  [[ "$(matrix_cell Artifact "$KOREAN_README")" == *'darwin/arm64'* ]] || return 1
  [[ "$(matrix_cell 'Claude Code' "$KOREAN_README")" == *'terminal function'* && "$(matrix_cell 'Claude Code' "$KOREAN_README")" == *'OAuth compatibility'* && "$(matrix_cell 'Claude Code' "$KOREAN_README")" == *'차단하지 않습니다'* ]] || return 1
  [[ "$compatibility" == *'경고'* && "$compatibility" == *'기존 proxy 동작'* && "$compatibility" == *'차단'* && "$compatibility" == *'시작'* && "$compatibility" == *'재시작'* && "$compatibility" == *'proxy update'* && "$compatibility" == *'생성된 shell 쓰기'* && "$compatibility" == *'중지는 유지'* && "$compatibility" == *'복구'* && "$compatibility" == *'새로 고치'* ]] || return 1
  printf 'macOS=15;architecture=arm64;shell=zsh;artifact=darwin/arm64;claude=required-for-functions-not-runtime-blocker;warning=continue;block=start,restart,update,shell-write;stop=available;recovery=refresh'
}

english_semantics() {
  local compatibility
  compatibility="$(matrix_cell Compatibility "$ENGLISH_README")"
  [[ "$(matrix_cell macOS "$ENGLISH_README")" == *'macOS 15+'* ]] || return 1
  [[ "$(matrix_cell Architecture "$ENGLISH_README")" == *'arm64'* ]] || return 1
  [[ "$(matrix_cell Shell "$ENGLISH_README")" == *'zsh'* ]] || return 1
  [[ "$(matrix_cell Artifact "$ENGLISH_README")" == *'darwin/arm64'* ]] || return 1
  [[ "$(matrix_cell 'Claude Code' "$ENGLISH_README")" == *'terminal functions'* && "$(matrix_cell 'Claude Code' "$ENGLISH_README")" == *'OAuth compatibility'* && "$(matrix_cell 'Claude Code' "$ENGLISH_README")" == *'not blocked'* ]] || return 1
  [[ "$compatibility" == *'Warning'* && "$compatibility" == *'existing proxy operation'* && "$compatibility" == *'Block'* && "$compatibility" == *'start'* && "$compatibility" == *'restart'* && "$compatibility" == *'proxy updates'* && "$compatibility" == *'generated shell writes'* && "$compatibility" == *'stopping an already running proxy remains available'* && "$compatibility" == *'Recovery'* && "$compatibility" == *'refresh'* ]] || return 1
  printf 'macOS=15;architecture=arm64;shell=zsh;artifact=darwin/arm64;claude=required-for-functions-not-runtime-blocker;warning=continue;block=start,restart,update,shell-write;stop=available;recovery=refresh'
}

korean_signature="$(korean_semantics)" || fail "README.md support matrix semantics are incomplete"
english_signature="$(english_semantics)" || fail "README.en.md support matrix semantics are incomplete"
[[ "$korean_signature" == "$english_signature" ]] || fail "README support matrix semantics must match"

for token in 'macOS 15' 'arm64' 'zsh' 'darwin/arm64' 'OAuth compatibility'; do
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
