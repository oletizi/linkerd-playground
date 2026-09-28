#!/usr/bin/env bash
# Runs on the macOS HOST. Waits for a detached lab log (see in-lab.sh --detach) to end
# with "[exit N]", prints its tail, and exits N. Exits 124 if the timeout passes first.
# Usage: wait-log.sh <demo-relative-log> [timeout-seconds, default 1800]
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"

log_file="$DEMO/${1:?usage: wait-log.sh <demo-relative-log> [timeout-seconds]}"
timeout_s="${2:-1800}"
deadline=$(( $(date +%s) + timeout_s ))
while :; do
  if [ -f "$log_file" ] && tail -n 1 "$log_file" | grep -qE '^\[exit [0-9]+\]$'; then
    tail -n 40 "$log_file"
    rc="$(tail -n 1 "$log_file" | tr -dc '0-9')"
    exit "$rc"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { err "timed out after ${timeout_s}s waiting for $log_file"; exit 124; }
  sleep 10
done
