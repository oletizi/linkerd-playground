#!/usr/bin/env bash
# Runs on the macOS HOST. Waits for a scenario launched by run.sh to finish, prints
# the end of its timeline and its validity verdict, and exits with the scenario's
# exit status (124 if the timeout passes first; the run keeps going regardless).
# Usage: wait-run.sh <demo-relative-run-dir> [timeout-seconds, default 3600]
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rel="${1:?usage: wait-run.sh <demo-relative-run-dir> [timeout-seconds]}"
rc=0
bash "$DEMO/scripts/wait-log.sh" "$rel/harness.log" "${2:-3600}" > /dev/null || rc=$?
[ "$rc" -ne 124 ] || { echo "still running: $rel" >&2; exit 124; }
echo "--- timeline (last 15 lines)"
tail -n 15 "$DEMO/$rel/timeline.log"
echo "--- validity"
cat "$DEMO/$rel/validity.txt" 2>/dev/null || echo "(no validity.txt: the run aborted; see $rel/harness.log)"
exit "$rc"
