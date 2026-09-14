#!/usr/bin/env bash
# Scenario N, shared by 40-webhook-unavailable-ignore and 40-webhook-unavailable-fail
# (design section 3, slice 4): a healthy installation with valid, long-lived webhook
# credentials, whose proxy-injector Deployment is scaled to zero, probed, then restored.
# Nothing here rotates a certificate; N3 is the hypothesis that the webhook's serving
# certificate stayed valid throughout, so every tick still records its state. Structured
# like W (lab/scenario-webhook.sh) -- same admission-probe set, same lab-webhook helpers,
# same Ignore/Fail profile shape -- so N2 (Ignore) is a direct, structural comparison
# against W2 (Ignore), not a comparison between differently-shaped runs. T_mark, here, is
# simply when the fault (the scale-down) happens; FAULT_LEAD_S is shared with O and
# S-hard, the lab's other fault-driven (non-expiry) scenarios. Source after
# lab/scenario-common.sh; do not execute.
# shellcheck source=/dev/null
. "$LAB_DIR/admission.sh"

# Read only by scenario_post_window_end (scenario-common.sh), not by this file itself.
# shellcheck disable=SC2034
POST_EXPIRY_WINDOW_S="$N_FAULT_WINDOW_S"   # the post window is N's fault window

N_BACKING_DEPLOYS=()
declare -A N_ORIG_REPLICAS

scenario_mark_epoch() { # T_mark: when the proxy-injector Deployment is scaled to zero
  echo $(( $(date -u +%s) + FAULT_LEAD_S ))
}

_n_phase() { # TICK: the admission phase for a probe set taken now (mirrors W's _w_phase,
  # minus the reconnect branch N has no equivalent of)
  local now
  now="$(date -u +%s)"
  case "$1" in
    baseline) echo baseline ;;
    verify) echo restored ;;
    *) if [ "$now" -lt "$T_MARK" ]; then echo pre-fault; else printf 'fault-%04d\n' $(( now - T_MARK )); fi ;;
  esac
}

# _n_cert_state TICK: webhook-cert-state/TICK.txt -- N3's per-tick record of the
# proxy-injector's serving certificate (notAfter, fingerprint, and whether it still
# verifies against the live caBundle), reusing w_cert_state_line (collect-state.sh,
# shared with W's _w_facts) rather than a second certificate-state mechanism. Read every
# tick, including during the fault: the Secret and the webhook configuration are ordinary
# API objects, unaffected by the Deployment behind the Service having no pods.
_n_cert_state() {
  local tick="${1:?_n_cert_state: TICK required}"
  local f="$RUN_DIR/webhook-cert-state/$tick.txt" tmp
  mkdir -p "$RUN_DIR/webhook-cert-state"
  tmp="$(mktemp -d)"
  w_cert_state_line proxyInjector "$CERTS/webhooks" "$tmp" "$(date -u +%s)" > "$f"
  rm -rf "$tmp"
}

scenario_tick_extra() { # NAME: admission probes and N's certificate-state record, every
  # tick, in the tick's phase; the baseline and post-restore probes are also N's validity
  # evidence (n-baseline, n-restored)
  admission_probes "$(_n_phase "$1")" "$1"
  _n_cert_state "$1"
  case "$1" in
    baseline)
      _write_result admission-baseline.txt admission_proof_check "$RUN_DIR/admission/baseline" baseline \
        "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" \
        || die "the healthy baseline did not prove every admission probe; see admission-baseline.txt" ;;
    verify)
      # Not fatal, unlike the baseline: by the verify tick the run is nearly finished, and
      # a failed restore is itself a finding worth the rest of _scenario_finish's evidence
      # (final logs, events, journal) rather than an early die. n-restored judges it.
      _write_result admission-restored.txt admission_proof_check "$RUN_DIR/admission/restored" verify \
        "$POLICY_VALIDATOR_WEBHOOK_NAME" "$SP_VALIDATOR_WEBHOOK_NAME" || true ;;
  esac
}

scenario_post_actions() { # T_mark + 60s: admission probes instead of new workloads (as W)
  admission_probes "$(_n_phase post-actions)" post-actions
  mark admission-probes post-actions
}

# _n_wait_gone: scale/pods-gone.txt -- wait for every backing Deployment's pods to
# actually be gone (wait_pods_gone, collect-state.sh, shared with G's certificate swap).
_n_wait_gone() {
  wait_pods_gone scale/pods-gone.txt linkerd "${N_BACKING_DEPLOYS[@]}"
}

