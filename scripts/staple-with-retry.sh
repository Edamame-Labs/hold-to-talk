#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/staple-with-retry.sh <path-to-app-or-dmg>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

TARGET="$1"
ATTEMPTS="${STAPLER_ATTEMPTS:-4}"
DELAY_SECONDS="${STAPLER_RETRY_DELAY_SECONDS:-15}"

if [[ ! "${ATTEMPTS}" =~ ^[0-9]+$ || "${ATTEMPTS}" -lt 1 ]]; then
  echo "error: STAPLER_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

attempt=1
while true; do
  if xcrun stapler staple "${TARGET}"; then
    exit 0
  fi

  status=$?
  if [[ "${attempt}" -ge "${ATTEMPTS}" ]]; then
    echo "error: stapler failed for ${TARGET} after ${attempt} attempts" >&2
    exit "${status}"
  fi

  echo "warning: stapler failed for ${TARGET} on attempt ${attempt}/${ATTEMPTS}; retrying in ${DELAY_SECONDS}s" >&2
  sleep "${DELAY_SECONDS}"
  attempt=$((attempt + 1))
done
