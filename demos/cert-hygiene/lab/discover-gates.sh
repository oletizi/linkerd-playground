#!/usr/bin/env bash
# Runs INSIDE the lab VM, against a long-profile lab with baseline workloads deployed.
# Exercises the restart-stage gates on healthy restarts (design section 10): client A,
# then server, then every other lab Deployment, recording how long each gate took.
# Usage: discover-gates.sh <out-dir>
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lab.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/collect.sh"
# shellcheck source=/dev/null
. "$LAB_DIR/gates.sh"
RUN_DIR="${1:?usage: discover-gates.sh <out-dir>}"
[ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists; refusing to overwrite"
mkdir -p "$RUN_DIR"

mark discover-gates start
stage_samples g0-no-restart
restart_and_gate g1-client-a probe-tcp-new
restart_and_gate g2-server server
mapfile -t rest < <(lab_deployments | grep -vx -e probe-tcp-new -e server)
restart_and_gate g3-all "${rest[@]}"
for s in g1-client-a g2-server g3-all; do
  f="$RUN_DIR/gates/$s.txt"
  printf 'stage=%s gate=%s seconds_to_gate=%s summary=%s\n' "$s" "$(_kv gate "$f")" \
    "$(( $(_kv gate_epoch "$f") - $(_kv started_epoch "$f") ))" "$(gate_summary "$f")"
done > "$RUN_DIR/durations.txt"
# shellcheck disable=SC1010
mark discover-gates done
cat "$RUN_DIR/durations.txt"
