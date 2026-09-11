#!/usr/bin/env bash
# Evidence reading; runs on the host or in the VM, and only reads. For every tick, in
# timeline order, prints "<tick> <tick-utc> <pod> <series> <value>" for each lab pod that
# is either every lab pod (POD_PREFIX '') or exactly one Deployment's -- POD_PREFIX
# followed by exactly two dash-separated segments (<deploy>-<replicaset-hash>-<pod-
# suffix>), so "probe-tcp-new" never also matches "probe-tcp-new-b"'s pods -- for each
# series named METRIC, with or without labels.
# Example: pod-series.sh RUN probe-http tcp_open_total
# Usage: pod-series.sh <run-dir> <pod-prefix> <metric>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/common.sh"
run="${1:?usage: pod-series.sh <run-dir> <pod-prefix> <metric>}"
[ $# -eq 3 ] || die "usage: pod-series.sh <run-dir> <pod-prefix, '' for every pod> <metric>"
prefix="$2"
metric="${3:?usage: pod-series.sh <run-dir> <pod-prefix> <metric>}"
[ -f "$run/timeline.log" ] || die "$run has no timeline.log"
awk '$2 == "tick" { print $1, $3 }' "$run/timeline.log" | while read -r utc tick; do
  [ -f "$run/metrics/$tick.txt" ] || continue
  awk -v pre="$prefix" -v m="$metric" -v t="$tick" -v u="$utc" '
    function pod_matches(pod,    rest) {
      if (pre == "") return 1
      if (index(pod, pre "-") != 1) return 0
      return split(substr(pod, length(pre) + 2), rest, "-") == 2
    }
    /^== / { split($2, a, "/"); pod = a[2]; on = (a[1] == "lab" && pod_matches(pod)); next }
    on && ($1 == m || index($1, m "{") == 1) { print t, u, pod, $1, $2 }' "$run/metrics/$tick.txt"
done
