#!/usr/bin/env bash
# Runs on the macOS HOST. Runs a script from demos/cert-hygiene inside the lab machine,
# with the demo directory as its working directory. Paths are the same on both sides.
#   in-lab.sh <script> [args...]                 foreground; exits with the script's status
#   in-lab.sh --detach <log> <script> [args...]  detached; the log ends with "[exit N]"
set -euo pipefail
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$DEMO/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"; load_config "$DEMO"
require_cmd orb

detach_log=""
if [ "${1:-}" = "--detach" ]; then
  detach_log="${2:?--detach needs a log path}"
  shift 2
fi
[ $# -ge 1 ] || die "usage: in-lab.sh [--detach <log>] <script> [args...]"
[ -f "$DEMO/$1" ] || die "no such script: $DEMO/$1"

quoted=""
for a in "$@"; do quoted="$quoted $(printf '%q' "$a")"; done
if [ -n "$detach_log" ]; then
  quoted=" lab/detach.sh $(printf '%q' "$detach_log")$quoted"
fi
orb -m "$LAB_VM" bash -lc "cd $(printf '%q' "$DEMO") && bash$quoted"
