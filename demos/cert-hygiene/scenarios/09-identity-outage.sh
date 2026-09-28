#!/usr/bin/env bash
# Scenario O (design section 4): the identity service is scaled to zero for OUTAGE_S,
# longer than a leaf's lifetime plus skew, while every credential stays unchanged. New
# workloads are created during the outage. After identity returns, a no-restart window
# is sampled first, then R's gated restart stages. Launch with scripts/run.sh.
set -euo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lab" && pwd)/scenario-common.sh"

# Read only by scenario_post_window_end in scenario-common.sh, not by this file itself.
# shellcheck disable=SC2034
POST_EXPIRY_WINDOW_S="$OUTAGE_S"   # the post window is the outage

scenario_mark_epoch() {
  echo $(( $(date -u +%s) + FAULT_LEAD_S ))
}

scenario_fault() {
  snap_controlplane fault-before
  mark fault-identity-down "scale deploy/linkerd-identity to 0 replicas for ${OUTAGE_S}s"
  capture fault/scale-down.txt kubectl -n linkerd scale deploy/linkerd-identity --replicas=0
  capture fault/identity-gone.txt kubectl -n linkerd wait --for=delete pod \
    -l linkerd.io/control-plane-component=identity --timeout=120s
  snap_controlplane fault-after
}

scenario_recover() {
  mark recover-identity-up "scale deploy/linkerd-identity back to 1 replica"
  capture recover/scale-up.txt kubectl -n linkerd scale deploy/linkerd-identity --replicas=1
  capture recover/rollout-up.txt kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=300s
  snap_controlplane recover-identity-up
  mark identity-pod "$(kubectl -n linkerd get pod -l linkerd.io/control-plane-component=identity \
    -o jsonpath='{range .items[*]}{.metadata.name} uid={.metadata.uid} start={.status.startTime} {end}')"
  restart_stages
}

run_scenario 09-identity-outage long "${1:?usage: 09-identity-outage.sh <run-dir>}"
