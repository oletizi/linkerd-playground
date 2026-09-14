#!/usr/bin/env bash
# Recovery stage choreographies (design sections 1.7 and 2). Source after
# lab/scenario-common.sh's helpers, lab/collect.sh and lab/gates.sh; do not execute.

snap_before_restart() { # LABEL: logs and probe history of the pods a stage will replace
  snap_logs "$1"
  snap_probes "$1"
}

wait_issuer_updated() { # TIMEOUT_S: record when (or whether) identity reloaded the issuer
  local t0 deadline
  t0="$(date -u +%s)"
  deadline=$(( t0 + $1 ))
  until kubectl -n linkerd get events --field-selector reason=IssuerUpdated -o name 2>/dev/null | grep -q .; do
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      mark issuer-updated "no IssuerUpdated event within ${1}s"
      return 0
    fi
    sleep 5
  done
  mark issuer-updated "IssuerUpdated event seen $(( $(date -u +%s) - t0 ))s after apply"
}

stage_window() { # STAGE WINDOW_S: no restarts for WINDOW_S (ticks STAGE-N), then samples
  local stage="$1" window="$2"
  mark stage "$stage: no restarts for ${window}s"
  observe_until $(( $(date -u +%s) + window )) "${stage%%-*}" post_expiry_hook
  stage_samples "$stage"
}

# restart_stages: the four cumulative stages that map endpoint state (design section 2):
# no restarts; client A; server; everything else. Used by the control, R and O.
restart_stages() {
  stage_window stage1-norestart "$RECOVER_WINDOW_S"
  matrix_restart_stages
}

# matrix_restart_stages: stages 2-4 of the matrix, each gated and sampled. S-hard uses
# them after its own condition-driven stage 1.
matrix_restart_stages() {
  local rest
  snap_before_restart pre-stage2
  restart_and_gate stage2-client-a probe-tcp-new
  tick stage2-client-a
  snap_before_restart pre-stage3
  restart_and_gate stage3-server server
  tick stage3-server
  snap_before_restart pre-stage4
  mapfile -t rest < <(lab_deployments | grep -vx -e probe-tcp-new -e server)
  [ "${#rest[@]}" -ge 1 ] || die "restart_stages: no lab Deployments left for stage 4"
  restart_and_gate stage4-all "${rest[@]}"
  tick stage4-all
}

# capture_rollouts FILE NAMESPACE DEPLOY...: wait for each named Deployment's rollout in
# NAMESPACE, recorded to FILE with capture. The one rollout-status loop, shared by every
# namespace a scenario restarts into (the control plane's linkerd, W's own; linkerd-viz,
# V's, Task 3b). FILE ends [exit 0] only when at least one Deployment was named and every
# rollout completed: an empty list would otherwise wait for nothing.
capture_rollouts() {
  local f="${1:?capture_rollouts: FILE required}" ns="${2:?capture_rollouts: NAMESPACE required}"
  shift 2
  # shellcheck disable=SC2016
  capture "$f" bash -c 'ns="$1"; shift
    [ $# -ge 1 ] || { echo "no Deployment named"; exit 1; }
    for d in "$@"; do kubectl -n "$ns" rollout status "deploy/$d" --timeout=300s || exit 1; done' capture_rollouts "$ns" "$@"
}

# capture_cp_rollouts FILE: capture_rollouts over every control-plane Deployment (the
# rollout wait of R, A, S and W's recovery). The names come from stdout only (_record), so
# a kubectl warning on stderr never becomes a name. A failed listing is recorded in FILE in
# capture's format, ending with its non-zero exit; an empty listing names no Deployment,
# so FILE ends non-zero too.
capture_cp_rollouts() {
  local ds rc=0
  ds="$(_record "control-plane Deployment listing" kubectl -n linkerd get deploy -o name)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    mkdir -p "$(dirname "$RUN_DIR/$1")"
    printf '$ kubectl -n linkerd get deploy -o name\n%s\n[exit %s]\n' "$ds" "$rc" > "$RUN_DIR/$1"
    return 0
  fi
  # shellcheck disable=SC2086
  capture_rollouts "$1" linkerd ${ds//deployment.apps\//}
}
