#!/usr/bin/env bash
# Runs INSIDE the lab VM. Starts a script detached from the calling session so it
# outlives the `orb` session that launched it. Usage: detach.sh <log> <script> [args...]
# The log's last line is "[exit N]" once the script has finished.
set -euo pipefail
log_file="${1:?usage: detach.sh <log> <script> [args...]}"
shift
[ $# -ge 1 ] || { echo "detach.sh: a script to run is required" >&2; exit 1; }
mkdir -p "$(dirname "$log_file")"
setsid nohup bash -c 'bash "$@"; echo "[exit $?]"' _ "$@" > "$log_file" 2>&1 < /dev/null &
echo "detached pid $! -> $log_file"
