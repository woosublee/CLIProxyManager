#!/usr/bin/env bash
# Submits a file to Apple's notary service with a stored notarytool keychain
# profile, and prints Apple's log when the submission is not accepted.
set -euo pipefail

file="${1:?usage: scripts/notarize.sh <zip-or-dmg>}"
profile="${NOTARY_PROFILE:-woosublee-notary}"
timeout="${NOTARIZE_TIMEOUT:-45m}"
notarytool=("${XCRUN:-xcrun}" notarytool)

[[ -f "$file" ]] || { echo "ERROR: file does not exist: $file" >&2; exit 1; }

profile_args=(--keychain-profile "$profile")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  profile_args+=(--keychain "$NOTARY_KEYCHAIN")
fi

submit_status=0
result="$("${notarytool[@]}" submit "$file" \
  "${profile_args[@]}" \
  --wait \
  --timeout "$timeout" \
  --output-format plist)" || submit_status=$?

submission_id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
echo "Notarization submission ${submission_id:-unknown}: ${status:-unknown} (notarytool exit $submit_status)"

if [[ "$submit_status" -ne 0 || "$status" != "Accepted" ]]; then
  printf '%s\n' "$result" >&2
  if [[ -n "$submission_id" ]]; then
    if [[ "$status" == "In Progress" ]]; then
      echo "Still processing. Resume with: xcrun notarytool wait $submission_id --keychain-profile $profile" >&2
    else
      "${notarytool[@]}" log "$submission_id" "${profile_args[@]}" >&2 || true
    fi
  fi
  exit 1
fi
