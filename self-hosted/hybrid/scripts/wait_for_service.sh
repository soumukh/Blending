#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <url-or-command> [timeout_seconds] [sleep_seconds]" >&2
  exit 2
fi

TARGET="$1"
TIMEOUT_SECONDS="${2:-180}"
SLEEP_SECONDS="${3:-5}"
START_TS="$(date +%s)"

echo "Waiting up to ${TIMEOUT_SECONDS}s for: ${TARGET}"

while true; do
  if [[ "$TARGET" =~ ^https?:// ]]; then
    if curl -fsS --max-time 5 "$TARGET" >/dev/null 2>&1; then
      echo "Ready: ${TARGET}"
      exit 0
    fi
  else
    if bash -lc "$TARGET" >/dev/null 2>&1; then
      echo "Ready: ${TARGET}"
      exit 0
    fi
  fi

  NOW_TS="$(date +%s)"
  if [ $((NOW_TS - START_TS)) -ge "$TIMEOUT_SECONDS" ]; then
    echo "Timed out waiting for: ${TARGET}" >&2
    exit 1
  fi

  sleep "$SLEEP_SECONDS"
done