scenario_fault() { # scale the derived Deployment(s) to zero, wait for the rollout AND
  # for their pods to actually be gone
  local d
  snap_controlplane fault-before
  _n_backing
  mark scale-backing "$(paste -sd';' "$RUN_DIR/scale/backing.txt")"
  mapfile -t N_BACKING_DEPLOYS < <(w_backing_deployments "$RUN_DIR/scale/backing.txt")
  [ "${#N_BACKING_DEPLOYS[@]}" -ge 1 ] \
    || die "scenario_fault: proxy-injector backing derivation named no Deployment; see scale/backing.txt"
  for d in "${N_BACKING_DEPLOYS[@]}"; do
    N_ORIG_REPLICAS["$d"]="$(kubectl -n linkerd get deploy "$d" -o jsonpath='{.spec.replicas}')" \
      || die "scenario_fault: cannot read $d's replica count"
    [ -n "${N_ORIG_REPLICAS[$d]}" ] || die "scenario_fault: $d's replica count is empty"
  done
  mark scale-down "${N_BACKING_DEPLOYS[*]} -> 0 replicas (was $(for d in "${N_BACKING_DEPLOYS[@]}"; do printf '%s=%s ' "$d" "${N_ORIG_REPLICAS[$d]}"; done))"
  capture scale/scale-down.txt kubectl -n linkerd scale "${N_BACKING_DEPLOYS[@]/#/deploy/}" --replicas=0
  capture_rollouts scale/rollout-down.txt linkerd "${N_BACKING_DEPLOYS[@]}"
  _n_wait_gone
  snap_controlplane fault-after
}

# _n_injecting_now: yes|no -- does a server-side dry-run of the inject-probe template get
# a linkerd-proxy container right now? Same throwaway-dry-run technique as W's
# _w_serving_now (no object is ever created), scoped to the one webhook N's fault
# touches.
_n_injecting_now() {
  local tmp rc=no
  tmp="$(mktemp -d)"
  admission_render inject-probe propagation-probe > "$tmp/pod.yaml"
  if kubectl create --dry-run=server -o yaml -f "$tmp/pod.yaml" 2>&1 | grep -qE 'name: linkerd-proxy$'; then rc=yes; fi
  rm -rf "$tmp"
  echo "$rc"
}

# _n_settle: scale/settle.txt -- poll until the proxy-injector serves again, or
# W_PROPAGATION_TIMEOUT_S passes. "pods Ready" and "webhook serving" are different
# instants, the same reason W's own recovery polls _w_serving_now rather than trusting
# the rollout wait alone; without this, the verify tick that n-restored judges could run
# before the webhook is actually back; result=fail there is judged, never masked.
_n_settle() {
  local f="$RUN_DIR/scale/settle.txt" deadline s
  deadline=$(( $(date -u +%s) + W_PROPAGATION_TIMEOUT_S ))
  : > "$f"
  while :; do
    s="$(_n_injecting_now)"
    printf '%s injecting=%s\n' "$(_utc)" "$s" >> "$f"
    if [ "$s" = yes ]; then mark settled "proxy-injector serving again"; return 0; fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then mark settled "not serving after ${W_PROPAGATION_TIMEOUT_S}s"; return 0; fi
    sleep 5
  done
}

# _n_backing: scale/backing.txt, the proxy-injector Service's backing Deployment(s)
# (w_backing_write, collect-state.sh, shared with W's _w_backing).
_n_backing() {
  w_backing_write "$RUN_DIR/scale/backing.txt" proxyInjector
}

scenario_recover() { # scale the same Deployment(s) back to their original replica
  # counts, wait for the rollout, then settle before the verify tick judges it
  local d pairs=()
  for d in "${N_BACKING_DEPLOYS[@]}"; do pairs+=("$d=${N_ORIG_REPLICAS[$d]}"); done
  mark scale-up "restoring ${pairs[*]}"
  # shellcheck disable=SC2016
  capture scale/scale-up.txt bash -c 'ns="$1"; shift
    for pair in "$@"; do kubectl -n "$ns" scale "deploy/${pair%%=*}" --replicas="${pair#*=}" || exit 1; done' \
    scale-up linkerd "${pairs[@]}"
  capture_rollouts scale/rollout-up.txt linkerd "${N_BACKING_DEPLOYS[@]}"
  snap_controlplane recover-scaled-up
  _n_settle
}
