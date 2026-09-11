#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. Summarises every
# restart-stage gate record (gates/<stage>.txt): its header, cells and leaf lines.
# Usage: gate-table.sh <run-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: gate-table.sh <run-dir>}"
[ -d "$run/gates" ] || die "$run has no gates/ directory"
for f in "$run"/gates/*.txt; do
  awk -F= '
    $1 == "stage" { s = $2 } $1 == "restarted" { r = $2 } $1 == "gate" { g = $2 } $1 == "unmet" { u = $2 }
    END { printf "stage=%s restarted=%s gate=%s unmet=%s\n", s, r, g, (u == "" ? "-" : u) }' "$f"
  awk '/^(cell|leaf) / { print "  " $0 }' "$f"
done
