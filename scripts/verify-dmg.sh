#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/verify-dmg.sh <path-to-dmg>" >&2
  exit 64
fi

dmg_path="$1"
last_status=0

for attempt in 1 2 3; do
  if hdiutil verify "$dmg_path"; then
    exit 0
  fi
  last_status=$?
  if [[ $attempt -lt 3 ]]; then
    sleep 2
  fi
done

exit "$last_status"
