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
