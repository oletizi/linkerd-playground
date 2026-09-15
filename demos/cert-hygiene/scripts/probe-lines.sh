#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. Prints every line a
# probe wrote, from every file under RUN_DIR/probes/ (per-pod snapshots, current and
# previous containers; slice-1 runs' flat probes/<probe>.log files too), deduplicated
# and in time order: the probe's continuous history across restarts. With FROM and TO
# (UTC ISO-8601), only lines in [FROM, TO).
# Twin: lab/lib-evidence-control.sh's _all_probe_lines (Task 8) does the same merge
# inside the VM (bash 5); kept separate because this script must also run on the host
# (macOS bash 3.2 / POSIX awk). lab/tests/test-read.sh checks the two agree.
# Usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]}"
probe="${2:?usage: probe-lines.sh <run-dir> <probe> [from-utc] [to-utc]}"
from="${3:-}"; to="${4:-}"
[ -d "$run/probes" ] || die "$run has no probes/ directory"
lines="$(find "$run/probes" -type f -name '*.log' -exec awk -v p="$probe" '$2 == p' {} + | sort -u \
  | awk -v f="$from" -v t="$to" '(f == "" || $1 >= f) && (t == "" || $1 < t)')"
[ -n "$lines" ] || die "no $probe lines under $run/probes${from:+ from $from}${to:+ to $to}"
printf '%s\n' "$lines"
